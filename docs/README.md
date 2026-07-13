# whisper_own documentation

Push-to-talk voice dictation for macOS: **hold `fn` — speak — release — the text is
pasted into whatever app you're in.** Built from Hammerspoon + ffmpeg + whisper.cpp, with
an optional Groq API fast path. macOS only.

**Start here → [install-mac.md](install-mac.md).**

| Doc | What's inside |
|---|---|
| [install-mac.md](install-mac.md) | Requirements, one-command install, manual fallback, permissions, smoke test, uninstall |
| [architecture.md](architecture.md) | The ring buffer, the two components, the IPC files, the engine dispatcher, post-processing, history + menu bar, the two watchdogs |
| [model-policy.md](model-policy.md) | Why there's no model menu; the tier→engine/model table; turbo vs large-v3; RU+EN autodetect |
| [speed-tuning.md](speed-tuning.md) | The latency budget and every knob that moves it |
| [known-issues.md](known-issues.md) | Whisper hallucinations and the five defenses; the fn tap after sleep; permissions; fallback; a diagnostics cheat-sheet |
| [cost-comparison.md](cost-comparison.md) | Groq free tier vs OpenAI vs fully local, with "Last verified" dates |

The Claude Code skill in [`../skill/whisper-dictation/`](../skill/whisper-dictation/) points
back into these documents for install, configure and debug flows.
