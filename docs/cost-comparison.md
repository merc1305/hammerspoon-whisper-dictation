# Cost comparison

**TL;DR:** the default setup is effectively free. Groq's free tier covers ordinary personal
dictation, and the local whisper.cpp fallback is `$0` and works offline. You only pay if you
push a lot of audio through Groq's paid tier.

> Prices below carry a **"Last verified"** date. Hosted-API pricing changes often — confirm
> against the vendor's current pricing page before quoting these.

## The three options

| Option | Marginal cost | Offline? | Notes |
|---|---|---|---|
| **Groq** `whisper-large-v3` (default fast path) | Free tier, then a few cents per audio-hour | No | Sub-second; needs a key at `~/.hammerspoon/groq_api_key` |
| **Local** whisper.cpp (`turbo-q5`) | **$0** | Yes | Metal on Apple Silicon; always the offline fallback |
| OpenAI `whisper-1` (not used here — reference only) | **$0.006 / minute** ≈ $0.36 / hour | No | The classic hosted-Whisper baseline |
| OpenAI `gpt-4o-transcribe` (reference only) | token-based, varies | No | Newer, priced per audio token |

_Last verified: 2026-07-13. Groq: see <https://groq.com/pricing>. OpenAI: see
<https://openai.com/api/pricing>._

## What this means for personal dictation

A heavy dictation day might be ~30 minutes of *actual speech* (VAD trims the silence before
it's ever sent). At the OpenAI `whisper-1` baseline that's `30 × $0.006 ≈ $0.18/day`, i.e.
a few dollars a month — and that's the *paid* baseline. On Groq's free tier the same usage
is **$0**, and if you ever run fully local it's **$0** regardless of volume.

## The LLM cleanup pass

`DICTATION_LLM_CLEANUP=1` sends the transcribed text (not the audio) to a small Groq chat
model (`llama-3.3-70b-versatile`) once per dictation. It reuses the same Groq key. The text
is tiny — a sentence or two — so the token cost is negligible and, on the free tier, `$0`.
Turn it off (`DICTATION_LLM_CLEANUP=0`) if you want to avoid the second round-trip entirely.

## Why Groq-first-then-local

Groq gives sub-second latency for free on a weak Mac where a local large model would be
slow. Local whisper.cpp is the always-available, zero-cost, offline safety net. You get the
speed of the cloud when it's up and the independence of local when it isn't — decided
automatically per run (`/tmp/dictation.engine` records which won).

## When to go fully local

Set `DICTATION_ENGINE_ORDER="whisper.cpp"` (or just don't configure a key) if you want
**zero network calls** — for privacy, for offline use, or to avoid any hosted cost. On
Apple Silicon with Metal this is fast enough to be your everyday path; on Intel it's the
slower-but-free fallback.
