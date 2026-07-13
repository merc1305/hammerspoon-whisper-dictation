# STATUS — whisper_own upgrade (feature/whisper-upgrade)

Source of truth: `plans/whisper-upgrade-plan.md`. Sequential order: A1 → A2 → A3 → B1 → A4 → C1 → C3 → C4 → C2 → D1 → D3 → D2.

## Environment (verified 2026-07-13)
- Intel Mac (x86_64) → **weak tier**, Groq-first. brew prefix `/usr/local`.
- ffmpeg `/usr/local/bin/ffmpeg` ✓  ·  ffprobe `/usr/local/bin/ffprobe`
- whisper.cpp built: `~/.local/opt/whisper.cpp/build-metal/bin/whisper-cli` ✓
- models: `ggml-large-v3-turbo-q5_0.bin` ✓, VAD `ggml-silero-v5.1.2.bin` ✓
- Groq key present at `~/.hammerspoon/groq_api_key` ✓ → cloud + LLM cleanup tested for real.
- No `mlx_whisper` (expected on weak Mac → mlx branches are skip-on-weak).
- Test WAVs (16kHz mono s16le) in scratchpad `audio/{ru,en,mixed}.{wav,raw}`.
- Lua syntax gate: `luac -p` (lua 5.4 via brew). No `hs` CLI → live Hammerspoon load is a MANUAL check.

## Task status
| # | Task | State | Notes |
|---|------|-------|-------|
| A1 | hardware-autodetect | ✅ done | detect.sh + profile.env; all 9 criteria green; commit'd |
| A2 | engine-dispatcher | ✅ done | run_engine dispatcher, transcribe_mlx, ENGINE_PATH; T1-T6 green; commit'd |
| A3 | model-policy | ✅ done | dictation-model-policy.sh + --print-policy; T1-T5 green; README table; commit'd |
| B1 | llm-postprocess | ✅ done | all 8 criteria green + runaway guard. **Deviation:** default model llama-3.1-8b-instant→**llama-3.3-70b-versatile** (8b translated RU↔EN & dropped content, failing bilingual "meaning intact"; 70b faithful, ~0.5s). timeout 2→4 for 70b headroom. Both overridable. |
| A4 | language-default | ✅ done | DICTATION_LANGUAGE=auto across all 3 engines; all criteria green incl. LLM bilingual. **Bugfix:** `${arr[@]}` under `set -u` on bash 3.2 → unbound; used `${arr[@]+"${arr[@]}"}` for vad_args (pre-existing latent bug: local engine broke without VAD) + lang_args. |
| C1 | dictation-history | ✅ done | append_history() + dictationHistoryRead(); all criteria green (JSON schema, rotation, 600, disable, fail-open, reader newest-first). Worker deployed to ~/.local/bin. |
| C3 | toggle-mode | ✅ done | triggerMode/toggleMaxSeconds; toggleCapture() reuses start/finishCapture; state-machine unit test green; guards intact. Live PTT/toggle → MANUAL. |
| C4 | hotkey-watchdog | ✅ done | rearmHotkeyTapIfDisabled() + dictationHotkeyWatchdog timer + systemDidWake hook; logic unit test green. Live sleep/wake re-arm → MANUAL. |
| C2 | menubar-icon | pending | |
| D1 | installer-wizard | pending | |
| D3 | docs | pending | |
| D2 | skill-packaging | pending | |

## Invariants being guarded
- Ring buffer math in startCapture/finishCapture — untouched.
- Recorder stop only via SIGINT (interrupt()), never SIGKILL.
- IPC contract: /tmp/dictation.{status,txt,err}, pid file. init.lua polls only status.
- §2.7: `printf '%s' "$ENGINE" > "$ENGINE_PATH"` must survive B1 & C1 rewrites of success branch.

## BLOCKERS
(none)
