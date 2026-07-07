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

## Setup

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

- `init.lua` — paths, pre-roll, minimum hold duration, indicator colors, the `fn` trigger key.
- `dictation-transcribe.sh` — every path and knob is an environment variable (`WHISPER_PATH`, `MODEL_PATH`, `VAD_MODEL_PATH`, `GROQ_MODEL`, `DICTATION_PROMPT`, `HALLUCINATION_PHRASES`, …). The prompt steers language mix and punctuation; the default is tuned for mixed Russian/English dictation — change it for your languages.

## Diagnostics

Every run leaves evidence, so when transcription misbehaves you can tell *what* broke:

- `/tmp/dictation-last.wav` — the exact audio of the last dictation (was the recording truncated, or the transcription?);
- `~/.local/share/whisper/last.log` — timestamp, engine used (groq/local), audio duration, raw engine output, and the post-filtered text when the filter changed anything;
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
