# Architecture

Two components talk through a handful of files in `/tmp`. Neither parses the other's
stdout.

- **`init.lua`** (Hammerspoon) — owns the microphone, the `fn` key, the ring buffer, the
  on-screen dot, the menu bar, and the two watchdogs. It launches the worker and polls one
  status file.
- **`dictation-transcribe.sh`** (the worker) — cuts the audio slice, runs the engines,
  post-processes the text, and writes the result files.

## The ring buffer (never clip the first syllable)

ffmpeg runs **continuously**, appending raw PCM to `/tmp/dictation-buffer.raw`
(`s16le`, 16 kHz, mono → **32000 bytes/second**). Pressing `fn` does **not** start a
recording — it records the current byte offset minus a **0.5 s pre-roll**
(`prerollSeconds`), so the first syllable is already in the buffer before you speak.
Releasing `fn` waits for the tail of the phrase to flush (up to ~0.8 s), then cuts the byte
range `[start, end)` out of the buffer, wraps it into a WAV, and hands it to the worker.
Recording latency is zero because the recording never stops.

```
                    ┌─────────────────────────────────────────────┐
 microphone ──────▶ │ ffmpeg (runs 24/7, s16le 16 kHz mono)        │
                    │   └─▶ /tmp/dictation-buffer.raw (ring file)  │
                    └─────────────────────────────────────────────┘
                                      │
 fn pressed  ── remember offset ──────┤ (0.5 s pre-roll backwards)
 fn released ── wait for tail, cut [start, end) ──▶ WAV
                                      │
                    ┌─────────────────▼───────────────────────────┐
                    │ dictation-transcribe.sh                      │
                    │  dispatch engines → post-process → history   │
                    └─────────────────┬───────────────────────────┘
                                      │
                          clipboard ──▶ Cmd+V into the active app
```

The recorder is **only ever stopped with SIGINT** (`interrupt()`), so ffmpeg finalizes its
output; SIGKILL would truncate the tail. The pre-roll/offset math in `startCapture` and
`finishCapture` is the sacred core — every feature is additive to it.

## IPC files

| File | Written by | Meaning |
|---|---|---|
| `/tmp/dictation.status` | worker | `running` \| `done` \| `ignored` \| `error:<reason>` — the **only** thing `init.lua` polls |
| `/tmp/dictation.txt` | worker | the final text to paste |
| `/tmp/dictation.err` | worker | diagnostics for the current run (accumulated across engine attempts) |
| `/tmp/dictation-whisper.pid` | worker | pid, so a timed-out run can be killed |
| `/tmp/dictation.engine` | worker | **new**: the winning engine token — `groq` \| `whisper.cpp` \| `mlx` |
| `/tmp/dictation-buffer.raw` | recorder | the continuous ring buffer |
| `/tmp/dictation-last.wav` | worker | the exact audio of the last live dictation |

`init.lua` never reads `/tmp/dictation.engine` — it exists for diagnostics, the doctor and
the docs. Because the two sides communicate only through these files, the shell side can add
new files freely.

## The engine dispatcher

`DICTATION_ENGINE_ORDER` is a space-separated priority list of engine tokens —
**`mlx | whisper.cpp | groq`** (aliases `mlx-whisper`, `local`, `cloud`). The worker tries
each in turn against one shared `OUT_PATH`:

- **rc 0** → success, this engine wins, `$ENGINE` = the token verbatim;
- **rc 2** → unavailable (no binary / no model / no key) → skip silently;
- **anything else** → failure → fall back to the next engine.

The default order `groq whisper.cpp` reproduces the original Groq-first-then-local
behavior. On a weak Mac Groq is the fast path and local whisper.cpp is the always-available
offline fallback. All engines auto-detect the language and share one prompt.

## Post-processing (success branch)

```
engine dispatch → capture RAW → write /tmp/dictation.engine ($ENGINE) →
clean_hallucinations (static filter) → capture STATIC →
llm_postprocess (only if DICTATION_LLM_CLEANUP=1, fail-open) →
log_diagnostics(engine, raw, static) → append_history → status = done
```

`clean_hallucinations` strips known YouTube-subtitle boilerplate from the text of **both**
engines. `llm_postprocess` is an optional second pass through a small Groq chat model — it
fixes punctuation/case and removes fillers **without adding meaning or translating**, and
is fully *fail-open* (a missing key, timeout, HTTP error or runaway response just leaves the
static text). Every step is fail-open: the run only becomes `error` if **all** engines
failed.

## History and menu bar

Each successful dictation appends one JSON line to
`~/.local/share/whisper/history.jsonl` (oldest first, rotated to the last
`DICTATION_HISTORY_MAX` = 50 lines, `chmod 600`). `init.lua` reads it newest-first via the
global `dictationHistoryRead(limit)`; the menu-bar dropdown lists the recent dictations and
lets you copy one again (no auto-paste). The menu-bar icon has three states driven by the
same indicator choke-points as the on-screen dot: grey ring (idle), red dot (recording),
orange dot (transcribing).

## Two independent watchdogs

They are **different subsystems** — do not conflate them:

- **`dictationRecorderWatchdog`** (every 5 s) — keeps the *ffmpeg recorder* alive: restarts
  it if it died, stalled (no growth for 12 s), or the buffer needs rotating.
- **`dictationHotkeyWatchdog`** (every `hotkeyWatchdogInterval` = 2 s) — re-arms the *global
  `fn` event tap* (CGEventTap) that macOS silently disables after sleep, under load, or on
  secure input. Also re-armed on `systemDidWake`.

**Invariant:** `restartRecorder` and both watchdogs early-exit while `captureActive` is
true, so nothing is torn down mid-dictation.
