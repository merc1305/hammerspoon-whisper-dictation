#!/bin/bash
# dictation-detect.sh — hardware autodetect + profile writer for whisper_own dictation.
#
# Pure probes (no side effects) describe the machine; recommend() maps facts to an
# engine order + model per the canonical policy table; write_profile() emits
# ~/.local/share/whisper/profile.env, the single carrier of hardware FACTS that
# dictation-transcribe.sh sources before its config block.
#
# Usage:
#   dictation-detect.sh                     # --report (human table), default
#   dictation-detect.sh --report
#   dictation-detect.sh --json              # machine-readable (python json.dumps)
#   dictation-detect.sh --print-order       # just the DICTATION_ENGINE_ORDER string
#   dictation-detect.sh --write-profile [PATH]
#
# Sourced as a library (functions only, no output):
#   DICTATION_DETECT_LIB=1 . dictation-detect.sh
#
# NOTE: FFMPEG_PATH/FFPROBE_PATH are intentionally NOT emitted here — install.sh
# appends them via `brew --prefix` (Intel /usr/local, Apple Silicon /opt/homebrew).

# ---- shared defaults (mirror dictation-transcribe.sh via ${VAR:-...}) ----
FFMPEG_PATH="${FFMPEG_PATH:-/usr/local/bin/ffmpeg}"
WHISPER_PATH="${WHISPER_PATH:-$HOME/.local/opt/whisper.cpp/build-metal/bin/whisper-cli}"
MODEL_DIR="${MODEL_DIR:-$HOME/.local/share/whisper}"
MODEL_PATH="${MODEL_PATH:-$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin}"
VAD_MODEL_PATH="${VAD_MODEL_PATH:-$MODEL_DIR/ggml-silero-v5.1.2.bin}"
GROQ_KEY_PATH="${GROQ_KEY_PATH:-$HOME/.hammerspoon/groq_api_key}"
PROFILE_PATH="${PROFILE_PATH:-$MODEL_DIR/profile.env}"

# Canonical universal model + its HuggingFace URL (see plan §2.2/§2.4).
# NOTE: the plan specified ggml-org/whisper.cpp, but that repo 401s for these .bin files;
# the models actually live in ggerganov/whisper.cpp (verified 200/206). Using that.
REC_MODEL_DEFAULT="ggml-large-v3-turbo-q5_0.bin"
REC_MODEL_URL_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

# ---- pure probes (no side effects) ----
hw_arch() {
  local a
  a="$(uname -m 2>/dev/null)"
  [ -n "$a" ] && printf '%s' "$a" || printf 'unknown'
}

hw_is_apple_silicon() {
  [ "$(hw_arch)" = "arm64" ]
}

hw_chip() {
  local c
  c="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  [ -n "$c" ] && printf '%s' "$c" || printf 'unknown'
}

hw_ram_gb() {
  local bytes
  bytes="$(sysctl -n hw.memsize 2>/dev/null)"
  case "$bytes" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$(( bytes / 1073741824 ))" ;;
  esac
}

hw_perf_cores() {
  local n
  n="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null)"
  case "$n" in '' | *[!0-9]*) n="" ;; esac
  if [ -z "$n" ]; then
    n="$(sysctl -n hw.physicalcpu 2>/dev/null)"
    case "$n" in '' | *[!0-9]*) n="" ;; esac
  fi
  if [ -z "$n" ]; then
    n="$(sysctl -n hw.ncpu 2>/dev/null)"
    case "$n" in '' | *[!0-9]*) n="" ;; esac
  fi
  [ -z "$n" ] && n=4
  printf '%s' "$n"
}

hw_has_ffmpeg() {
  [ -x "$FFMPEG_PATH" ] || command -v ffmpeg >/dev/null 2>&1
}

hw_has_whispercpp() {
  [ -x "$WHISPER_PATH" ] && [ -f "$MODEL_PATH" ]
}

hw_has_vad() {
  [ -f "$VAD_MODEL_PATH" ]
}

hw_has_mlx() {
  command -v mlx_whisper >/dev/null 2>&1 && return 0
  /usr/bin/python3 -c 'import mlx_whisper' >/dev/null 2>&1
}

hw_has_groq_key() {
  [ -n "${GROQ_API_KEY:-}" ] && return 0
  [ -s "$GROQ_KEY_PATH" ]
}

# ---- recommendation (facts -> engine order / model / tuning) ----
# Sets: DICT_TIER DICT_HAS_MLX DICT_HAS_METAL_WHISPER DICT_CHIP DICT_ARCH DICT_RAM_GB
#       REC_ORDER REC_MODEL REC_MODEL_URL REC_MODEL_PATH REC_THREADS REC_COMPUTE
#       REC_LLM REC_BUILD_LOCAL
recommend() {
  DICT_ARCH="$(hw_arch)"
  DICT_CHIP="$(hw_chip)"
  DICT_RAM_GB="$(hw_ram_gb)"
  local cores
  cores="$(hw_perf_cores)"

  local is_as=0
  hw_is_apple_silicon && is_as=1
  local has_mlx=0
  hw_has_mlx && has_mlx=1
  local has_wcpp=0
  hw_has_whispercpp && has_wcpp=1
  local has_key=0
  hw_has_groq_key && has_key=1

  DICT_HAS_MLX="$has_mlx"
  # "Metal whisper" = a local whisper.cpp build that can use the GPU — only meaningful
  # on Apple Silicon. On Intel a local build is CPU-only, so it does not count.
  if [ "$is_as" = "1" ] && [ "$has_wcpp" = "1" ]; then
    DICT_HAS_METAL_WHISPER=1
  else
    DICT_HAS_METAL_WHISPER=0
  fi

  # Tier (see plan §2.4). strong_local = Apple Silicon + RAM>=16 + (mlx OR whisper.cpp).
  if [ "$is_as" = "1" ] && [ "$DICT_RAM_GB" -ge 16 ] && { [ "$has_mlx" = "1" ] || [ "$has_wcpp" = "1" ]; }; then
    DICT_TIER="apple-strong"
  elif [ "$is_as" = "1" ] && [ "$has_wcpp" = "1" ]; then
    DICT_TIER="apple-capable"
  else
    DICT_TIER="weak"
  fi

  # Engine order: a tier-priority sequence filtered down to engines that are actually
  # usable. groq is always kept as a candidate (the cloud path can be enabled later by
  # adding a key; the runtime dispatcher skips it with rc=2 when no key is present).
  local seq
  case "$DICT_TIER" in
    apple-strong)
      if [ "$has_mlx" = "1" ]; then seq="mlx whisper.cpp groq"; else seq="whisper.cpp groq"; fi
      ;;
    apple-capable) seq="whisper.cpp groq" ;;
    *) seq="groq whisper.cpp" ;; # weak: Groq-first, local as offline fallback
  esac
  REC_ORDER=""
  local e
  for e in $seq; do
    case "$e" in
      mlx) [ "$has_mlx" = "1" ] || continue ;;
      whisper.cpp) [ "$has_wcpp" = "1" ] || continue ;;
      groq) : ;; # always a candidate
    esac
    REC_ORDER="${REC_ORDER:+$REC_ORDER }$e"
  done
  # Never emit an empty order — fall back to the canonical safe default.
  [ -n "$REC_ORDER" ] || REC_ORDER="groq whisper.cpp"

  # Local model preference. Universal = turbo-q5; large-v3 only on strong + RAM>=24.
  if [ "$DICT_TIER" = "apple-strong" ] && [ "$DICT_RAM_GB" -ge 24 ]; then
    REC_MODEL="ggml-large-v3-q5_0.bin"
  else
    REC_MODEL="$REC_MODEL_DEFAULT"
  fi

  # Threads: perf cores on Apple Silicon, else min(physical, 8).
  if [ "$is_as" = "1" ]; then
    REC_THREADS="$cores"
  elif [ "$cores" -gt 8 ]; then
    REC_THREADS=8
  else
    REC_THREADS="$cores"
  fi

  # Compute + LLM cleanup default + whether to build whisper.cpp locally.
  if [ "$DICT_HAS_METAL_WHISPER" = "1" ]; then
    REC_COMPUTE="metal"
  else
    REC_COMPUTE="cpu"
  fi
  if [ "$has_key" = "1" ]; then
    REC_LLM=1
  else
    REC_LLM=0
  fi
  if [ "$DICT_TIER" = "weak" ]; then
    REC_BUILD_LOCAL=0
  else
    REC_BUILD_LOCAL=1
  fi

  REC_MODEL_URL="$REC_MODEL_URL_BASE/$REC_MODEL"
  REC_MODEL_PATH="$MODEL_DIR/$REC_MODEL"
}

# ---- profile writer ----
write_profile() {
  local out="${1:-$PROFILE_PATH}"
  recommend
  local dir
  dir="$(dirname "$out")"
  mkdir -p "$dir" 2>/dev/null
  {
    printf '# Auto-generated by dictation-detect.sh on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# Precedence: runtime env > this profile > policy > dictation-transcribe.sh defaults\n'
    printf '# Facts: chip=%s | arch=%s | ram=%sGB | tier=%s\n\n' \
      "$DICT_CHIP" "$DICT_ARCH" "$DICT_RAM_GB" "$DICT_TIER"

    printf '# --- facts (read by model-policy.resolve_model_policy) ---\n'
    printf 'export DICT_TIER="${DICT_TIER:-%s}"\n' "$DICT_TIER"
    printf 'export DICT_HAS_MLX="${DICT_HAS_MLX:-%s}"\n' "$DICT_HAS_MLX"
    printf 'export DICT_HAS_METAL_WHISPER="${DICT_HAS_METAL_WHISPER:-%s}"\n\n' "$DICT_HAS_METAL_WHISPER"

    printf '# --- human/installer facts ---\n'
    printf 'export DICT_CHIP="${DICT_CHIP:-%s}"\n' "$DICT_CHIP"
    printf 'export DICT_ARCH="${DICT_ARCH:-%s}"\n' "$DICT_ARCH"
    printf 'export DICT_RAM_GB="${DICT_RAM_GB:-%s}"\n' "$DICT_RAM_GB"
    printf 'export REC_MODEL_URL="${REC_MODEL_URL:-%s}"\n' "$REC_MODEL_URL"
    printf 'export REC_MODEL_PATH="${REC_MODEL_PATH:-%s}"\n' "$REC_MODEL_PATH"
    printf 'export REC_BUILD_LOCAL="${REC_BUILD_LOCAL:-%s}"\n\n' "$REC_BUILD_LOCAL"

    printf '# --- pre-resolved recommendations (policy re-derives from facts if unset) ---\n'
    printf 'export DICTATION_ENGINE_ORDER="${DICTATION_ENGINE_ORDER:-%s}"\n' "$REC_ORDER"
    printf 'export WHISPER_THREADS="${WHISPER_THREADS:-%s}"\n' "$REC_THREADS"
    printf 'export DICTATION_COMPUTE="${DICTATION_COMPUTE:-%s}"\n' "$REC_COMPUTE"
    printf 'export DICTATION_LLM_CLEANUP="${DICTATION_LLM_CLEANUP:-%s}"\n' "$REC_LLM"

    if [ -f "$REC_MODEL_PATH" ]; then
      printf '\n# MODEL_PATH — recommended model file exists on disk\n'
      printf 'export MODEL_PATH="${MODEL_PATH:-%s}"\n' "$REC_MODEL_PATH"
    else
      printf '\n# MODEL_PATH not written: recommended model file not present yet\n'
    fi

    printf '\n# FFMPEG_PATH/FFPROBE_PATH are appended by install.sh via brew --prefix.\n'
  } > "$out"
}

# ---- reporters ----
yesno() {
  if "$@"; then printf 'yes'; else printf 'no'; fi
}

do_report() {
  recommend
  printf 'whisper_own hardware detection\n'
  printf '==============================\n'
  printf 'Chip:          %s\n' "$DICT_CHIP"
  printf 'Architecture:  %s\n' "$DICT_ARCH"
  printf 'RAM:           %s GB\n' "$DICT_RAM_GB"
  printf 'Tier:          %s\n' "$DICT_TIER"
  printf '\nDependencies:\n'
  printf '  ffmpeg:        %s\n' "$(yesno hw_has_ffmpeg)"
  printf '  whisper.cpp:   %s\n' "$(yesno hw_has_whispercpp)"
  printf '  Silero VAD:    %s\n' "$(yesno hw_has_vad)"
  printf '  mlx_whisper:   %s\n' "$(yesno hw_has_mlx)"
  printf '  Groq API key:  %s\n' "$(yesno hw_has_groq_key)"
  printf '\nRecommended:\n'
  printf '  engine order:  %s\n' "$REC_ORDER"
  printf '  local model:   %s\n' "$REC_MODEL"
  printf '  threads:       %s\n' "$REC_THREADS"
  printf '  compute:       %s\n' "$REC_COMPUTE"
  printf '  LLM cleanup:   %s\n' "$REC_LLM"
  printf '  build local:   %s\n' "$REC_BUILD_LOCAL"
}

do_json() {
  recommend
  local has_ffmpeg=false has_wcpp=false has_vad=false has_mlx=false has_key=false
  hw_has_ffmpeg && has_ffmpeg=true
  hw_has_whispercpp && has_wcpp=true
  hw_has_vad && has_vad=true
  hw_has_mlx && has_mlx=true
  hw_has_groq_key && has_key=true
  D_ARCH="$DICT_ARCH" D_CHIP="$DICT_CHIP" D_RAM="$DICT_RAM_GB" D_TIER="$DICT_TIER" \
    D_MLX="$DICT_HAS_MLX" D_METAL="$DICT_HAS_METAL_WHISPER" \
    D_HAS_FFMPEG="$has_ffmpeg" D_HAS_WCPP="$has_wcpp" D_HAS_VAD="$has_vad" D_HAS_KEY="$has_key" \
    D_ORDER="$REC_ORDER" D_MODEL="$REC_MODEL" D_URL="$REC_MODEL_URL" D_MPATH="$REC_MODEL_PATH" \
    D_THREADS="$REC_THREADS" D_COMPUTE="$REC_COMPUTE" D_LLM="$REC_LLM" D_BUILD="$REC_BUILD_LOCAL" \
    /usr/bin/python3 -c '
import os, json
def b(x): return x == "true"
d = {
  "arch": os.environ.get("D_ARCH", ""),
  "chip": os.environ.get("D_CHIP", ""),
  "ram_gb": int(os.environ.get("D_RAM", "0") or 0),
  "tier": os.environ.get("D_TIER", ""),
  "has_mlx": os.environ.get("D_MLX", "0") == "1",
  "has_metal_whisper": os.environ.get("D_METAL", "0") == "1",
  "has_ffmpeg": b(os.environ.get("D_HAS_FFMPEG", "false")),
  "has_whispercpp": b(os.environ.get("D_HAS_WCPP", "false")),
  "has_vad": b(os.environ.get("D_HAS_VAD", "false")),
  "has_groq_key": b(os.environ.get("D_HAS_KEY", "false")),
  "recommended": {
    "order": os.environ.get("D_ORDER", ""),
    "model": os.environ.get("D_MODEL", ""),
    "model_url": os.environ.get("D_URL", ""),
    "model_path": os.environ.get("D_MPATH", ""),
    "threads": int(os.environ.get("D_THREADS", "0") or 0),
    "compute": os.environ.get("D_COMPUTE", ""),
    "llm_cleanup": os.environ.get("D_LLM", "0") == "1",
    "build_local": os.environ.get("D_BUILD", "0") == "1",
  },
}
print(json.dumps(d, ensure_ascii=False, indent=2))
'
}

# ---- CLI (skipped entirely when sourced as a library) ----
if [ "${DICTATION_DETECT_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null
  exit 0
fi

case "${1:---report}" in
  --report) do_report ;;
  --json) do_json ;;
  --print-order) recommend; printf '%s\n' "$REC_ORDER" ;;
  --write-profile) write_profile "${2:-}"; printf 'Wrote profile: %s\n' "${2:-$PROFILE_PATH}" >&2 ;;
  *) do_report ;;
esac
