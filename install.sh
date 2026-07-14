#!/bin/bash
# BEGIN_USAGE
# install.sh — one-command installer for the whisper_own macOS dictation tool.
#
# Replaces the manual README steps with an idempotent wizard: detect hardware, install
# brew deps, build/locate whisper.cpp (Metal), download models, set up the optional Groq
# key, deploy the scripts, register Hammerspoon at login, and smoke-test the pipeline.
#
# Flags:
#   --yes         assume "yes" to the confirmation prompt (non-interactive)
#   --skip-brew   do not install Homebrew formulae/casks
#   --skip-local  do not build/clone whisper.cpp (Groq-only or already built)
#   --reinstall   force re-download of models and rebuild of whisper.cpp
#   --no-smoke    skip the final smoke test
#   --autostart-only  only repair/register Hammerspoon login startup
#   --dry-run     print every action without changing anything
#   -h, --help    show this help
# END_USAGE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '/^# BEGIN_USAGE$/,/^# END_USAGE$/p' "${BASH_SOURCE[0]}" |
    sed '1d;$d;s/^# \{0,1\}//'
}

# ---- flags ----
ASSUME_YES=0
SKIP_BREW=0
SKIP_LOCAL=0
REINSTALL=0
NO_SMOKE=0
AUTOSTART_ONLY=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --yes | -y) ASSUME_YES=1 ;;
    --skip-brew) SKIP_BREW=1 ;;
    --skip-local) SKIP_LOCAL=1 ;;
    --reinstall) REINSTALL=1 ;;
    --no-smoke) NO_SMOKE=1 ;;
    --autostart-only) AUTOSTART_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$arg" >&2
      usage
      exit 2
      ;;
  esac
done

# ---- paths (overridable via env, mostly for testing) ----
HAMMERSPOON_DIR="${HAMMERSPOON_DIR:-$HOME/.hammerspoon}"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"
MODEL_DIR="${MODEL_DIR:-$HOME/.local/share/whisper}"
WHISPER_DIR="${WHISPER_DIR:-$HOME/.local/opt/whisper.cpp}"
WHISPER_BUILD="${WHISPER_BUILD:-$WHISPER_DIR/build-metal}"
WHISPER_PATH="${WHISPER_PATH:-$WHISPER_BUILD/bin/whisper-cli}"
PROFILE_PATH="${DICTATION_PROFILE:-$MODEL_DIR/profile.env}"
GROQ_KEY_PATH="${GROQ_KEY_PATH:-$HAMMERSPOON_DIR/groq_api_key}"
VAD_MODEL_PATH="${VAD_MODEL_PATH:-$MODEL_DIR/ggml-silero-v5.1.2.bin}"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp"
LOG_FILE="$MODEL_DIR/install.log"
HAMMERSPOON_LAUNCH_LABEL="${HAMMERSPOON_LAUNCH_LABEL:-local.whisper-own.hammerspoon}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
HAMMERSPOON_LAUNCH_PLIST="${HAMMERSPOON_LAUNCH_PLIST:-$LAUNCH_AGENTS_DIR/$HAMMERSPOON_LAUNCH_LABEL.plist}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
OPEN_BIN="${OPEN_BIN:-/usr/bin/open}"
PGREP_BIN="${PGREP_BIN:-/usr/bin/pgrep}"
HAMMERSPOON_START_TIMEOUT="${HAMMERSPOON_START_TIMEOUT:-10}"

# ---- output helpers ----
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

log() {
  printf '%s\n' "$*"
  [ -d "$MODEL_DIR" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
info() { log "${C_BOLD}==>${C_RESET} $*"; }
ok() { log "${C_GREEN}✓${C_RESET} $*"; }
warn() { log "${C_YELLOW}!${C_RESET} $*"; }
die() {
  log "${C_RED}✗ $*${C_RESET}"
  exit 1
}

# run a command, or just print it under --dry-run
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# ---- steps ----
require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    warn "This installer is macOS-only. On other systems, see the Manual install section of README.md."
    exit 0
  fi
  if [ "$(id -u)" = "0" ]; then
    die "Do not run this installer as root."
  fi
  ok "macOS detected ($(uname -m))"
}

detect_brew_prefix() {
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew is required. Install it with:"
    warn '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    die "Homebrew not found."
  fi
  BREW_PREFIX="$(brew --prefix)"
  FFMPEG_BIN="$BREW_PREFIX/bin/ffmpeg"
  FFPROBE_BIN="$BREW_PREFIX/bin/ffprobe"
  ok "Homebrew prefix: $BREW_PREFIX"
}

run_autodetect() {
  info "Detecting hardware and writing the profile"
  run mkdir -p "$MODEL_DIR"
  run env MODEL_DIR="$MODEL_DIR" PROFILE_PATH="$PROFILE_PATH" \
    bash "$SCRIPT_DIR/dictation-detect.sh" --write-profile "$PROFILE_PATH"

  # Append the ffmpeg/ffprobe paths (brew --prefix); dictation-detect.sh deliberately
  # does not hardcode these. Idempotent: the profile is rewritten fresh each run.
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] append FFMPEG_PATH=%s / FFPROBE_PATH=%s to %s\n' "$FFMPEG_BIN" "$FFPROBE_BIN" "$PROFILE_PATH"
  else
    {
      printf '\n# --- ffmpeg paths (added by install.sh via brew --prefix) ---\n'
      printf 'export FFMPEG_PATH="${FFMPEG_PATH:-%s}"\n' "$FFMPEG_BIN"
      printf 'export FFPROBE_PATH="${FFPROBE_PATH:-%s}"\n' "$FFPROBE_BIN"
    } >> "$PROFILE_PATH"
  fi
  # shellcheck disable=SC1090
  [ -f "$PROFILE_PATH" ] && . "$PROFILE_PATH" || true
  ok "Profile written: $PROFILE_PATH (tier=${DICT_TIER:-?}, order=${DICTATION_ENGINE_ORDER:-?})"
}

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  printf '\n%sPlan:%s chip=%s ram=%sGB tier=%s engines=[%s] model=%s\n' \
    "$C_BOLD" "$C_RESET" "${DICT_CHIP:-?}" "${DICT_RAM_GB:-?}" "${DICT_TIER:-?}" \
    "${DICTATION_ENGINE_ORDER:-?}" "$(basename "${REC_MODEL_PATH:-?}")"
  printf 'Proceed with install? [Y/n] '
  read -r reply
  case "$reply" in
    "" | y | Y | yes | YES) ;;
    *) die "Aborted." ;;
  esac
}

brew_has() {
  brew list --formula 2>/dev/null | grep -qx "$1" || brew list --cask 2>/dev/null | grep -qx "$1"
}

install_brew_deps() {
  if [ "$SKIP_BREW" = "1" ]; then
    warn "Skipping Homebrew deps (--skip-brew)"
    return 0
  fi
  info "Installing Homebrew dependencies"
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode command line tools missing — installing (a GUI prompt may appear)"
    run xcode-select --install || true
  fi
  local formula
  for formula in ffmpeg cmake; do
    if brew_has "$formula"; then
      ok "$formula already installed"
    else
      run brew install "$formula"
    fi
  done
  if brew_has hammerspoon; then
    ok "hammerspoon already installed"
  else
    run brew install --cask hammerspoon
  fi
}

build_or_locate_whisper() {
  if [ "$SKIP_LOCAL" = "1" ]; then
    warn "Skipping local whisper.cpp (--skip-local)"
    return 0
  fi
  if [ -x "$WHISPER_PATH" ] && [ "$REINSTALL" != "1" ]; then
    ok "whisper.cpp already built: $WHISPER_PATH"
    return 0
  fi
  info "Building whisper.cpp with Metal"
  if [ ! -d "$WHISPER_DIR/.git" ]; then
    run git clone "$WHISPER_REPO" "$WHISPER_DIR"
  fi
  run cmake -S "$WHISPER_DIR" -B "$WHISPER_BUILD" -DGGML_METAL=ON
  run cmake --build "$WHISPER_BUILD" -j --config Release
  if [ "$DRY_RUN" != "1" ] && [ ! -x "$WHISPER_PATH" ]; then
    die "whisper-cli not found after build at $WHISPER_PATH"
  fi
  ok "whisper.cpp built"
}

download_one() {
  # download_one <url> <dest>
  local url="$1" dest="$2"
  if [ -f "$dest" ] && [ "$REINSTALL" != "1" ]; then
    local size
    size="$(stat -Lf%z "$dest" 2>/dev/null || echo 0)"
    if [ "$size" -gt 102400 ]; then
      ok "$(basename "$dest") already present ($((size / 1024)) KB)"
      return 0
    fi
  fi
  run curl -fL -C - -o "$dest" "$url"
  if [ "$DRY_RUN" != "1" ]; then
    local size
    size="$(stat -Lf%z "$dest" 2>/dev/null || echo 0)"
    [ "$size" -gt 102400 ] || die "Download looks too small: $dest ($size bytes)"
    ok "$(basename "$dest") downloaded ($((size / 1024)) KB)"
  fi
}

download_models() {
  info "Downloading models"
  run mkdir -p "$MODEL_DIR"
  local model_url="${REC_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin}"
  local model_path="${REC_MODEL_PATH:-$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin}"
  download_one "$model_url" "$model_path"
  download_one "$VAD_URL" "$VAD_MODEL_PATH"
}

setup_groq_key() {
  info "Groq API key (optional cloud fast path)"
  if [ -s "$GROQ_KEY_PATH" ]; then
    ok "Groq key already present"
    return 0
  fi
  if [ "$ASSUME_YES" = "1" ] || [ "$DRY_RUN" = "1" ]; then
    warn "No Groq key configured; continuing 100% local. Add one later at $GROQ_KEY_PATH (chmod 600)."
    return 0
  fi
  printf 'Paste a Groq API key for the cloud fast path (or press Enter to skip): '
  local key
  read -rs key
  printf '\n'
  if [ -z "$key" ]; then
    warn "Skipped — running 100% local."
    return 0
  fi
  run mkdir -p "$HAMMERSPOON_DIR"
  ( umask 077; printf '%s\n' "$key" > "$GROQ_KEY_PATH" )
  run chmod 600 "$GROQ_KEY_PATH"
  ok "Groq key saved (chmod 600)"
}

install_scripts() {
  info "Installing scripts"
  run mkdir -p "$LOCAL_BIN" "$HAMMERSPOON_DIR"
  run install -m 755 "$SCRIPT_DIR/dictation-transcribe.sh" "$LOCAL_BIN/dictation-transcribe.sh"
  run install -m 644 "$SCRIPT_DIR/dictation-model-policy.sh" "$LOCAL_BIN/dictation-model-policy.sh"
  run install -m 755 "$SCRIPT_DIR/dictation-detect.sh" "$LOCAL_BIN/dictation-detect.sh"
  ok "Worker + policy + detector installed to $LOCAL_BIN"

  # Deploy init.lua, backing up any existing config first.
  local dest="$HAMMERSPOON_DIR/init.lua"
  if [ -f "$dest" ]; then
    local backup="$dest.bak-$(date '+%s')"
    run cp "$dest" "$backup"
    warn "Backed up existing Hammerspoon config to $backup"
  fi
  run cp "$SCRIPT_DIR/init.lua" "$dest"
  # Point ffmpegPath at the detected brew ffmpeg (BSD sed in-place).
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] sed ffmpegPath -> %s in %s\n' "$FFMPEG_BIN" "$dest"
  else
    sed -i '' "s|^local ffmpegPath = .*|local ffmpegPath = \"$FFMPEG_BIN\"|" "$dest"
  fi
  ok "Hammerspoon config deployed: $dest"
}

find_hammerspoon_app() {
  local candidate
  if [ -n "${HAMMERSPOON_APP:-}" ]; then
    [ -x "$HAMMERSPOON_APP/Contents/MacOS/Hammerspoon" ] ||
      die "Hammerspoon app not found or invalid at HAMMERSPOON_APP=$HAMMERSPOON_APP" >&2
    printf '%s\n' "$HAMMERSPOON_APP"
    return 0
  fi

  for candidate in "/Applications/Hammerspoon.app" "$HOME/Applications/Hammerspoon.app"; do
    if [ -x "$candidate/Contents/MacOS/Hammerspoon" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [ "$DRY_RUN" = "1" ]; then
    warn "Hammerspoon.app is not present yet; assuming /Applications/Hammerspoon.app for preview" >&2
    printf '%s\n' "/Applications/Hammerspoon.app"
    return 0
  fi
  die "Hammerspoon.app not found or its executable is invalid after installation" >&2
}

install_hammerspoon_autostart() {
  info "Registering Hammerspoon to start at login"
  local app uid target tmp app_xml log_xml
  app="$(find_hammerspoon_app)"
  uid="$(id -u)"
  target="gui/$uid/$HAMMERSPOON_LAUNCH_LABEL"

  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] write %s (RunAtLoad -> %s)\n' "$HAMMERSPOON_LAUNCH_PLIST" "$app"
    reload_hammerspoon_launch_agent "$uid" "$target"
    return 0
  fi

  mkdir -p "$(dirname "$HAMMERSPOON_LAUNCH_PLIST")" "$MODEL_DIR"
  tmp="$HAMMERSPOON_LAUNCH_PLIST.tmp.$$"
  app_xml="$(printf '%s' "$app" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
  log_xml="$(printf '%s' "$MODEL_DIR/hammerspoon-launch.log" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HAMMERSPOON_LAUNCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$OPEN_BIN</string>
    <string>-gj</string>
    <string>$app_xml</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$log_xml</string>
  <key>StandardErrorPath</key>
  <string>$log_xml</string>
</dict>
</plist>
EOF
  plutil -lint "$tmp" >/dev/null
  chmod 644 "$tmp"
  mv "$tmp" "$HAMMERSPOON_LAUNCH_PLIST"

  reload_hammerspoon_launch_agent "$uid" "$target"
  wait_for_hammerspoon_start
  ok "Hammerspoon autostart registered: $HAMMERSPOON_LAUNCH_PLIST"
}

reload_hammerspoon_launch_agent() {
  local uid="$1" target="$2"
  if [ "$DRY_RUN" = "1" ]; then
    run "$LAUNCHCTL_BIN" bootout "$target" || true
  else
    "$LAUNCHCTL_BIN" bootout "$target" >/dev/null 2>&1 || true
  fi
  run "$LAUNCHCTL_BIN" enable "$target"
  run "$LAUNCHCTL_BIN" bootstrap "gui/$uid" "$HAMMERSPOON_LAUNCH_PLIST"
  run "$LAUNCHCTL_BIN" kickstart -k "$target"
}

wait_for_hammerspoon_start() {
  local waited=0
  while ! "$PGREP_BIN" -x Hammerspoon >/dev/null 2>&1; do
    if [ "$waited" -ge "$HAMMERSPOON_START_TIMEOUT" ]; then
      die "Hammerspoon did not start within ${HAMMERSPOON_START_TIMEOUT}s; check $MODEL_DIR/hammerspoon-launch.log"
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

print_permissions() {
  info "Permissions"
  cat <<EOF
Grant Hammerspoon two permissions (System Settings → Privacy & Security):
  • Accessibility  — so it can paste with Cmd+V and read the fn key
  • Microphone     — so ffmpeg can record
Then open Hammerspoon and Reload Config.
EOF
  if [ "$ASSUME_YES" != "1" ] && [ "$DRY_RUN" != "1" ]; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true
  fi
}

run_smoke_test() {
  if [ "$NO_SMOKE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
    warn "Skipping smoke test"
    return 0
  fi
  info "Smoke test"
  local aiff="/tmp/dictation-smoke.aiff" wav="/tmp/dictation-smoke.wav"
  say -o "$aiff" "Testing dictation one two three." || {
    warn "say failed; skipping smoke test"
    return 0
  }
  "$FFMPEG_BIN" -y -hide_banner -loglevel error -i "$aiff" -ar 16000 -ac 1 "$wav" || {
    warn "ffmpeg failed; skipping smoke test"
    return 0
  }
  DICTATION_PROFILE="$PROFILE_PATH" "$LOCAL_BIN/dictation-transcribe.sh" "$wav" >/dev/null 2>&1 || true
  local status text
  status="$(cat /tmp/dictation.status 2>/dev/null || echo '?')"
  text="$(cat /tmp/dictation.txt 2>/dev/null || echo '')"
  if [ "$status" = "done" ] && [ -n "$text" ]; then
    ok "Smoke test passed: \"$text\" (engine=$(cat /tmp/dictation.engine 2>/dev/null || echo '?'))"
  else
    warn "Smoke test did not complete cleanly (status=$status). Check ~/.local/share/whisper/last.log"
  fi
}

link_skill() {
  local target="$SCRIPT_DIR/skill/whisper-dictation"
  [ -d "$target" ] || return 0
  local link_dir="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
  local link="$link_dir/whisper-dictation"
  if [ -L "$link" ] || [ -e "$link" ]; then
    ok "Claude Code skill already linked"
    return 0
  fi
  local do_link=0
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] ln -s %s %s\n' "$target" "$link"
    return 0
  elif [ "$ASSUME_YES" = "1" ]; then
    do_link=1
  else
    printf 'Link the Claude Code skill into %s? [y/N] ' "$link_dir"
    read -r reply
    case "$reply" in y | Y | yes | YES) do_link=1 ;; esac
  fi
  if [ "$do_link" = "1" ]; then
    run mkdir -p "$link_dir"
    run ln -s "$target" "$link"
    ok "Claude Code skill linked: $link"
  fi
}

final_summary() {
  printf '\n%s✓ Installation complete%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
  cat <<EOF
  worker:    $LOCAL_BIN/dictation-transcribe.sh
  config:    $HAMMERSPOON_DIR/init.lua
  autostart: $HAMMERSPOON_LAUNCH_PLIST
  profile:   $PROFILE_PATH
  models:    $MODEL_DIR
Next: open Hammerspoon, grant Accessibility + Microphone, Reload Config, then hold fn and speak.
EOF
}

main() {
  [ "$DRY_RUN" = "1" ] && warn "DRY RUN — no changes will be made"
  require_macos
  if [ "$AUTOSTART_ONLY" = "1" ]; then
    install_hammerspoon_autostart
    return 0
  fi
  detect_brew_prefix
  run_autodetect
  confirm
  install_brew_deps
  build_or_locate_whisper
  download_models
  setup_groq_key
  install_scripts
  install_hammerspoon_autostart
  print_permissions
  run_smoke_test
  link_skill
  final_summary
}

main
