# Troubleshooting playbook

Run `../scripts/whisper-doctor.sh` first — it checks every part read-only. Then match the
symptom below. Each row names the exact file to look at.

## Nothing is typed / no text appears

- **Clue:** `dictationFnTap:isEnabled()` in the Hammerspoon console — should be `true`.
- **Cause & fix:** almost always **Accessibility** isn't granted (System Settings →
  Privacy & Security → Accessibility → Hammerspoon), or macOS disabled the `fn` event tap.
  The **hotkey watchdog** re-arms the tap every 2 s and on wake; if not, grant Accessibility
  and Reload Config. Confirm the run finished: `cat /tmp/dictation.status` → `done`.

## The first syllable is clipped

- **Clue:** `ls -l /tmp/dictation-buffer.raw` — the size must climb every second.
- **Cause & fix:** the recorder wasn't running at press time (a cold start). The recorder
  watchdog restarts it within ~12 s; a headset plug/unplug or a wake also restarts it. Check
  **Microphone** permission if it never grows.

## ffmpeg not found (often on Apple Silicon)

- **Clue:** `/tmp/dictation.err`, and `grep ffmpegPath ~/.hammerspoon/init.lua`.
- **Cause & fix:** default path is `/usr/local/bin/ffmpeg` (Intel). On Apple Silicon it's
  `/opt/homebrew/bin/ffmpeg`. `install.sh` rewrites `ffmpegPath`; `init.lua` also falls back
  to `command -v ffmpeg`. Fix the path or re-run the installer.

## Russian dictation ends in a hallucinated tail ("Продолжение следует")

- **Clue:** `~/.local/share/whisper/last.log` — compare the `raw`, `cleaned`, and
  `llm-cleaned` stages.
- **Cause & fix:** confirm the **VAD model** exists (`ggml-silero-v5.1.2.bin`); add the
  phrase stem to `HALLUCINATION_PHRASES`; and/or enable the LLM pass with
  `DICTATION_LLM_CLEANUP=1` to catch tails contextually. The five defenses are VAD, `-mc 0`,
  `-sns`, the static filter, and the Groq-Llama pass.

## Groq is slow, failing, or the key is missing → silent fallback

- **Clue:** `cat /tmp/dictation.engine` — with no/invalid key it reads `whisper.cpp`.
- **Cause & fix:** the dispatcher falls back to local whisper.cpp automatically. The key must
  be at `~/.hammerspoon/groq_api_key`, `chmod 600`. `whisper-doctor.sh` does a 2 s auth
  check when a key is present. To go fully local on purpose, set
  `DICTATION_ENGINE_ORDER="whisper.cpp"`.

## Wrong `WHISPER_PATH` → local fails but Groq works

- **Clue:** `/tmp/dictation.err` shows "whisper.cpp unavailable".
- **Cause & fix:** the binary or model is missing → `transcribe_local` returns rc 2 and the
  dispatcher skips to Groq. Fix `WHISPER_PATH`/`MODEL_PATH` or re-run `install.sh`.

## Very short clips do nothing

- **Clue:** `cat /tmp/dictation.status` → `ignored`.
- **Cause:** the tap was under `minDurationSeconds` (0.5 s) or the audio under
  `MIN_AUDIO_SECONDS` (0.75 s). Intentional — hold a little longer.

## Out of scope

File transcription, subtitles (SRT/VTT), batch/folder processing, and non-macOS runtimes are
not part of this tool. Don't try to make it do those.
