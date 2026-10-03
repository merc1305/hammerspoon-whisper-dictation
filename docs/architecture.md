# Architecture and recovery

`init.lua` owns the microphone, Fn, UI, and paste. `dictation-transcribe.sh` owns an
immutable audio snapshot, recognition, and transcription history. Recording a long story
and retrying it must never depend on a partial transcript or a moving byte offset.

## Capture lifecycle

ffmpeg continuously writes 16 kHz mono signed 16-bit PCM to
`~/.local/share/whisper/capture-buffer.raw`. Fn remembers the current byte offset minus
0.5 seconds of pre-roll. Push-to-talk stops on release; Toggle stops on the next press.
Toggle defaults to a ten-minute safety limit, configurable under **Settings → Toggle
recording limit** (10 minutes, 30 minutes, or no limit). A warning appears one minute before
the limit. At the limit the controller saves the audio locally without recognition and
returns Fn to service; Ctrl+B can transcribe it deliberately. The five-second watchdog
enforces this limit, so stopping can occur up to five seconds after the boundary. Held
push-to-talk has no such limit. The menu bar displays elapsed recording time and provides
a stop action. Only the physical Fn key (keycode 63) changes recording state;
synthetic Fn flags on other modifier/navigation events are ignored.

On press, `active-capture.json` records the start offset. On stop, the controller waits up
to 0.8 seconds for the recorder tail, then journals the end offset and launches one job.
The finalization state blocks new captures and buffer rotation until the snapshot is safe.
A short read of the requested byte range is an error, never successful partial audio.

Each attempt has a unique directory under `~/.local/share/whisper/recordings/`:

| File | Purpose |
|---|---|
| `audio.wav` | Complete immutable input, saved before recognition starts |
| `audio-ready` | Acknowledges the committed audio snapshot |
| `status` | `running`, `saved` (local-only), `done`, `ignored`, or `error:<reason>` |
| `progress` | Current chunk / total chunks |
| `transcript.txt` | Final result; no successful prefix on a failed job |
| `raw.txt` | Unfiltered engine output for diagnosis |
| `chunks/` | Lossless audio chunks and individual transcripts |
| `error.log`, `engine`, `pid` | Job diagnostics |

After a live snapshot is saved, an atomic `last.wav` symlink points to it. Only then does
the controller remove the capture journal. The old shared `/tmp/dictation.*` output paths
remain defaults for standalone CLI callers; the Hammerspoon UI uses only its own job's
files. An old process cannot publish into a newer UI attempt.

## Recovery

**Ctrl+B** or **Retry last recording** starts recognition again from the complete saved
WAV. It does not copy old text. Earlier recordings and their original audio remain in the
recordings folder, accessible from the menu. Individual files can also be transcribed:

```bash
~/.local/bin/dictation-transcribe.sh /path/to/audio.wav
```

If Hammerspoon exits/reloads during capture, it preserves the journal and raw buffer and
interrupts ffmpeg gracefully. On the next launch the worker automatically saves the exact
journaled range as an immutable WAV with `--save-only --cut`, without calling a recognition
engine. Once `audio-ready` acknowledges the snapshot, the journal is cleared and the
recorder resumes. Even a multi-hour accidental capture no longer requires transcription
before Fn can work again. Ctrl+B can recognize the saved audio later; a new capture cannot
overwrite the archived WAV. Config reload during recognition leaves the job archive
available; Ctrl+B can retry the saved audio. Each retry has its own directory.

A failed recovery keeps the original buffer and journal. **Save interrupted recording and
resume** in the menu retries the local snapshot without recognition. Invalid metadata fails
closed with an explicit error. No recording is deleted automatically.

The Fn watchdog re-arms a disabled event tap without discarding a capture. Toggle keeps
recording; push-to-talk checks the physical key state and finalizes if a release was missed.
Recorder failure, stalled audio, or a microphone change preserves the captured prefix and
shows an interruption warning. Speech after a physical microphone failure cannot be
recovered; the UI does not claim otherwise. Device restarts are deferred while a snapshot
or recognition is in progress. ffmpeg is stopped with SIGINT, never SIGKILL.

## Long recordings and recognition

The existing profile still chooses the engine (`groq`, `whisper.cpp`, or `mlx`) and language.
No new paid service is enabled. On this Intel Mac the installed profile currently selects
Groq's `whisper-large-v3`; local models remain available for explicit offline configuration.

Recordings longer than 120 seconds are normalized to lossless PCM and split into consecutive
chunks. Each boundary is the midpoint of the quietest 100 ms window in the final 15 seconds
of a two-minute window. On continuous speech this is a quietest-point heuristic, not a
guarantee of a sentence boundary. Every sample belongs to exactly one chunk; concatenating
the decoded PCM chunks reconstructs the normalized recording exactly. There is no text
window deduplication that could remove intentionally repeated sentences.

Every chunk must succeed before the full result becomes `done`. A failed chunk leaves the
whole audio and completed chunk results on disk, and offers a full retry. Groq requests
have a 10-second connection timeout, 60-second attempt timeout, and two bounded retries
for transient curl/HTTP errors. Local decoders have a 15-minute limit per chunk and their
own process group for timeout cleanup. The UI no longer kills a long job after 180 seconds.

## Post-processing and insertion

The boilerplate filter only drops an entire response consisting solely of recognized
boilerplate and punctuation. A phrase such as “thanks for watching” inside real text never
deletes its continuation. Unfiltered output is always retained.

Optional LLM cleanup remains disabled by default. If enabled, an incomplete response or
any change to the sequence of non-filler words is rejected. Punctuation and case changes
are allowed; summarization, translation, and missing middle paragraphs are not accepted.

The transcript is copied to the clipboard. Automatic Cmd+V occurs only if the application
and window still match the capture target. If focus changed while recognition was running,
the user gets a “Text copied” notice and can paste deliberately. History still contains the
last 50 successful transcripts and now includes the original audio path.

Audio/job files are created with mode 600, and the data/recordings directories are private.
Stopped recordings are retained until the owner removes them; no pending recording is
silently pruned. PCM uses about 1.92 MB per minute; long-recording chunks add roughly another
copy. The ambient buffer rotates at 256 MiB while idle. Review or remove old recordings
through **Open saved recordings** when appropriate.

## Comparison with Codex dictation

Inspection of the installed ChatGPT/Codex desktop bundle on 2026-09-27 found a separate
recording lifecycle, persisted audio chunks, retry of the same audio, recovery after a
streaming failure, and explicit insertion-failure handling. Those client-side patterns
informed this implementation. The server-side recognition model used by that feature is
not established by that inspection, so equivalent word accuracy is not claimed.

OpenAI's [file transcription guide](https://developers.openai.com/api/docs/guides/speech-to-text)
also distinguishes completed-file transcription from live transcription and recommends
compressed audio or splitting larger inputs, avoiding cuts in the middle of a sentence.
Whisper Own retains its existing provider while adopting durable audio and retry semantics.

## Verification

- `lua test-init-settings.lua`: settings, physical Fn edges, event-tap recovery, missed
  releases, Toggle beyond five minutes, warning and local-only stop at the safety limit,
  persistent limit settings, unlimited PTT, finalization races, stalled microphone, slow
  recognition, focus changes, Ctrl+B, automatic interrupted-capture recovery, and safe
  retry after a failed snapshot.
- `bash test-worker-tuning.sh`: engine policy plus actual ffmpeg capture/chunking of 321
  seconds of PCM; exact sample coverage; failed middle chunk; identical-audio retry;
  truncated buffer rejection; local-only recovery without engine calls; transient HTTP
  retry; filter/cleanup content preservation.
- `bash test-install-autostart.sh`: installation and login startup regression checks.

The Fn recovery test fails against the pre-fix controller. The old filter reproduces loss
of all speech after a boilerplate phrase on a single line. These are verified defects;
the user's particular historical interruption cannot be uniquely attributed without a
recording from that event.

Live verification on 2026-09-27:

- Groq recognized a generated Russian recording of 442.847 seconds (7:23), in four
  chunks. All 11 control words, the continuation after “Спасибо за просмотр”, and the
  final sentence survived. This is a controlled synthetic-speech check, not a claim of
  perfect recognition of every real speaker.
- The installed Hammerspoon handled posted native Fn press/release events and saved
  2.921 seconds from the actual MacBook microphone. Disabling the native event tap was
  recovered by its watchdog. Native Ctrl+B launched a new job from the same saved WAV
  and completed recognition.
- End-to-end insertion into TextEdit was not confirmed: the foreground application changed
  during verification, so further global test keystrokes were stopped. The window-change
  clipboard behavior is covered by the controller tests. Physical-key use while talking
  in the owner's normal workflow still provides the final human acceptance check.

For current runtime diagnostics, use the bundled Hammerspoon CLI:

```bash
~/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'return hs.json.encode(dictationStatus())'
```

`dictationStatus()` reports mode, lifecycle state, recorder liveness, buffer size, pending
capture recovery, current job directory, Toggle limit, and event-tap health without exposing
audio/text.

Live verification on 2026-10-03:

- Posted native Fn events started and stopped PTT and started Toggle in the installed
  Hammerspoon. Reloading during Toggle saved 1.396 seconds from the actual microphone,
  cleared the journal, and restarted the recorder without recognition.
- Advancing only the controller's elapsed-time clock exercised the ten-minute warning
  and automatic stop in the real app. The worker saved 1.812 seconds of actual audio with
  `status=saved`, no engine call, and no chunks. The real clock was restored; the app
  returned to idle with microphone and Fn enabled.
- A short synthesized Russian phrase transcribed successfully through the installed
  worker launched by Hammerspoon using its existing Groq configuration. These checks did
  not paste text into the owner's foreground app.
