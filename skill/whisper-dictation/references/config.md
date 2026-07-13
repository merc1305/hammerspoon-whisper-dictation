# Configuration reference

Everything resolves as **runtime env > `~/.local/share/whisper/profile.env` > policy >
built-in defaults**. There is no model menu — see [engine-policy.md](engine-policy.md).

## `init.lua` knobs (top of the file)

| Knob | Default | What it does / when to change |
|---|---|---|
| `ffmpegPath` | `/usr/local/bin/ffmpeg` | ffmpeg binary. `install.sh` rewrites it to the detected brew ffmpeg; falls back to `command -v ffmpeg`. Set to `/opt/homebrew/bin/ffmpeg` on Apple Silicon if editing by hand. |
| `transcribeScriptPath` | `~/.local/bin/dictation-transcribe.sh` | Path to the worker. |
| `minDurationSeconds` | `0.5` | Taps shorter than this are ignored. |
| `prerollSeconds` | `0.5` | How far back the pre-roll reaches. Lower trims latency but risks clipping the first syllable. |
| `bytesPerSecond` | `32000` | Buffer byte-rate (16 kHz mono s16). Must match the recorder format — do not change casually. |
| `maxBufferBytes` | `256 MB` | Ring-buffer rotation threshold. |
| `triggerMode` | `"ptt"` | `"ptt"` (hold `fn`) or `"toggle"` (tap to start/stop). |
| `toggleMaxSeconds` | `300` | Safety auto-stop for a toggle session left running. |
| `toggleStartAlert` | `true` | Brief hint when a toggle session starts. |
| `hotkeyWatchdogInterval` | `2` | Seconds between fn-tap health checks. |
| `menubarEnabled` | `true` | Show the menu-bar icon (in addition to the on-screen dot). |
| `menubarHistoryCount` | `10` | Recent dictations listed in the dropdown. |
| `indicatorColors` | — | On-screen dot palette (do not confuse with `menubarColors`). |
| `menubarColors` | — | Menu-bar icon palette (idle/recording/transcribing). |

## `dictation-transcribe.sh` environment variables

| Variable | Default | What it does / when to change |
|---|---|---|
| `WHISPER_PATH` | `~/.local/opt/whisper.cpp/build-metal/bin/whisper-cli` | Local whisper-cli binary. |
| `MODEL_PATH` | `~/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin` | Local model (usually set by policy). |
| `VAD_MODEL_PATH` | `~/.local/share/whisper/ggml-silero-v5.1.2.bin` | Silero VAD; absent → runs without VAD. |
| `GROQ_KEY_PATH` | `~/.hammerspoon/groq_api_key` | Groq key file (`chmod 600`). `GROQ_API_KEY` env overrides it. |
| `GROQ_MODEL` | `whisper-large-v3` | Cloud transcription model. |
| `GROQ_ENDPOINT` | Groq audio transcriptions URL | Rarely changed. |
| `MIN_AUDIO_SECONDS` | `0.75` | Audio shorter than this yields `ignored`. |
| `DICTATION_PROMPT` | RU+EN tuned prompt | Language/punctuation bias for the engines. |
| `DICTATION_LANGUAGE` | `auto` | `auto` = RU+EN autodetect (no translation); or an ISO code (`ru`/`en`) to force. |
| `HALLUCINATION_PHRASES` | RU/EN stems | Regexes for the static hallucination post-filter. |
| `DICTATION_ENGINE_ORDER` | `groq whisper.cpp` | Priority list of engine tokens `mlx｜whisper.cpp｜groq`. |
| `DICTATION_PROFILE` | `~/.local/share/whisper/profile.env` | Where the hardware profile is sourced from. |
| `DICTATION_MODEL_POLICY` | `~/.local/bin/dictation-model-policy.sh` | Policy library sourced at runtime. |
| `DICTATION_LLM_CLEANUP` | `0` | `1` enables the optional Groq-Llama cleanup pass (fail-open). |
| `GROQ_LLM_MODEL` | `llama-3.3-70b-versatile` | Cleanup chat model (70b is faithful for RU+EN). |
| `GROQ_LLM_ENDPOINT` | Groq chat completions URL | Cleanup endpoint. |
| `LLM_CLEANUP_TIMEOUT` | `4` | Hard timeout (s) for the cleanup call. |
| `LLM_MAX_TOKENS` | `1024` | Max tokens for the cleanup response. |
| `DICTATION_LLM_PROMPT` | (built-in) | Override the cleanup system prompt. |
| `DICTATION_HISTORY_PATH` | `~/.local/share/whisper/history.jsonl` | History journal location. |
| `DICTATION_HISTORY_MAX` | `50` | Journal cap; `0` disables it. |
| `MLX_WHISPER_BIN` / `MLX_MODEL` | `mlx_whisper` / `mlx-community/whisper-large-v3-turbo` | Optional Apple Silicon engine. |
| `WHISPER_THREADS` | detected | Local decode threads. |

Run `dictation-transcribe.sh --print-policy` to see the resolved engine order, model, and
tier without touching any IPC file.
