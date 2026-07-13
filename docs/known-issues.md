# Known issues & troubleshooting

Each symptom lists the file to look at.

## Russian hallucinations on pauses («Продолжение следует…»)

On silence, Whisper emits YouTube-subtitle boilerplate and can drop real speech doing it.
In Russian the usual culprits are **«Продолжение следует»**, **«Спасибо за просмотр»**,
**«Субтитры сделал DimaTorzok»**, **«Редактор субтитров …»**, **«Подписывайтесь на
канал»**, and in English **"Thanks for watching"**, **"Subtitles by …"**. Context
contamination between 30-second windows turns one hallucination into a truncated
transcript.

Five defenses, all implemented here:

1. **Silero VAD** (`--vad --vad-model`) — cuts silence *before* decoding, so Whisper never
   sees the pauses it hallucinates on;
2. **`-mc 0`** — carries no decoded text as context into the next window;
3. **`-sns`** — suppresses non-speech tokens;
4. **static post-filter** (`clean_hallucinations`) — strips the known phrase stems from the
   final text of *both* engines; tune it via `HALLUCINATION_PHRASES`;
5. **optional Groq-Llama pass** (`DICTATION_LLM_CLEANUP=1`) — removes a tail the regex missed,
   contextually.

_Evidence:_ `~/.local/share/whisper/last.log` shows the `raw`, `cleaned` and `llm-cleaned`
stages, so you can see which defense caught it.

## The fn key stops working (after sleep, or under load)

macOS silently disables global event taps after sleep, under heavy load, or when secure
input is active. The **hotkey watchdog** re-arms the `fn` tap every 2 s and on
`systemDidWake`, so dictation recovers without a manual reload. If it still won't fire,
confirm the tap is alive:

```lua
-- Hammerspoon console
dictationFnTap:isEnabled()   -- should be true
```

and check **Accessibility** is granted (below). This is separate from the ffmpeg recorder
watchdog — see [architecture.md](architecture.md#two-independent-watchdogs).

## Nothing is typed / no audio

Almost always a permission. Grant Hammerspoon **Accessibility** (to paste and read `fn`) and
**Microphone** (to record) in System Settings → Privacy & Security, then Reload Config.

## The first syllable is clipped

The recorder wasn't running when you pressed `fn` (a cold start). Check the buffer is
growing:

```bash
ls -l /tmp/dictation-buffer.raw      # size should climb every second
```

If it's stalled, the recorder watchdog restarts it within ~12 s; a headset plug/unplug or a
wake also restarts it.

## ffmpeg not found (especially on Apple Silicon)

The default ffmpeg path is `/usr/local/bin/ffmpeg` (Intel Homebrew). On Apple Silicon it's
`/opt/homebrew/bin/ffmpeg`. `install.sh` rewrites `ffmpegPath` in `init.lua` to the detected
path, and `init.lua` also falls back to `command -v ffmpeg` if the hardcoded path is
missing.

## Groq is slow, failing, or you have no key → silent fallback

No key, an invalid key, or any Groq failure falls back to local whisper.cpp automatically.
Confirm what ran:

```bash
cat /tmp/dictation.engine     # with no key this reads: whisper.cpp
tail -n 20 ~/.local/share/whisper/last.log
```

The key must be at `~/.hammerspoon/groq_api_key`, `chmod 600`.

## No VAD model → runs without VAD

If `ggml-silero-v5.1.2.bin` is missing, the local engine logs "running without VAD" to
`/tmp/dictation.err` and continues (the other four hallucination defenses still apply).
VAD models live in `ggml-org/whisper-vad` — the main `whisper.cpp` repo path 404s.

## Wrong `WHISPER_PATH` → local fails, Groq still works

If the whisper-cli binary or model is missing, `transcribe_local` returns "unavailable"
(rc 2) and the dispatcher skips to Groq. Fix `WHISPER_PATH`/`MODEL_PATH` or re-run
`install.sh`.

## Very short clips are ignored

A tap shorter than `minDurationSeconds` (0.5 s) or audio shorter than `MIN_AUDIO_SECONDS`
(0.75 s) yields `status=ignored` and nothing is pasted or logged to history. This is
intentional.

## Diagnostics cheat-sheet

```bash
cat /tmp/dictation.status                     # running | done | ignored | error:<reason>
cat /tmp/dictation.engine                     # which engine won
cat /tmp/dictation.err                        # stderr of the current run
tail -n 40 ~/.local/share/whisper/last.log    # raw / cleaned / llm-cleaned stages
ls -l /tmp/dictation-buffer.raw               # is the recorder growing?
afplay /tmp/dictation-last.wav                # what did it actually hear?
```

## Not covered here

Subtitle generation, speaker diarization, file/URL batch transcription, SRT/VTT output, and
non-macOS runtimes are **out of scope** — this is a macOS push-to-talk dictation tool only.
