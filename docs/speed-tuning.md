# Speed tuning

This is a **short-dictation** tool, not a batch transcriber. The whole budget is measured
in a couple of seconds, and most of it is fixed.

## The latency budget

| Stage | Cost | Notes |
|---|---|---|
| Cold start | **0** | the recorder never stops (the ring buffer) |
| Tail flush after release | ≤ ~0.8 s | wait for ffmpeg to write the last packet |
| Engine (Groq) | ~0.3–1 s | network round-trip to `whisper-large-v3` |
| Engine (local whisper.cpp) | depends on chip | Metal on Apple Silicon; CPU on Intel |
| LLM cleanup (optional) | ~0.3–1 s | only if `DICTATION_LLM_CLEANUP=1`; fail-open |
| Paste | ~0.25 s | clipboard + `Cmd+V` (`pasteTimer`) |

## Groq fast path vs offline

On a weak Mac the order is `groq whisper.cpp`: Groq is the sub-second fast path and local
whisper.cpp is the offline fallback. Kill your network and it still works — just slower and
fully local. Check which engine actually ran:

```bash
cat /tmp/dictation.engine            # groq | whisper.cpp | mlx
tail -n 20 ~/.local/share/whisper/last.log
```

## The whisper.cpp flags (and why)

`transcribe_local` runs `whisper-cli` with:

- `-t 8` — threads (tune to your core count via `WHISPER_THREADS`);
- `-ng` — no GPU offload flag toggling / greedy path for short clips;
- `-bs 1 -bo 1` — beam size / best-of 1: greedy, lowest latency;
- `-nf` — no fallback temperature sweeps;
- `-mc 0` — carry **no** decoded context into the next 30 s window (the main
  anti-hallucination fix; this build has no `--no-context` flag, `-mc 0` is the equivalent);
- `-sns` — suppress non-speech tokens;
- `--vad --vad-model …` — cut silence before decoding (Silero VAD);
- `-nt -np` — no timestamps, no progress;
- `-l "$DICTATION_LANGUAGE"` (`auto` by default) + one `--prompt`.

## Model choice

The universal model is `ggml-large-v3-turbo-q5_0.bin` — **turbo is ~8× faster than
large-v3** with near-identical Russian quality, and `q5_0` quantization keeps it small and
fast. A strong Apple Silicon machine with `mlx_whisper` can use the `mlx` engine
(`mlx-community/whisper-large-v3-turbo`) instead. See [model-policy.md](model-policy.md).

## Knobs in `init.lua`

- `prerollSeconds` (0.5) — how far back the pre-roll reaches; lower trims latency but risks
  clipping the first syllable;
- `minDurationSeconds` (0.5) — taps shorter than this are ignored;
- the tail-flush deadline (~0.8 s in `finishCapture`) — the largest tunable chunk;
- `bytesPerSecond` (32000) — must match the recorder format; don't change casually.

## Turning cleanup off for speed

The LLM cleanup pass adds a second Groq round-trip. If you want the lowest possible latency,
set `DICTATION_LLM_CLEANUP=0` (it is off by default; the installer enables it only when a
Groq key is present). The static hallucination filter always runs and costs nothing.
