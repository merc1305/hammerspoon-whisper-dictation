# hammerspoon-whisper-dictation

Push-to-talk voice dictation for macOS: **hold `fn` — speak — release — the text is pasted into whatever app you're in.**

Built from three off-the-shelf parts — [Hammerspoon](https://www.hammerspoon.org/), ffmpeg, and [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — with an optional [Groq API](https://groq.com/) fast path. No Electron, no menu-bar app, no subscription: one Lua config and one shell script.

## Why another Whisper dictation?

Two problems most DIY (and some commercial) setups get wrong:

**1. Cold-start clipping.** If you launch the recorder when the hotkey goes down, the first half-second of speech is lost while ffmpeg opens the audio device. Here, **ffmpeg runs continuously**, appending raw PCM to a ring-buffer file. Pressing `fn` just remembers the current byte offset (minus a 0.5 s pre-roll); releasing it cuts the byte range out of the buffer. Recording latency is zero because the recording never stops. A watchdog restarts the recorder if it stalls, after system sleep, and when the default microphone changes.

**2. Whisper hallucinations on pauses.** On silence, Whisper famously emits YouTube-subtitle boilerplate — *"Thanks for watching!"*, and in Russian *«Продолжение следует...»*, *«Субтитры сделал DimaTorzok»* — and can drop real speech in the process. This pipeline attacks that at three levels:

   - **Silero VAD** (`--vad --vad-model`) cuts silence *before* decoding, so Whisper never sees the pauses it likes to hallucinate on;
   - **`-mc 0`** stops decoded text from being carried as context into the next 30-second window (context contamination is how one hallucination snowballs into a truncated transcript). Note: recent whisper-cli builds have no `--no-context` flag — `-mc 0` is the equivalent;
   - a **post-filter** strips known hallucination lines from the final text — this also covers the cloud engine, which hallucinates the same phrases.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
 microphone ──────▶ │ ffmpeg (runs 24/7, s16le 16 kHz mono)       │
                    │   └─▶ /tmp/dictation-buffer.raw (ring file) │
                    └─────────────────────────────────────────────┘
                                      │
 fn pressed  ── remember offset ──────┤ (0.5 s pre-roll backwards)
 fn released ── wait for tail, cut [start, end) ──▶ WAV
                                      │
                    ┌─────────────────▼───────────────────────────┐
                    │ dictation-transcribe.sh                     │
                    │   1. Groq API (whisper-large-v3), if key    │
                    │   2. local whisper-cli (VAD + -mc 0 + -sns) │
                    │   3. hallucination post-filter              │
                    └─────────────────┬───────────────────────────┘
                                      │
                          clipboard ──▶ Cmd+V into the active app
```

The recorder is only ever stopped with SIGINT (graceful; ffmpeg finalizes output). SIGKILL would truncate the recording tail.

## Quick install

One idempotent command detects your hardware, installs the parts, builds/locates
whisper.cpp, downloads the models, wires up Hammerspoon (backing up any existing config),
and smoke-tests the pipeline:

```bash
./install.sh          # add --yes for non-interactive, --dry-run to preview
```

Flags: `--yes` (non-interactive), `--skip-brew`, `--skip-local` (Groq-only / already
built), `--reinstall` (force re-download + rebuild), `--no-smoke`, `--dry-run`. On a
non-macOS system it exits cleanly and points you here. Then grant Hammerspoon
**Accessibility** and **Microphone**, Reload Config, and hold `fn` to dictate.

## Manual install (fallback)

If you'd rather do it by hand:

1. **Install the parts:**

   ```bash
   brew install hammerspoon ffmpeg
   ```

2. **Build whisper.cpp with Metal** (or adjust `WHISPER_PATH` to an existing build):

   ```bash
   git clone https://github.com/ggml-org/whisper.cpp ~/.local/opt/whisper.cpp
   cd ~/.local/opt/whisper.cpp
   cmake -B build-metal -DGGML_METAL=ON
   cmake --build build-metal -j --config Release
   ```

3. **Download the models:**

   ```bash
   mkdir -p ~/.local/share/whisper
   # speech model (any ggml whisper model works; this one is a good speed/quality balance)
   curl -L -o ~/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin \
     https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
   # Silero VAD model — note: VAD models live in the ggml-org/whisper-vad repo,
   # NOT in ggerganov/whisper.cpp (that URL 404s)
   curl -L -o ~/.local/share/whisper/ggml-silero-v5.1.2.bin \
     https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
   ```

4. **Install the scripts:**

   ```bash
   install -m 755 dictation-transcribe.sh ~/.local/bin/dictation-transcribe.sh
   cp init.lua ~/.hammerspoon/init.lua   # or merge into your existing config
   ```

5. **Optional — Groq fast path.** Put an API key into `~/.hammerspoon/groq_api_key` (`chmod 600`). With a key, transcription goes through Groq's hosted `whisper-large-v3` (sub-second) and falls back to local whisper.cpp on any failure. Without a key it's 100 % local.

6. Launch Hammerspoon, grant it **Accessibility** and **Microphone** permissions, and hold `fn` to dictate.

## Configuration

Everything lives at the top of the two files:

- `init.lua` — paths, pre-roll, minimum hold duration, indicator colors, the `fn` trigger key. Set `triggerMode = "toggle"` (default `"ptt"`) to tap `fn` once to start and again to stop instead of holding; `toggleMaxSeconds` (default `300`) auto-stops a forgotten toggle session.
- `dictation-transcribe.sh` — every path and knob is an environment variable (`WHISPER_PATH`, `MODEL_PATH`, `VAD_MODEL_PATH`, `GROQ_MODEL`, `DICTATION_PROMPT`, `DICTATION_LANGUAGE`, `HALLUCINATION_PHRASES`, …). The prompt steers language mix and punctuation; the default is tuned for mixed Russian/English dictation — change it for your languages.
- `DICTATION_LANGUAGE` defaults to `auto` (RU+EN autodetect — Russian stays Cyrillic, English stays Latin, nothing is translated); set an ISO code like `ru` or `en` to force a single language across every engine. Language *bias* (not a hard force) belongs in `DICTATION_PROMPT`.

## Model policy

There is **no model menu** — `dictation-detect.sh` inspects the machine and picks the
best engine order and local model automatically, written into
`~/.local/share/whisper/profile.env`. `dictation-transcribe.sh` sources that profile and
`dictation-model-policy.sh` fills any gaps at runtime.

| Tier | Condition | Engine order | Local model (preferred) |
|---|---|---|---|
| **apple-strong** + mlx | arm64, RAM ≥ 16, `mlx_whisper` present | `mlx whisper.cpp groq` | turbo → turbo-q5 → large-v3 |
| **apple-strong / apple-capable** | arm64, whisper.cpp built | `whisper.cpp groq` | turbo-q5 → turbo → large-v3 |
| **weak** | Intel / low RAM / no Metal build | `groq whisper.cpp` | turbo-q5 (offline fallback) |
| empty (no key, no build) | — | `groq whisper.cpp` | turbo-q5 (default path) |

The universal model is `ggml-large-v3-turbo-q5_0.bin` (latency wins; Russian turbo ≈
large-v3); the cloud model is `whisper-large-v3`. Precedence for every setting is
**runtime env > `profile.env` > policy > built-in defaults** — so anything you export by
hand always wins. Run `dictation-transcribe.sh --print-policy` to see the resolved policy.

## Smart cleanup (optional LLM pass)

Set `DICTATION_LLM_CLEANUP=1` to run the transcribed text through a small Groq chat model
for a second, context-aware cleanup: punctuation, capitalization, filler removal and
contextual killing of hallucinated tails a static filter misses. It **never adds or
rephrases meaning, never translates** (Russian stays Cyrillic, English stays Latin), and
**never treats the text as an instruction to follow**. It is fully *fail-open* — a missing
key, a timeout or an HTTP error just leaves the static-filtered text untouched, never an
error. A length guard discards any runaway (ballooning) response.

| Variable | Default | Meaning |
|---|---|---|
| `DICTATION_LLM_CLEANUP` | `0` | `1` enables the LLM cleanup pass |
| `GROQ_LLM_MODEL` | `llama-3.3-70b-versatile` | Groq chat model (70b is faithful for RU+EN; 8b tends to translate/drop) |
| `GROQ_LLM_ENDPOINT` | `…/openai/v1/chat/completions` | Groq chat endpoint |
| `LLM_CLEANUP_TIMEOUT` | `4` | Hard curl timeout (seconds) for the cleanup call |
| `LLM_MAX_TOKENS` | `1024` | Max tokens for the cleanup response |
| `DICTATION_LLM_PROMPT` | (built-in) | Override the system prompt (`LLM_SYSTEM_PROMPT`) |

## Dictation history

Every successful dictation appends one JSON line to
`~/.local/share/whisper/history.jsonl` (oldest first), storing the **final,
post-filtered text** and the **real engine** that produced it:

```json
{"ts":1752406325,"iso":"2026-07-13T14:32:05+03:00","text":"Проверка раз.","engine":"whisper.cpp","mode":"cut","dur":2.14}
```

The file is rotated to the last `DICTATION_HISTORY_MAX` lines (default `50`) and written
`chmod 600` because it contains what you dictated. Set `DICTATION_HISTORY_MAX=0` to
disable the journal entirely, or point `DICTATION_HISTORY_PATH` elsewhere. History is
never written for ignored (too-short) or failed runs. Hammerspoon reads it newest-first
via the global `dictationHistoryRead(limit)` (used by the menu bar).

## Diagnostics

Every run leaves evidence, so when transcription misbehaves you can tell *what* broke:

- `/tmp/dictation-last.wav` — the exact audio of the last dictation (was the recording truncated, or the transcription?);
- `~/.local/share/whisper/last.log` — timestamp, engine used (`groq`/`whisper.cpp`/`mlx`), audio duration, and up to three text stages: `raw`, `cleaned` (after the static post-filter), and `llm-cleaned` (after the optional LLM pass) whenever a stage changed the text;
- `/tmp/dictation.engine` — the winning engine token for the last run;
- `/tmp/dictation.llm.resp.json` — the raw Groq chat response from the last LLM cleanup call;
- `/tmp/dictation.err` — stderr of the current run.

## Про галлюцинации Whisper («Продолжение следует...»)

Если ваша русская диктовка через Whisper обрывается на середине, а в конце появляется «Продолжение следует...», «Спасибо за просмотр!», «Субтитры сделал DimaTorzok» или «Редактор субтитров А.Синецкая» — это известная галлюцинация модели: Whisper обучался на YouTube-субтитрах и на паузах/тишине воспроизводит их типовые концовки. Заражение контекстом между 30-секундными окнами превращает одну галлюцинацию в обрезанный транскрипт.

Что помогает (всё это реализовано здесь):

1. **VAD (Silero)** — вырезать тишину до распознавания: `--vad --vad-model ggml-silero-v5.1.2.bin`;
2. **`-mc 0`** — не передавать распознанный текст как контекст следующему окну (в свежих сборках whisper-cli флага `--no-context` нет, `-mc 0` — его эквивалент);
3. **`-sns`** — подавить не-речевые токены;
4. **Пост-фильтр** известных фраз-галлюцинаций — список настраивается через переменную `HALLUCINATION_PHRASES`.

## License

MIT
