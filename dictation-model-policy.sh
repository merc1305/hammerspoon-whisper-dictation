#!/bin/bash
# dictation-model-policy.sh — sourced library that maps detected hardware facts
# (DICT_TIER / DICT_HAS_MLX / DICT_HAS_METAL_WHISPER) to a concrete engine order and
# local model, WITHOUT any user-facing model menu. Safe to source under `set -u`.
#
# resolve_model_policy() fills DICTATION_ENGINE_ORDER / MODEL_PATH / GROQ_MODEL ONLY
# when they are empty, so precedence stays: runtime env > profile.env > policy >
# dictation-transcribe.sh built-in defaults (see plan §2.4).
#
#   | tier                          | order                | local model (pref)        |
#   |-------------------------------|----------------------|---------------------------|
#   | apple-strong + mlx            | mlx whisper.cpp groq | turbo → turbo-q5 → large   |
#   | apple-strong / apple-capable  | whisper.cpp groq     | turbo-q5 → turbo → large   |
#   | weak / empty                  | groq whisper.cpp     | turbo-q5 (fallback)       |

MODEL_DIR="${MODEL_DIR:-$HOME/.local/share/whisper}"

# Local model preference lists (best first). turbo-q5 is the universal default; a strong
# machine may prefer the un-quantized turbo.
DICT_LOCAL_MODEL_PREFERENCE_DEFAULT="${DICT_LOCAL_MODEL_PREFERENCE_DEFAULT:-ggml-large-v3-turbo-q5_0.bin ggml-large-v3-turbo.bin ggml-large-v3-q5_0.bin ggml-large-v3.bin}"
DICT_LOCAL_MODEL_PREFERENCE_STRONG="${DICT_LOCAL_MODEL_PREFERENCE_STRONG:-ggml-large-v3-turbo.bin ggml-large-v3-turbo-q5_0.bin ggml-large-v3.bin}"

# Echo the first model file from $1 (a space-separated name list) that exists in MODEL_DIR.
_first_present_model() {
  local name
  for name in $1; do
    if [ -f "$MODEL_DIR/$name" ]; then
      printf '%s' "$MODEL_DIR/$name"
      return 0
    fi
  done
  return 1
}

resolve_model_policy() {
  local tier="${DICT_TIER:-weak}"
  local has_mlx="${DICT_HAS_MLX:-0}"

  # Engine order — only if not already set by runtime env or profile.env.
  if [ -z "${DICTATION_ENGINE_ORDER:-}" ]; then
    case "$tier" in
      apple-strong)
        if [ "$has_mlx" = "1" ]; then
          DICTATION_ENGINE_ORDER="mlx whisper.cpp groq"
        else
          DICTATION_ENGINE_ORDER="whisper.cpp groq"
        fi
        ;;
      apple-capable)
        DICTATION_ENGINE_ORDER="whisper.cpp groq"
        ;;
      *)
        DICTATION_ENGINE_ORDER="groq whisper.cpp"
        ;;
    esac
  fi

  # Local model — best present file from the tier-appropriate list, else the default.
  if [ -z "${MODEL_PATH:-}" ]; then
    local pref="$DICT_LOCAL_MODEL_PREFERENCE_DEFAULT"
    if [ "$tier" = "apple-strong" ]; then
      pref="$DICT_LOCAL_MODEL_PREFERENCE_STRONG"
    fi
    local found
    if found="$(_first_present_model "$pref")"; then
      MODEL_PATH="$found"
    else
      MODEL_PATH="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
    fi
  fi

  # Cloud model.
  GROQ_MODEL="${GROQ_MODEL:-whisper-large-v3}"

  export DICTATION_ENGINE_ORDER MODEL_PATH GROQ_MODEL
}
