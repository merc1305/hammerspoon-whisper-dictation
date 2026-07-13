---
name: whisper-dictation
description: Installs, configures, and debugs the whisper_own push-to-talk voice dictation tool for macOS (Hammerspoon + ffmpeg ring buffer + whisper.cpp, with an optional Groq API fast path). Use when the user wants to set up or fix hold-fn-to-dictate voice typing on their Mac — e.g. "настрой диктовку", "диктовка не вставляет текст", "voice dictation mac", "переключи на локальный движок / на Groq", "включи toggle-режим", or complains that Russian dictation ends in a hallucinated "Продолжение следует". NOT for transcribing existing audio/video files, generating subtitles (SRT/VTT), batch or file-to-text conversion, or any non-macOS system — this skill only manages the live fn-key dictation setup.
---

# whisper-dictation

Manage the **whisper_own** macOS push-to-talk dictation tool: hold `fn`, speak, release,
and the transcribed text is pasted into the active app.

## What it is

Two components talking through files in `/tmp`:

- **`init.lua`** (Hammerspoon) — owns the mic, the `fn` key, a continuous ffmpeg **ring
  buffer** (`/tmp/dictation-buffer.raw`), the on-screen dot, the menu bar, and two
  watchdogs. It launches the worker and polls `/tmp/dictation.status`.
- **`dictation-transcribe.sh`** (the worker) — cuts the audio slice, dispatches the
  transcription engines (`mlx | whisper.cpp | groq`), post-processes the text, and writes
  the result files.

On a weak Mac Groq is the sub-second fast path; local whisper.cpp is the offline fallback.

## Hard invariants (do NOT break)

- **The ring-buffer math is sacred.** Do not touch the offset / pre-roll arithmetic in
  `startCapture` / `finishCapture` in `init.lua`. Every feature is additive to it.
- **Stop the recorder only with SIGINT** (`interrupt()`), never SIGKILL — SIGKILL
  truncates the recording tail.
- **The IPC contract is fixed:** `/tmp/dictation.status` (`running|done|ignored|error:<reason>`),
  `/tmp/dictation.txt`, `/tmp/dictation.err`, `/tmp/dictation-whisper.pid`. `init.lua` polls
  only `status`. The shell side may add new files (e.g. `/tmp/dictation.engine`).
- **Push-to-talk is the default** trigger mode; the on-screen dot stays.
- **macOS only.** Never add cross-platform, subtitle, diarization, or file-batch behavior.

## Tasks (progressive disclosure)

| Goal | Do this |
|---|---|
| Install / reinstall | Run `../../install.sh` (idempotent; `--yes`, `--dry-run`, `--skip-local`, `--reinstall`). See [../../docs/install-mac.md](../../docs/install-mac.md). |
| Debug "it broke" | Run `scripts/whisper-doctor.sh` first, then [references/troubleshooting.md](references/troubleshooting.md). |
| Change a setting | See [references/config.md](references/config.md). |
| Understand engine/model choice | See [references/engine-policy.md](references/engine-policy.md). |

### INSTALL

Run `../../install.sh` (from the repo root). It detects the hardware, installs the parts,
builds/locates whisper.cpp, downloads the models, deploys the scripts (backing up any
existing `~/.hammerspoon/init.lua`), and smoke-tests. Then the user grants Hammerspoon
**Accessibility** + **Microphone** and Reloads Config.

### DEBUG

1. Run `scripts/whisper-doctor.sh` (read-only). It reports PASS/WARN/FAIL for every part.
2. Follow [references/troubleshooting.md](references/troubleshooting.md) for the symptom.
3. Inspect the evidence files:
   - `/tmp/dictation.status` — `running|done|ignored|error:<reason>`
   - `/tmp/dictation.err` — stderr of the last run
   - `/tmp/dictation.engine` — which engine won (`groq|whisper.cpp|mlx`)
   - `/tmp/dictation-last.wav` — the exact audio it heard
   - `~/.local/share/whisper/last.log` — `raw` / `cleaned` / `llm-cleaned` stages

### CONFIGURE

All knobs are in [references/config.md](references/config.md); engine/model selection is in
[references/engine-policy.md](references/engine-policy.md). **The model is automatic — there
is no model menu.** You tune trigger mode, language, cleanup, and history, not model files.

## Scope guard

This skill only manages the live `fn`-key dictation setup on macOS. If the user asks to
transcribe a file, make subtitles (SRT/VTT), batch-process a folder, or run on
Windows/Linux, say that's out of scope for this tool and stop — do not improvise it.
