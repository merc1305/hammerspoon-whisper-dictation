#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/whisper-autostart-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LAUNCHCTL_STUB="$TMP/launchctl"
cat > "$LAUNCHCTL_STUB" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "${LAUNCHCTL_LOG:?}"
case "$1" in
  bootout)
    [ "${LAUNCHCTL_FAIL_ON:-}" = "bootout" ] && exit 42
    rm -f "${LAUNCHCTL_STATE:?}"
    ;;
  enable)
    [ "${LAUNCHCTL_FAIL_ON:-}" = "enable" ] && exit 48
    rm -f "${LAUNCHCTL_DISABLED:-${LAUNCHCTL_STATE:?}.disabled}"
    ;;
  bootstrap)
    [ "${LAUNCHCTL_FAIL_ON:-}" = "bootstrap" ] && exit 43
    [ ! -e "${LAUNCHCTL_DISABLED:-${LAUNCHCTL_STATE:?}.disabled}" ] || exit 49
    [ ! -e "${LAUNCHCTL_STATE:?}" ] || exit 44
    : > "$LAUNCHCTL_STATE"
    ;;
  kickstart)
    [ "${LAUNCHCTL_FAIL_ON:-}" = "kickstart" ] && exit 45
    [ -e "${LAUNCHCTL_STATE:?}" ] || exit 46
    ;;
  print)
    [ "${LAUNCHCTL_FAIL_ON:-}" = "print" ] && exit 47
    [ -e "${LAUNCHCTL_STATE:?}" ]
    ;;
esac
EOF
chmod +x "$LAUNCHCTL_STUB"

PGREP_STUB="$TMP/pgrep"
printf '#!/bin/bash\nexit 0\n' > "$PGREP_STUB"
chmod +x "$PGREP_STUB"
export PGREP_BIN="$PGREP_STUB"

make_fake_app() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS"
  printf '#!/bin/bash\nexit 0\n' > "$app/Contents/MacOS/Hammerspoon"
  chmod +x "$app/Contents/MacOS/Hammerspoon"
}

HOME_DIR="$TMP/home & user"
APP="$HOME_DIR/Applications/Hammerspoon.app"
LAUNCHCTL_LOG="$TMP/launchctl.log"
LAUNCHCTL_STATE="$TMP/launchctl.state"
LAUNCHCTL_DISABLED="$LAUNCHCTL_STATE.disabled"
make_fake_app "$APP"
touch "$LAUNCHCTL_DISABLED"

run_install() {
  HOME="$HOME_DIR" \
  LAUNCHCTL_BIN="$LAUNCHCTL_STUB" \
  LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
  LAUNCHCTL_STATE="$LAUNCHCTL_STATE" \
  LAUNCHCTL_DISABLED="$LAUNCHCTL_DISABLED" \
  bash "$ROOT/install.sh" --autostart-only
}

old_umask="$(umask)"
umask 000
output="$(run_install)"
output="$output
$(run_install)"
umask "$old_umask"

assert_contains() {
  local haystack="$1" expected="$2"
  if ! printf '%s\n' "$haystack" | grep -Fq -- "$expected"; then
    printf 'missing expected installer output: %s\n' "$expected" >&2
    exit 1
  fi
}

assert_contains "$output" "Registering Hammerspoon to start at login"
assert_contains "$output" "$HOME_DIR/Library/LaunchAgents/local.whisper-own.hammerspoon.plist"

PLIST="$HOME_DIR/Library/LaunchAgents/local.whisper-own.hammerspoon.plist"
plutil -lint "$PLIST" >/dev/null
[ "$(plutil -extract Label raw -o - "$PLIST")" = "local.whisper-own.hammerspoon" ]
[ "$(plutil -extract RunAtLoad raw -o - "$PLIST")" = "true" ]
[ "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST")" = "/usr/bin/open" ]
[ "$(plutil -extract ProgramArguments.2 raw -o - "$PLIST")" = "$APP" ]
[ "$(plutil -extract StandardOutPath raw -o - "$PLIST")" = "$HOME_DIR/.local/share/whisper/hammerspoon-launch.log" ]
[ "$(stat -f %Lp "$PLIST")" = "644" ]
[ ! -e "$LAUNCHCTL_DISABLED" ]

TARGET="gui/$(id -u)/local.whisper-own.hammerspoon"
EXPECTED_LOG="$TMP/launchctl.expected"
printf '%s\n' \
  "bootout $TARGET" \
  "enable $TARGET" \
  "bootstrap gui/$(id -u) $PLIST" \
  "kickstart -k $TARGET" \
  "bootout $TARGET" \
  "enable $TARGET" \
  "bootstrap gui/$(id -u) $PLIST" \
  "kickstart -k $TARGET" > "$EXPECTED_LOG"
cmp -s "$EXPECTED_LOG" "$LAUNCHCTL_LOG"

help_output="$(bash "$ROOT/install.sh" --help)"
assert_contains "$help_output" "--autostart-only"
assert_contains "$help_output" "--dry-run"

# A regular install must still reach the autostart step. Dry-run keeps all external
# operations read-only while exercising the normal main() path.
normal_output="$(
  HOME="$HOME_DIR" HAMMERSPOON_APP="$APP" \
    bash "$ROOT/install.sh" --dry-run --yes --skip-brew --skip-local --no-smoke 2>/dev/null
)"
assert_contains "$normal_output" "Registering Hammerspoon to start at login"
assert_contains "$normal_output" "RunAtLoad -> $APP"

# Preview remains useful before Hammerspoon is installed.
EMPTY_HOME="$TMP/empty-home"
mkdir -p "$EMPTY_HOME"
dry_output="$(HOME="$EMPTY_HOME" bash "$ROOT/install.sh" --dry-run --autostart-only 2>/dev/null)"
assert_contains "$dry_output" "RunAtLoad -> /Applications/Hammerspoon.app"

# A bad explicit app path must fail before launchctl is touched.
set +e
bad_app_output="$(
  HOME="$EMPTY_HOME" HAMMERSPOON_APP="$TMP/missing.app" \
    LAUNCHCTL_BIN="$LAUNCHCTL_STUB" LAUNCHCTL_LOG="$TMP/bad-app.log" \
    LAUNCHCTL_STATE="$TMP/bad-app.state" \
    bash "$ROOT/install.sh" --autostart-only 2>&1
)"
bad_app_rc=$?
set -e
[ "$bad_app_rc" -ne 0 ]
assert_contains "$bad_app_output" "Hammerspoon app not found"
[ ! -e "$TMP/bad-app.log" ]

# A directory with no executable bundle payload must not pass validation merely because
# another Hammerspoon process is already running.
BROKEN_APP="$TMP/Broken Hammerspoon.app"
mkdir -p "$BROKEN_APP"
set +e
broken_app_output="$(
  HOME="$EMPTY_HOME" HAMMERSPOON_APP="$BROKEN_APP" \
    LAUNCHCTL_BIN="$LAUNCHCTL_STUB" LAUNCHCTL_LOG="$TMP/broken-app.log" \
    LAUNCHCTL_STATE="$TMP/broken-app.state" \
    bash "$ROOT/install.sh" --autostart-only 2>&1
)"
broken_app_rc=$?
set -e
[ "$broken_app_rc" -ne 0 ]
assert_contains "$broken_app_output" "Hammerspoon app not found or invalid"
[ ! -e "$TMP/broken-app.log" ]

run_failure_case() {
  local fail_on="$1"
  local case_home="$TMP/fail-$fail_on" case_log="$TMP/fail-$fail_on.log"
  local case_state="$TMP/fail-$fail_on.state" case_output rc
  make_fake_app "$case_home/Applications/Hammerspoon.app"
  set +e
  case_output="$(
    HOME="$case_home" LAUNCHCTL_BIN="$LAUNCHCTL_STUB" \
      LAUNCHCTL_LOG="$case_log" LAUNCHCTL_STATE="$case_state" \
      LAUNCHCTL_FAIL_ON="$fail_on" \
      bash "$ROOT/install.sh" --autostart-only 2>&1
  )"
  rc=$?
  set -e
  [ "$rc" -ne 0 ]
  if printf '%s\n' "$case_output" | grep -Fq "autostart registered"; then
    printf 'installer reported success after %s failure\n' "$fail_on" >&2
    exit 1
  fi
}

run_failure_case bootstrap
run_failure_case kickstart
run_failure_case enable

# A successful launchctl transaction must not claim success if the app never starts.
PGREP_FAIL_STUB="$TMP/pgrep-fail"
printf '#!/bin/bash\nexit 1\n' > "$PGREP_FAIL_STUB"
chmod +x "$PGREP_FAIL_STUB"
PROCESS_HOME="$TMP/process-home"
make_fake_app "$PROCESS_HOME/Applications/Hammerspoon.app"
set +e
process_output="$(
  HOME="$PROCESS_HOME" LAUNCHCTL_BIN="$LAUNCHCTL_STUB" \
    LAUNCHCTL_LOG="$TMP/process.log" LAUNCHCTL_STATE="$TMP/process.state" \
    PGREP_BIN="$PGREP_FAIL_STUB" HAMMERSPOON_START_TIMEOUT=0 \
    bash "$ROOT/install.sh" --autostart-only 2>&1
)"
process_rc=$?
set -e
[ "$process_rc" -ne 0 ]
assert_contains "$process_output" "Hammerspoon did not start"
if printf '%s\n' "$process_output" | grep -Fq "autostart registered"; then
  printf 'installer reported success when Hammerspoon did not start\n' >&2
  exit 1
fi

# bootout failure is intentionally tolerated when no old service is loaded.
BOOT_HOME="$TMP/bootout-home"
make_fake_app "$BOOT_HOME/Applications/Hammerspoon.app"
bootout_output="$(
  HOME="$BOOT_HOME" LAUNCHCTL_BIN="$LAUNCHCTL_STUB" \
    LAUNCHCTL_LOG="$TMP/bootout.log" LAUNCHCTL_STATE="$TMP/bootout.state" \
    LAUNCHCTL_FAIL_ON=bootout \
    bash "$ROOT/install.sh" --autostart-only
)"
assert_contains "$bootout_output" "autostart registered"

# An independently overridden plist path must get its own parent directory.
CUSTOM_HOME="$TMP/custom-home"
CUSTOM_PLIST="$TMP/custom agents/hammerspoon.plist"
make_fake_app "$CUSTOM_HOME/Applications/Hammerspoon.app"
HOME="$CUSTOM_HOME" HAMMERSPOON_LAUNCH_PLIST="$CUSTOM_PLIST" \
  LAUNCHCTL_BIN="$LAUNCHCTL_STUB" LAUNCHCTL_LOG="$TMP/custom.log" \
  LAUNCHCTL_STATE="$TMP/custom.state" \
  bash "$ROOT/install.sh" --autostart-only >/dev/null
[ -f "$CUSTOM_PLIST" ]

# Exercise both doctor outcomes without network access.
DOCTOR_HOME="$TMP/doctor-home"
DOCTOR_BIN="$DOCTOR_HOME/bin"
DOCTOR_DATA="$DOCTOR_HOME/data"
DOCTOR_PROFILE="$DOCTOR_HOME/profile.env"
mkdir -p "$DOCTOR_HOME/Applications/Hammerspoon.app" "$DOCTOR_BIN" "$DOCTOR_DATA"
for name in ffmpeg ffprobe whisper-cli; do
  printf '#!/bin/bash\nexit 0\n' > "$DOCTOR_BIN/$name"
  chmod +x "$DOCTOR_BIN/$name"
done
touch "$DOCTOR_DATA/model.bin" "$DOCTOR_DATA/vad.bin"
{
  printf 'export FFMPEG_PATH=%q\n' "$DOCTOR_BIN/ffmpeg"
  printf 'export FFPROBE_PATH=%q\n' "$DOCTOR_BIN/ffprobe"
  printf 'export WHISPER_PATH=%q\n' "$DOCTOR_BIN/whisper-cli"
  printf 'export MODEL_PATH=%q\n' "$DOCTOR_DATA/model.bin"
  printf 'export VAD_MODEL_PATH=%q\n' "$DOCTOR_DATA/vad.bin"
  printf 'export GROQ_KEY_PATH=%q\n' "$DOCTOR_HOME/no-key"
} > "$DOCTOR_PROFILE"

doctor_ok="$(
  HOME="$DOCTOR_HOME" PATH="$TMP:$PATH" DICTATION_PROFILE="$DOCTOR_PROFILE" \
    HAMMERSPOON_LAUNCH_PLIST="$PLIST" LAUNCHCTL_LOG="$TMP/doctor-ok.log" \
    LAUNCHCTL_STATE="$LAUNCHCTL_STATE" \
    bash "$ROOT/skill/whisper-dictation/scripts/whisper-doctor.sh"
)"
assert_contains "$doctor_ok" "PASS  Hammerspoon autostart plist is valid"
assert_contains "$doctor_ok" "PASS  Hammerspoon autostart is registered with launchd"

INVALID_PLIST="$TMP/invalid.plist"
printf 'not a plist\n' > "$INVALID_PLIST"
doctor_warn="$(
  HOME="$DOCTOR_HOME" PATH="$TMP:$PATH" DICTATION_PROFILE="$DOCTOR_PROFILE" \
    HAMMERSPOON_LAUNCH_PLIST="$INVALID_PLIST" LAUNCHCTL_LOG="$TMP/doctor-warn.log" \
    LAUNCHCTL_STATE="$LAUNCHCTL_STATE" LAUNCHCTL_FAIL_ON=print \
    bash "$ROOT/skill/whisper-dictation/scripts/whisper-doctor.sh"
)"
assert_contains "$doctor_warn" "WARN  Hammerspoon autostart missing or invalid"
assert_contains "$doctor_warn" "WARN  Hammerspoon autostart is not registered with launchd"

printf 'PASS install autostart + failure paths + doctor checks\n'
