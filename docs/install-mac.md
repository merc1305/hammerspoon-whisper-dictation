# Installing on macOS

**macOS only.** On any other OS the installer exits cleanly and points you here — there is
no cross-platform runtime.

## Requirements

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- ~1.5 GB free disk (the speech model is ~560 MB)

## One command

```bash
./install.sh
```

`install.sh` is idempotent — safe to re-run. It:

1. detects the machine and writes `~/.local/share/whisper/profile.env`
   (via `dictation-detect.sh`), then appends `FFMPEG_PATH`/`FFPROBE_PATH` from
   `brew --prefix` (Intel `/usr/local`, Apple Silicon `/opt/homebrew`);
2. installs the Homebrew parts if missing: `ffmpeg`, `cmake`, and the `hammerspoon` cask;
3. builds **whisper.cpp with Metal** into `~/.local/opt/whisper.cpp/build-metal` (skipped
   with `--skip-local` or if already built) → `WHISPER_PATH`;
4. downloads the models into `~/.local/share/whisper`:
   - speech model `ggml-large-v3-turbo-q5_0.bin`
     (`https://huggingface.co/ggerganov/whisper.cpp/resolve/main/…`),
   - Silero VAD `ggml-silero-v5.1.2.bin`
     (`https://huggingface.co/ggml-org/whisper-vad/resolve/main/…` — VAD models live in
     the `whisper-vad` repo, not the main one);
5. optionally stores a **Groq API key** at `~/.hammerspoon/groq_api_key` (`chmod 600`);
6. installs the worker to `~/.local/bin/dictation-transcribe.sh` (plus the policy library
   and detector), backs up any existing `~/.hammerspoon/init.lua`, deploys the new one,
   and rewrites its `ffmpegPath` to the detected ffmpeg;
7. registers `~/Library/LaunchAgents/local.whisper-own.hammerspoon.plist`, starts
   Hammerspoon now, and starts it automatically after every macOS login;
8. opens the two permission panes;
9. runs a **smoke test** (`say` → wav → worker) and checks `status=done`.

Flags: `--yes` (non-interactive), `--skip-brew`, `--skip-local` (Groq-only / already
built), `--reinstall` (force re-download + rebuild), `--no-smoke`, `--autostart-only`
(repair login startup without reinstalling anything), `--dry-run` (preview, change nothing).

## Permissions

Grant Hammerspoon two permissions in **System Settings → Privacy & Security**:

- **Accessibility** — so it can send `Cmd+V` and read the `fn` key
  (`Privacy & Security → Accessibility`);
- **Microphone** — so ffmpeg can record
  (`Privacy & Security → Microphone`).

Then open Hammerspoon and **Reload Config**.

The installer owns the `local.whisper-own.hammerspoon` LaunchAgent instead of relying on
Hammerspoon's preference checkbox alone. This keeps startup deterministic if macOS loses
the corresponding background-item registration after an app update or reboot.

## Smoke test by hand

```bash
say -o /tmp/s.aiff "проверка диктовки, this is a test."
/usr/local/bin/ffmpeg -y -i /tmp/s.aiff -ar 16000 -ac 1 /tmp/s.wav   # /opt/homebrew on Apple Silicon
~/.local/bin/dictation-transcribe.sh /tmp/s.wav
cat /tmp/dictation.status   # -> done
cat /tmp/dictation.txt      # -> the recognized text (Cyrillic + Latin, not translated)
cat /tmp/dictation.engine   # -> groq | whisper.cpp | mlx
```

## Manual install (fallback)

If you'd rather not use `install.sh`:

```bash
# 1. the parts
brew install ffmpeg cmake
brew install --cask hammerspoon

# 2. build whisper.cpp with Metal (or point WHISPER_PATH at an existing build)
git clone https://github.com/ggml-org/whisper.cpp ~/.local/opt/whisper.cpp
cd ~/.local/opt/whisper.cpp
cmake -B build-metal -DGGML_METAL=ON
cmake --build build-metal -j --config Release

# 3. models
mkdir -p ~/.local/share/whisper
curl -fL -o ~/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
curl -fL -o ~/.local/share/whisper/ggml-silero-v5.1.2.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

# 4. scripts
install -m 755 dictation-transcribe.sh ~/.local/bin/dictation-transcribe.sh
install -m 644 dictation-model-policy.sh ~/.local/bin/dictation-model-policy.sh
cp init.lua ~/.hammerspoon/init.lua        # back up any existing config first
#   on Apple Silicon, set ffmpegPath in init.lua to /opt/homebrew/bin/ffmpeg

# 5. optional Groq key (cloud fast path)
umask 077; printf '%s\n' "YOUR_GROQ_KEY" > ~/.hammerspoon/groq_api_key

# 6. optional: write the hardware profile
bash dictation-detect.sh --write-profile
```

Then grant permissions (above) and Reload Config.

## Uninstalling

```bash
rm -f ~/.local/bin/dictation-transcribe.sh ~/.local/bin/dictation-model-policy.sh \
      ~/.local/bin/dictation-detect.sh
launchctl bootout "gui/$(id -u)/local.whisper-own.hammerspoon" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/local.whisper-own.hammerspoon.plist
rm -rf ~/.local/share/whisper ~/.local/opt/whisper.cpp
# restore your previous Hammerspoon config from the ~/.hammerspoon/init.lua.bak-* backup
```

Trouble? See [known-issues.md](known-issues.md).
