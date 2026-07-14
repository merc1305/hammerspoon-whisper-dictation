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
| C3 | toggle-mode | ✅ done | triggerMode/toggleMaxSeconds; menu-bar Settings switches PTT/toggle immediately and persists via hs.settings; toggleCapture() reuses start/finishCapture; guards intact. Live PTT/toggle → MANUAL. |
| C4 | hotkey-watchdog | ✅ done | rearmHotkeyTapIfDisabled() + dictationHotkeyWatchdog timer + systemDidWake hook; logic unit test green. Live sleep/wake re-arm → MANUAL. |
| C2 | menubar-icon | ✅ done | 3-state icon + history dropdown; menu logic unit test green (header/rows/copy/clear/reload, UTF-8 preview); full init.lua load-under-stub green. Live icon colors/click → MANUAL. |
| D1 | installer-wizard | ✅ done | install.sh; all criteria a-i green in sandbox (exit0/idempotent/--reinstall/755/backup/key600/smoke=done/Linux-exit/Apple-Silicon-sed). **Deviation:** model URL org ggml-org→**ggerganov** (plan's ggml-org/whisper.cpp 401s; ggerganov returns 200/206 — matches original README). +`--dry-run` flag. |
| D3 | docs | ✅ done | 6 docs + index; README → landing page; link/scope/symbol cross-checks green; fallback confirmed (no key→engine=whisper.cpp). 2 links to skill/ resolve once D2 lands. |
| D2 | skill-packaging | ✅ done | skill/whisper-dictation/{SKILL.md,references×3,whisper-doctor.sh}; frontmatter valid (name==folder, desc 692<1024, triggers+scope-guards); doctor read-only 9PASS/0FAIL exit0; 0 broken links (32 checked); install.sh link_skill idempotent. |

## Invariants being guarded
- Ring buffer math in startCapture/finishCapture — untouched.
- Recorder stop only via SIGINT (interrupt()), never SIGKILL.
- IPC contract: /tmp/dictation.{status,txt,err}, pid file. init.lua polls only status.
- §2.7: `printf '%s' "$ENGINE" > "$ENGINE_PATH"` must survive B1 & C1 rewrites of success branch.

## Final integration & reviews (all green)
- **12/12 tasks** implemented, verified, committed on `feature/whisper-upgrade` (14 commits).
- Clean install from scratch (sandbox + dry-run): exit 0, idempotent, `--reinstall` forces, smoke=done.
- E2E across all engines/fallbacks (groq / whisper.cpp / mlx-skip / broken-key-fallback / forced-lang): all `done`, RU+EN preserved, history grows.
- init.lua loads fully under stub: menubar built, PTT/toggle switch, both watchdogs armed, all reload-surviving globals present.
- **/verify:** PASS (deployed worker driven E2E + 3 probes held).
- **/code-review:** 1 low-sev finding (menu build on corrupted history `ts`) → fixed; no correctness/security bugs survived.
- **/security-review:** CLEAN — no secrets in history/temp/logs; key 600 + HTTPS-only; injection-safe (quoted vars, `%q`, validated pid); transcribed text never exec'd.
- **/simplify:** memoized `audio_duration_seconds` (3×→1× ffprobe); rest already clean.

## Deviations from the plan (documented, evidence-backed)
1. **B1 LLM model:** default `llama-3.1-8b-instant` → **`llama-3.3-70b-versatile`** — 8b reliably translated RU↔EN and dropped content, failing the bilingual "meaning intact" criterion; 70b is faithful and still sub-second. Overridable via `GROQ_LLM_MODEL`. Timeout 2→4 for headroom.
2. **D1 model URL org:** `ggml-org/whisper.cpp` → **`ggerganov/whisper.cpp`** — the plan-mandated org 401s for these `.bin` files (verified); ggerganov returns 200/206 and matches the original README. Criterion (e) requires a *downloadable* URL.
3. **A4 bugfix:** `${arr[@]}` under `set -u` on macOS bash 3.2 errors on empty arrays → switched vad_args/lang_args to `${arr[@]+"${arr[@]}"}` (also fixed a pre-existing latent bug: local engine broke without a VAD model).
4. **D1 extra flag:** added `--dry-run` (additive) for safe previewing.

## BLOCKERS
(none — 100% complete)

## Remaining for the human
Six live checks in [MANUAL-ACCEPTANCE.md](MANUAL-ACCEPTANCE.md) (fn key / menu-bar pixels /
sleep / paste into a third-party app — not drivable headless). The transcription worker is
already deployed to `~/.local/bin`; only `init.lua` needs deploying (`./install.sh`) +
a Hammerspoon Reload for the UI features. Pushing / opening a PR is left to the human.
