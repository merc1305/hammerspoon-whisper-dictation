# Model policy

**There is no model menu.** `dictation-detect.sh` inspects the machine once at install time
and picks the engine order and local model automatically, writing them into
`~/.local/share/whisper/profile.env`. At runtime `dictation-transcribe.sh` sources that
profile, and `dictation-model-policy.sh` fills any gaps. The model is *not* a user-facing
knob — you tune behavior, not model files.

## The policy table

| Tier | Condition | Engine order | Local model (preferred) |
|---|---|---|---|
| **apple-strong** + mlx | arm64, RAM ≥ 16, `mlx_whisper` present | `mlx whisper.cpp groq` | turbo → turbo-q5 → large-v3 |
| **apple-strong / apple-capable** | arm64, whisper.cpp built with Metal | `whisper.cpp groq` | turbo-q5 → turbo → large-v3 |
| **weak** | Intel / low RAM / no Metal build | `groq whisper.cpp` | turbo-q5 (offline fallback) |
| empty | no key, no build | `groq whisper.cpp` | turbo-q5 (default path) |

- Cloud model: `GROQ_MODEL=whisper-large-v3`.
- Local tokens: `mlx | whisper.cpp | groq` — the winning one is written verbatim to
  `/tmp/dictation.engine` and into the history.

## turbo vs large-v3

The universal model is **`ggml-large-v3-turbo-q5_0.bin`**. Turbo trades a hair of accuracy
for a large latency win — on Russian it is roughly on par with large-v3 while being about
**8× faster to decode**. `q5_0` is a 5-bit quantization that keeps the file ~560 MB and the
decode fast. large-v3 is only worth it on a strong Apple Silicon machine with plenty of RAM,
which the policy table already accounts for.

Rough word-error-rate reference (Russian, illustrative — benchmarks vary by dataset):

| Model | RU WER (approx.) | Relative speed |
|---|---|---|
| large-v3 | ~9% | 1× |
| large-v3-turbo (q5) | ~11% | ~8× |

_Last verified: 2026-07-13 — treat as order-of-magnitude, not exact; re-measure on your own
audio._

## RU + EN by default (no translation)

`DICTATION_LANGUAGE` defaults to **`auto`** — Whisper detects the language per utterance and
keeps **Russian in Cyrillic, English in Latin, and code-switching intact**. Nothing is
translated. Implementation:

- whisper.cpp: `-l auto` (i.e. `-l "$DICTATION_LANGUAGE"`);
- Groq: the `language` form field is sent **only** when a specific language is forced —
  omitting it *is* autodetect;
- mlx: `--language` only when forced.

Language *bias* (not a hard force) lives in `DICTATION_PROMPT`. Set `DICTATION_LANGUAGE=ru`
or `en` to force a single language across every engine.

## Precedence

Every setting resolves as **runtime env > `profile.env` > policy > built-in defaults**, so
anything you export by hand always wins. Inspect the resolved policy any time:

```bash
dictation-transcribe.sh --print-policy
```
