# Engine & model policy

**The model is chosen automatically — there is no model menu.** `dictation-detect.sh`
inspects the machine at install time and writes `~/.local/share/whisper/profile.env`; at
runtime `dictation-model-policy.sh` fills any gaps. You change engine *order* and language,
not model files.

## Tokens

Engine tokens are **`mlx | whisper.cpp | groq`** (aliases: `mlx-whisper`, `local`, `cloud`).
The winning token is written verbatim to `/tmp/dictation.engine` and into the history — the
local engine is `whisper.cpp`, never the old `local`.

## Policy table

| Tier | Condition | `DICTATION_ENGINE_ORDER` | Model |
|---|---|---|---|
| **weak** (e.g. Intel) | no Metal build / low RAM | `groq whisper.cpp` | cloud `whisper-large-v3`; local `ggml-large-v3-turbo-q5_0` fallback |
| **apple-strong / apple-capable** | arm64 + whisper.cpp built | `whisper.cpp groq` | local `turbo-q5` → `turbo` → `large-v3` |
| **apple-strong + mlx** | arm64, RAM ≥ 16, `mlx_whisper` | `mlx whisper.cpp groq` | mlx `whisper-large-v3-turbo`, then local, then cloud |

`turbo-q5` is the universal default: ~8× faster to decode than large-v3 with near-identical
Russian quality.

## Switching engines

- **Force cloud:** `DICTATION_ENGINE_ORDER="groq whisper.cpp"` and a valid key at
  `~/.hammerspoon/groq_api_key`.
- **Force fully local / offline:** `DICTATION_ENGINE_ORDER="whisper.cpp"` (or remove the
  key). Zero network calls.
- **Apple Silicon with mlx:** `DICTATION_ENGINE_ORDER="mlx whisper.cpp groq"`.

Each engine reports availability: rc 0 = success, rc 2 = unavailable (skip silently),
anything else = failure (fall back to the next). So an order can safely list engines that
aren't installed — they're skipped.

## Precedence

**runtime env > `profile.env` > policy > built-in defaults.** Anything exported by hand
wins. RU+EN autodetect (`DICTATION_LANGUAGE=auto`) is already correct — keep it; Russian
stays Cyrillic, English stays Latin, nothing is translated. Groq sends no language field
when `auto` (omitting it *is* autodetect).

Inspect the resolved policy: `dictation-transcribe.sh --print-policy`.
