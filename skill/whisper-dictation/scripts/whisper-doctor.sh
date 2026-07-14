#!/bin/bash
# whisper-doctor.sh — READ-ONLY health check for the whisper_own dictation tool.
# Makes no changes: it only reads files, sources the profile, and does one 2 s GET to
# Groq (auth check) when a key is present. Exit 0 if the critical parts are OK, else 1.
set -u

PASS=0
WARN=0
FAIL=0
pass() {
  printf '  PASS  %s\n' "$*"
  PASS=$((PASS + 1))
}
warn() {
  printf '  WARN  %s\n' "$*"
  WARN=$((WARN + 1))
}
fail() {
  printf '  FAIL  %s\n' "$*"
  FAIL=$((FAIL + 1))
}
info() { printf '  INFO  %s\n' "$*"; }

# Resolve config exactly like the worker does (read-only).
PROFILE_PATH="${DICTATION_PROFILE:-$HOME/.local/share/whisper/profile.env}"
# shellcheck disable=SC1090
[ -f "$PROFILE_PATH" ] && . "$PROFILE_PATH"
FFMPEG_PATH="${FFMPEG_PATH:-/usr/local/bin/ffmpeg}"
FFPROBE_PATH="${FFPROBE_PATH:-/usr/local/bin/ffprobe}"
WHISPER_PATH="${WHISPER_PATH:-$HOME/.local/opt/whisper.cpp/build-metal/bin/whisper-cli}"
MODEL_PATH="${MODEL_PATH:-$HOME/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin}"
VAD_MODEL_PATH="${VAD_MODEL_PATH:-$HOME/.local/share/whisper/ggml-silero-v5.1.2.bin}"
GROQ_KEY_PATH="${GROQ_KEY_PATH:-$HOME/.hammerspoon/groq_api_key}"
LAST_LOG="${LAST_LOG_PATH:-$HOME/.local/share/whisper/last.log}"

printf 'whisper-dictation doctor (read-only)\n'
printf '====================================\n'

# Hammerspoon
if [ -d "/Applications/Hammerspoon.app" ] || [ -d "$HOME/Applications/Hammerspoon.app" ]; then
  pass "Hammerspoon installed"
elif pgrep -x Hammerspoon >/dev/null 2>&1; then
  pass "Hammerspoon running"
else
  warn "Hammerspoon.app not found (checked /Applications and ~/Applications)"
fi

# ffmpeg / ffprobe
ffbin="$FFMPEG_PATH"
[ -x "$ffbin" ] || ffbin="$(command -v ffmpeg 2>/dev/null || true)"
if [ -n "$ffbin" ] && [ -x "$ffbin" ]; then
  case "$ffbin" in
    /opt/homebrew/*) pass "ffmpeg: $ffbin (Apple Silicon prefix)" ;;
    /usr/local/*) pass "ffmpeg: $ffbin (Intel prefix)" ;;
    *) pass "ffmpeg: $ffbin" ;;
  esac
else
  fail "ffmpeg not found (checked $FFMPEG_PATH and PATH)"
fi
if [ -x "$FFPROBE_PATH" ] || command -v ffprobe >/dev/null 2>&1; then
  pass "ffprobe present"
else
  warn "ffprobe not found"
fi

# local engine
WHISPER_OK=0
MODEL_OK=0
if [ -x "$WHISPER_PATH" ]; then
  pass "whisper-cli: $WHISPER_PATH"
  WHISPER_OK=1
else
  warn "whisper-cli not found at $WHISPER_PATH"
fi
if [ -f "$MODEL_PATH" ]; then
  pass "model: $(basename "$MODEL_PATH")"
  MODEL_OK=1
else
  warn "model missing at $MODEL_PATH"
fi
if [ -f "$VAD_MODEL_PATH" ]; then
  pass "VAD model present"
else
  warn "VAD model missing (runs without VAD)"
fi

# Groq
GROQ_OK=0
if [ -n "${GROQ_API_KEY:-}" ] || [ -s "$GROQ_KEY_PATH" ]; then
  key="${GROQ_API_KEY:-$(tr -d '[:space:]' < "$GROQ_KEY_PATH" 2>/dev/null)}"
  code="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $key" https://api.groq.com/openai/v1/models 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    pass "Groq key valid (HTTP 200)"
    GROQ_OK=1
  elif [ "$code" = "000" ]; then
    warn "Groq key present but endpoint unreachable (timeout/offline)"
    GROQ_OK=1
  else
    warn "Groq key present but auth returned HTTP $code"
  fi
else
  warn "no Groq key configured (100% local)"
fi

# at least one working engine (critical)
if [ "$GROQ_OK" = "1" ] || { [ "$WHISPER_OK" = "1" ] && [ "$MODEL_OK" = "1" ]; }; then
  pass "at least one transcription engine is available"
else
  fail "no usable engine (no Groq key and no local whisper.cpp + model)"
fi

# recorder buffer freshness (via mtime — read-only)
BUF="/tmp/dictation-buffer.raw"
if [ -f "$BUF" ]; then
  mtime="$(stat -f %m "$BUF" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$((now - mtime))
  if [ "$age" -lt 15 ]; then
    pass "recorder buffer is fresh (written ${age}s ago)"
  else
    warn "recorder buffer stale (last write ${age}s ago) — is Hammerspoon running?"
  fi
else
  warn "no recorder buffer at $BUF — Hammerspoon may not be loaded"
fi

# last run breadcrumbs
[ -f /tmp/dictation.status ] && info "last status: $(cat /tmp/dictation.status)"
[ -f /tmp/dictation.engine ] && info "last engine: $(cat /tmp/dictation.engine)"
if [ -f "$LAST_LOG" ]; then
  info "last.log tail:"
  tail -n 4 "$LAST_LOG" 2>/dev/null | sed 's/^/        /'
fi

printf '\n%s PASS, %s WARN, %s FAIL\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
