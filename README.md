# hammerspoon-whisper-dictation

Push-to-talk voice dictation for macOS: **hold `fn` — speak — release — the text is pasted into whatever app you're in.**

Built from three off-the-shelf parts — [Hammerspoon](https://www.hammerspoon.org/), ffmpeg, and [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — with an optional [Groq API](https://groq.com/) fast path. No Electron, no subscription: one Lua config and one shell script. **macOS only.**

## Why another Whisper dictation?

**1. Cold-start clipping.** If you launch the recorder when the hotkey goes down, the first half-second of speech is lost while ffmpeg opens the audio device. Here, **ffmpeg runs continuously**, appending raw PCM to a ring-buffer file. Pressing `fn` just remembers the current byte offset (minus a 0.5 s pre-roll); releasing it cuts the byte range out of the buffer. Recording latency is zero because the recording never stops.

**2. Whisper hallucinations on pauses.** On silence, Whisper emits YouTube-subtitle boilerplate — *"Thanks for watching!"*, *«Продолжение следует…»* — and can drop real speech doing it. This pipeline attacks that at five levels (Silero VAD, `-mc 0`, `-sns`, a static post-filter, and an optional Groq-Llama cleanup pass). See [docs/known-issues.md](docs/known-issues.md).

## Architecture

```
                    ┌─────────────────────────────────────────────┐
 microphone ──────▶ │ ffmpeg (runs 24/7, s16le 16 kHz mono)       │
                    │   └─▶ /tmp/dictation-buffer.raw (ring file) │
                    └─────────────────────────────────────────────┘
                                      │
 fn pressed  ── remember offset ──────┤ (0.5 s pre-roll backwards)
 fn released ── wait for tail, cut [start, end) ──▶ WAV
                                      │
                    ┌─────────────────▼───────────────────────────┐
                    │ dictation-transcribe.sh                     │
                    │   engine dispatch: mlx → whisper.cpp → groq │
                    │   → static filter → optional LLM cleanup    │
                    └─────────────────┬───────────────────────────┘
                                      │
                          clipboard ──▶ Cmd+V into the active app
```

The recorder is only ever stopped with SIGINT (graceful; ffmpeg finalizes output). SIGKILL would truncate the recording tail.

## Quick install

```bash
./install.sh          # --yes for non-interactive, --dry-run to preview
```

Detects your hardware, installs the parts, builds/locates whisper.cpp, downloads the models, wires up Hammerspoon (backing up any existing config), registers it to start automatically after login, and smoke-tests the pipeline. Then grant Hammerspoon **Accessibility** + **Microphone**, Reload Config, and hold `fn`. Full walkthrough → [docs/install-mac.md](docs/install-mac.md).

## Documentation

Full docs live in [`docs/`](docs/README.md):

- **[docs/install-mac.md](docs/install-mac.md)** — one-command install, manual fallback, permissions, smoke test, uninstall
- **[docs/architecture.md](docs/architecture.md)** — the ring buffer, the IPC files, the engine dispatcher, post-processing, history + menu bar, the two watchdogs
- **[docs/model-policy.md](docs/model-policy.md)** — no model menu; the tier→engine/model table; turbo vs large-v3; RU+EN autodetect
- **[docs/speed-tuning.md](docs/speed-tuning.md)** — the latency budget and every knob that moves it
- **[docs/known-issues.md](docs/known-issues.md)** — Whisper hallucinations and the five defenses; the fn tap after sleep; permissions; a diagnostics cheat-sheet
- **[docs/cost-comparison.md](docs/cost-comparison.md)** — Groq free tier vs OpenAI vs fully local

There's also a Claude Code skill in [`skill/whisper-dictation/`](skill/whisper-dictation/) that can install, configure and debug the tool.

## Configuration at a glance

- **Trigger:** `triggerMode = "ptt"` (hold `fn`) or `"toggle"` (tap to start/stop) in `init.lua`.
- **Language:** `DICTATION_LANGUAGE=auto` (RU+EN autodetect, no translation) — see [docs/model-policy.md](docs/model-policy.md).
- **Smart cleanup:** `DICTATION_LLM_CLEANUP=1` for an optional Groq-Llama punctuation/filler pass (fail-open) — see [docs/architecture.md](docs/architecture.md#post-processing-success-branch).
- **History:** `~/.local/share/whisper/history.jsonl` (last 50, `chmod 600`); the menu-bar dropdown lists them.
- Everything resolves as **runtime env > `profile.env` > policy > built-in defaults**. Run `dictation-transcribe.sh --print-policy` to see what's active.

## Claude Code skill

A [Claude Code](https://claude.com/claude-code) skill lives in
[`skill/whisper-dictation/`](skill/whisper-dictation/) — it can install, configure and
debug this tool (including a read-only `whisper-doctor.sh` health check). Make it available:

```bash
ln -s "$(pwd)/skill/whisper-dictation" ~/.claude/skills/whisper-dictation
```

`install.sh` offers to create this symlink for you.

## License

MIT
