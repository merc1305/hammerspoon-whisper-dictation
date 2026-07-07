#!/bin/bash
set -u

# dictation-transcribe.sh — transcription worker for the Hammerspoon dictation pipeline.
#
# Modes:
#   dictation-transcribe.sh /path/to/audio.wav            — transcribe an existing file
#   dictation-transcribe.sh --cut BUFFER START END        — cut bytes [START, END) out of
#     a raw ring buffer (s16le 16kHz mono), wrap into WAV and transcribe
#
# Engine order: Groq API (whisper-large-v3) if a key is configured, otherwise —
# or on any Groq failure — a fully local whisper.cpp (whisper-cli).
#
# Communicates with Hammerspoon via files:
#   /tmp/dictation.txt     — final transcribed text
#   /tmp/dictation.status  — running | done | ignored | error:<reason>
#   /tmp/dictation.err     — diagnostics for the current run

MODE="file"
AUDIO_PATH="/tmp/dictation.wav"
SLICE_PATH="/tmp/dictation-slice.raw"

if [ "${1:-}" = "--cut" ]; then
  MODE="cut"
  BUFFER_PATH="${2:?buffer path required}"
  START_BYTES="${3:?start bytes required}"
  END_BYTES="${4:?end bytes required}"
elif [ -n "${1:-}" ]; then
  AUDIO_PATH="$1"
fi

# ---- configuration (override any of these via environment variables) ----
FFMPEG_PATH="${FFMPEG_PATH:-/usr/local/bin/ffmpeg}"
FFPROBE_PATH="${FFPROBE_PATH:-/usr/local/bin/ffprobe}"
WHISPER_PATH="${WHISPER_PATH:-$HOME/.local/opt/whisper.cpp/build-metal/bin/whisper-cli}"
MODEL_PATH="${MODEL_PATH:-$HOME/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin}"
# Silero VAD model — download from https://huggingface.co/ggml-org/whisper-vad
VAD_MODEL_PATH="${VAD_MODEL_PATH:-$HOME/.local/share/whisper/ggml-silero-v5.1.2.bin}"
LAST_LOG_PATH="${LAST_LOG_PATH:-$HOME/.local/share/whisper/last.log}"
LAST_WAV_PATH="${LAST_WAV_PATH:-/tmp/dictation-last.wav}"
GROQ_KEY_PATH="${GROQ_KEY_PATH:-$HOME/.hammerspoon/groq_api_key}"
GROQ_MODEL="${GROQ_MODEL:-whisper-large-v3}"
GROQ_ENDPOINT="https://api.groq.com/openai/v1/audio/transcriptions"
MIN_AUDIO_SECONDS="${MIN_AUDIO_SECONDS:-0.75}"

# Initial prompt: steers language mix and punctuation. Tune for your languages.
PROMPT="${DICTATION_PROMPT:-Russian-English dictation. Keep Russian as Russian and English words as English. Add punctuation. Use question marks for questions. Examples: Проверка диктовки. Today is Tuesday. Всё работает локально. Почему не ставится вопросительный знак?}"

# Known Whisper hallucination phrases (YouTube-subtitle boilerplate that Whisper emits
# on silence/pauses). One regex per line; matched case-insensitively; the match and
# everything after it on the same line is removed. Add your own for your language.
HALLUCINATION_PHRASES="${HALLUCINATION_PHRASES:-продолжение\s+следует
спасибо\s+за\s+просмотр
субтитры\s+сделал
редактор\s+субтитров
подписывайтесь\s+на\s+канал
thanks?\s+for\s+watching
subtitles\s+by}"
# -------------------------------------------------------------------------

OUT_PATH="/tmp/dictation.txt"
ERR_PATH="/tmp/dictation.err"
STATUS_PATH="/tmp/dictation.status"
PID_PATH="/tmp/dictation-whisper.pid"

printf '%s\n' "$$" > "$PID_PATH"
printf '%s\n' "running" > "$STATUS_PATH"
: > "$OUT_PATH"
: > "$ERR_PATH"

finish_ignored() {
  printf 'ignored: %s\n' "$1" >> "$ERR_PATH"
  printf '%s\n' "ignored" > "$STATUS_PATH"
  rm -f "$PID_PATH"
  exit 0
}

finish_error() {
  printf '%s\n' "error:$1" > "$STATUS_PATH"
  rm -f "$PID_PATH"
  exit 1
}

if [ "$MODE" = "cut" ]; then
  if [ ! -f "$BUFFER_PATH" ]; then
    finish_error "buffer-missing"
  fi

  SLICE_LENGTH=$((END_BYTES - START_BYTES))
  if [ "$SLICE_LENGTH" -le 0 ]; then
    finish_ignored "empty slice"
  fi

  tail -c +"$((START_BYTES + 1))" "$BUFFER_PATH" | head -c "$SLICE_LENGTH" > "$SLICE_PATH"

  if [ ! -s "$SLICE_PATH" ]; then
    finish_ignored "slice is empty"
  fi

  if ! "$FFMPEG_PATH" -y -hide_banner -loglevel error \
      -f s16le -ar 16000 -ac 1 \
      -i "$SLICE_PATH" "$AUDIO_PATH" 2>> "$ERR_PATH"; then
    finish_error "cut"
  fi

  rm -f "$SLICE_PATH"
fi

read_groq_key() {
  if [ -n "${GROQ_API_KEY:-}" ]; then
    printf '%s' "$GROQ_API_KEY"
    return
  fi

  if [ -f "$GROQ_KEY_PATH" ]; then
    tr -d '[:space:]' < "$GROQ_KEY_PATH"
    return
  fi
}

audio_duration_seconds() {
  "$FFPROBE_PATH" \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$AUDIO_PATH" 2>/dev/null
}

audio_is_too_short() {
  duration="$(audio_duration_seconds)"
  /usr/bin/python3 - "$duration" "$MIN_AUDIO_SECONDS" <<'PY'
import sys

try:
    duration = float(sys.argv[1])
    minimum = float(sys.argv[2])
except Exception:
    sys.exit(0)

sys.exit(0 if duration < minimum else 1)
PY
}

if audio_is_too_short; then
  finish_ignored "audio shorter than ${MIN_AUDIO_SECONDS}s"
fi

write_json_text_to_out() {
  /usr/bin/python3 - "$1" "$OUT_PATH" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    payload = json.load(f)
text = (payload.get("text") or "").strip()
with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
    if text:
        f.write("\n")
PY
}

transcribe_groq() {
  key="$(read_groq_key)"
  if [ -z "$key" ]; then
    return 2
  fi

  json_path="/tmp/dictation.groq.json"
  http_path="/tmp/dictation.groq.http"
  : > "$json_path"

  http_code="$(/usr/bin/curl \
    --silent \
    --show-error \
    --max-time 60 \
    --output "$json_path" \
    --write-out '%{http_code}' \
    --request POST "$GROQ_ENDPOINT" \
    --header "Authorization: Bearer $key" \
    --form "file=@${AUDIO_PATH};type=audio/wav" \
    --form "model=${GROQ_MODEL}" \
    --form "prompt=${PROMPT}" \
    --form "response_format=json" \
    --form "temperature=0" \
    2> "$ERR_PATH")"

  printf '%s\n' "$http_code" > "$http_path"

  if [ "$http_code" != "200" ]; then
    {
      printf 'Groq HTTP %s\n' "$http_code"
      cat "$json_path" 2>/dev/null
    } >> "$ERR_PATH"
    return 1
  fi

  if ! write_json_text_to_out "$json_path" 2>> "$ERR_PATH"; then
    return 1
  fi

  if [ ! -s "$OUT_PATH" ]; then
    printf 'Groq returned empty transcription\n' >> "$ERR_PATH"
    return 1
  fi

  return 0
}

transcribe_local() {
  # -mc 0        : do not carry decoded text as context into the next 30s window.
  #                (this whisper-cli build has no --no-context flag; -mc 0 is the
  #                equivalent — it is the main fix against cross-window hallucination
  #                contamination)
  # --vad ...    : cut silence/pauses before decoding (Silero VAD) — Whisper never
  #                sees the silence it likes to hallucinate on
  # -sns         : suppress non-speech tokens
  local vad_args=()
  if [ -f "$VAD_MODEL_PATH" ]; then
    vad_args=(--vad --vad-model "$VAD_MODEL_PATH")
  else
    printf 'VAD model missing at %s, running without VAD\n' "$VAD_MODEL_PATH" >> "$ERR_PATH"
  fi

  "$WHISPER_PATH" \
    -m "$MODEL_PATH" \
    -f "$AUDIO_PATH" \
    -l auto \
    -nt \
    -np \
    -t 8 \
    -ng \
    -bs 1 \
    -bo 1 \
    -nf \
    -mc 0 \
    -sns \
    "${vad_args[@]}" \
    --prompt "$PROMPT" \
    > "$OUT_PATH" \
    2> "$ERR_PATH"
}

# Post-filter: strip known Whisper hallucination lines (YouTube boilerplate emitted on
# pauses/silence). Applied to the output of BOTH engines (Groq and local) — the cloud
# model hallucinates the same phrases.
clean_hallucinations() {
  HALLUCINATION_PHRASES="$HALLUCINATION_PHRASES" /usr/bin/python3 - "$OUT_PATH" <<'PY'
import os
import re
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
except FileNotFoundError:
    sys.exit(0)

# Phrase stems. Real occurrences drag a tail behind them ("Субтитры сделал
# DimaTorzok", "Продолжение следует...") — so we cut from the phrase start
# to the end of the line.
phrases = [p.strip() for p in os.environ.get("HALLUCINATION_PHRASES", "").splitlines() if p.strip()]
if not phrases:
    sys.exit(0)
pattern = re.compile("|".join(phrases), re.IGNORECASE | re.UNICODE)

cleaned_lines = []
for line in text.splitlines():
    m = pattern.search(line)
    if m:
        # cut from the phrase to end of line, keeping any real text before it
        line = line[: m.start()]
        # drop dangling connective punctuation left by the cut
        line = re.sub(r"[\s,;:\-–—…]+$", "", line)
    stripped = line.strip()
    # drop lines that became empty or are punctuation-only
    if stripped and re.search(r"\w", stripped, re.UNICODE):
        cleaned_lines.append(line.rstrip())

result = "\n".join(cleaned_lines).strip()
with open(path, "w", encoding="utf-8") as f:
    f.write(result)
    if result:
        f.write("\n")
PY
}

log_diagnostics() {
  # $1 = engine (groq|local), $2 = raw engine output (before the post-filter)
  local engine="$1"
  local raw="$2"
  local duration
  duration="$(audio_duration_seconds)"
  local cleaned
  cleaned="$(cat "$OUT_PATH" 2>/dev/null)"
  {
    printf '==== %s | mode=%s | engine=%s | duration=%ss ====\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$engine" "${duration:-?}"
    printf -- '--- raw (%s) ---\n%s\n' "$engine" "$raw"
    if [ "$raw" != "$cleaned" ]; then
      printf -- '--- cleaned (after post-filter) ---\n%s\n' "$cleaned"
    fi
    printf '\n'
  } >> "$LAST_LOG_PATH" 2>/dev/null
}

transcribe_groq
groq_code=$?

if [ "$groq_code" -eq 0 ]; then
  exit_code=0
  ENGINE="groq"
else
  {
    printf '\n--- falling back to local whisper, groq_code=%s ---\n' "$groq_code"
  } >> "$ERR_PATH"
  transcribe_local
  exit_code=$?
  ENGINE="local"
fi

# Raw engine output BEFORE the post-filter — so the log shows whether the engine
# itself hallucinated.
RAW_OUTPUT="$(cat "$OUT_PATH" 2>/dev/null)"

if [ "$exit_code" -eq 0 ]; then
  clean_hallucinations
  log_diagnostics "$ENGINE" "$RAW_OUTPUT"
  printf '%s\n' "done" > "$STATUS_PATH"
else
  log_diagnostics "$ENGINE" "$RAW_OUTPUT"
  printf 'error:%s\n' "$exit_code" > "$STATUS_PATH"
fi

# Diagnostics: keep the transcribed wav as -last.wav (live dictation only) instead of
# deleting it. On the next failure you can tell whether the recording itself was
# truncated or the transcription lost the tail.
if [ "$MODE" = "cut" ] && [ -f "$AUDIO_PATH" ]; then
  mv -f "$AUDIO_PATH" "$LAST_WAV_PATH" 2>/dev/null
fi

rm -f "$PID_PATH"
