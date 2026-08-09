#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/whisper-worker-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

touch "$TMP/audio.wav" "$TMP/model.bin"

cat > "$TMP/ffprobe" <<'EOF'
#!/bin/bash
printf '2.0\n'
EOF
chmod +x "$TMP/ffprobe"

cat > "$TMP/whisper-cli" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "${WHISPER_ARGS_LOG:?}"
printf 'Test transcript.\n'
EOF
chmod +x "$TMP/whisper-cli"

run_worker() {
  local compute="$1" args_log="$TMP/args-$1.log"
  WHISPER_ARGS_LOG="$args_log" \
  DICTATION_PROFILE="$TMP/missing-profile" \
  DICTATION_MODEL_POLICY="$TMP/missing-policy" \
  DICTATION_ENGINE_ORDER="whisper.cpp" \
  DICTATION_LLM_CLEANUP=0 \
  DICTATION_HISTORY_MAX=0 \
  WHISPER_THREADS=10 \
  DICTATION_COMPUTE="$compute" \
  WHISPER_PATH="$TMP/whisper-cli" \
  MODEL_PATH="$TMP/model.bin" \
  VAD_MODEL_PATH="$TMP/missing-vad.bin" \
  FFPROBE_PATH="$TMP/ffprobe" \
  OUT_PATH="$TMP/out-$compute.txt" \
  ERR_PATH="$TMP/err-$compute.txt" \
  STATUS_PATH="$TMP/status-$compute.txt" \
  PID_PATH="$TMP/pid-$compute" \
  ENGINE_PATH="$TMP/engine-$compute" \
  LAST_LOG_PATH="$TMP/last-$compute.log" \
    bash "$ROOT/dictation-transcribe.sh" "$TMP/audio.wav"
  printf '%s' "$args_log"
}

cpu_args="$(run_worker cpu)"
grep -Eq '(^| )-t 10( |$)' "$cpu_args"
grep -Eq '(^| )-ng( |$)' "$cpu_args"

metal_args="$(run_worker metal)"
grep -Eq '(^| )-t 10( |$)' "$metal_args"
if grep -Eq '(^| )-ng( |$)' "$metal_args"; then
  printf 'Metal profile unexpectedly disabled GPU offload\n' >&2
  exit 1
fi

# Policy regression: weak machines prefer the fast multilingual CPU model, while an
# Apple-capable profile keeps turbo-q5.
mkdir -p "$TMP/models"
touch "$TMP/models/ggml-small-q5_1.bin" "$TMP/models/ggml-large-v3-turbo-q5_0.bin"

weak_model="$({
  MODEL_DIR="$TMP/models"
  DICT_TIER=weak
  DICT_HAS_MLX=0
  DICTATION_ENGINE_ORDER=
  MODEL_PATH=
  source "$ROOT/dictation-model-policy.sh"
  resolve_model_policy
  basename "$MODEL_PATH"
})"
[ "$weak_model" = "ggml-small-q5_1.bin" ]

apple_model="$({
  MODEL_DIR="$TMP/models"
  DICT_TIER=apple-capable
  DICT_HAS_MLX=0
  DICTATION_ENGINE_ORDER=
  MODEL_PATH=
  source "$ROOT/dictation-model-policy.sh"
  resolve_model_policy
  basename "$MODEL_PATH"
})"
[ "$apple_model" = "ggml-large-v3-turbo-q5_0.bin" ]

detected_model="$({
  DICTATION_DETECT_LIB=1
  source "$ROOT/dictation-detect.sh"
  hw_arch() { printf 'x86_64'; }
  hw_chip() { printf 'Test Intel'; }
  hw_ram_gb() { printf '32'; }
  hw_perf_cores() { printf '8'; }
  hw_is_apple_silicon() { return 1; }
  hw_has_mlx() { return 1; }
  hw_has_whispercpp() { return 0; }
  hw_has_groq_key() { return 0; }
  recommend
  printf '%s' "$REC_MODEL"
})"
[ "$detected_model" = "ggml-small-q5_1.bin" ]

printf 'PASS worker thread/compute tuning + weak model policy\n'
