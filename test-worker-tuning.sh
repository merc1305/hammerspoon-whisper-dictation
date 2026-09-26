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
  DICTATION_RECORDINGS_DIR="$TMP/recordings" \
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

# Exercise actual PCM snapshots/chunking with ffmpeg, and mock only the recognition
# service. These tests neither upload microphone data nor use real API credentials.
TEST_ROOT="$ROOT" TEST_TMP="$TMP" /usr/bin/python3 - <<'PY'
import hashlib, http.server, json, math, os, pathlib, subprocess, threading, wave
root, tmp = pathlib.Path(os.environ['TEST_ROOT']), pathlib.Path(os.environ['TEST_TMP'])
ffmpeg = subprocess.check_output(['which', 'ffmpeg'], text=True).strip()
ffprobe = subprocess.check_output(['which', 'ffprobe'], text=True).strip()
worker = root / 'dictation-transcribe.sh'
model = tmp / 'model.bin'
recognizer = tmp / 'recognizer'
recognizer.write_text('''#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-f" ]; then audio="$2"; shift; fi
  shift
done
index="$(basename "$audio" .wav)"
if [ "${FAIL_CHUNK:-}" = "$index" ]; then exit 1; fi
printf '%s %s\\n' "${TEST_TRANSCRIPT:-Начало. Спасибо за просмотр. Важное продолжение. Финал.}" "$index"
''')
recognizer.chmod(0o755)
raw = tmp / 'story.raw'
# Deterministic changing signal, interleaved with quiet boundaries, over five minutes.
import array
samples = array.array('h', (int(6000 * math.sin(i * .071)) if i % 32000 < 28000 else 0 for i in range(321 * 16000)))
raw.write_bytes(samples.tobytes())
base = dict(os.environ, DICTATION_PROFILE=str(tmp/'missing'), DICTATION_MODEL_POLICY=str(tmp/'missing'),
            DICTATION_RECORDINGS_DIR=str(tmp/'recordings'), DICTATION_ENGINE_ORDER='whisper.cpp',
            DICTATION_LLM_CLEANUP='0', DICTATION_HISTORY_MAX='0', WHISPER_PATH=str(recognizer),
            MODEL_PATH=str(model), VAD_MODEL_PATH=str(tmp/'missing'), FFMPEG_PATH=ffmpeg,
            FFPROBE_PATH=ffprobe, LAST_WAV_PATH=str(tmp/'last.wav'), LAST_LOG_PATH=str(tmp/'last.log'))
serial = 0

def run(args, **overrides):
    global serial
    serial += 1
    job = tmp/f'job-{serial}'
    result = subprocess.run(['bash', str(worker), '--job', str(job)] + list(map(str, args)),
                            env=dict(base, **overrides), capture_output=True, text=True, timeout=60)
    return job, result

def pcm(path):
    with wave.open(str(path)) as f: return f.readframes(f.getnframes())

job, result = run(['--cut', raw, 16000, raw.stat().st_size])
assert result.returncode == 0, result.stderr
assert (job/'status').read_text().strip() == 'done'
assert pcm(job/'audio.wav') == raw.read_bytes()[16000:], 'snapshot lost samples'
chunks = sorted((job/'chunks').glob('*.wav'))
assert len(chunks) == 3, len(chunks)
assert b''.join(pcm(p) for p in chunks) == pcm(job/'audio.wav'), 'chunk boundary lost/duplicated samples'
text = (job/'transcript.txt').read_text()
assert text.count('Важное продолжение. Финал.') == 3, 'filter deleted real content'
assert text.index('00000') < text.index('00001') < text.index('00002'), 'chunks out of order'
assert (job/'raw.txt').is_file() and (job/'audio-ready').is_file()
assert (job/'audio.wav').stat().st_mode & 0o077 == 0, 'audio must be private'

failed, result = run(['--cut', raw, 0, raw.stat().st_size], FAIL_CHUNK='00001')
assert result.returncode != 0
assert (failed/'status').read_text().startswith('error:chunk-2-of-3')
assert (failed/'transcript.txt').read_text() == '', 'must not publish the successful prefix'
assert pcm(tmp/'last.wav') == raw.read_bytes(), 'failure must retain the whole recording'
retry, result = run(['--retry'])
assert result.returncode == 0
assert pcm(retry/'audio.wav') == pcm(failed/'audio.wav'), 'retry must use identical audio'
assert '00002' in (retry/'transcript.txt').read_text(), 'retry omitted final chunk'

short, result = run(['--cut', raw, 0, raw.stat().st_size + 32000])
assert result.returncode != 0
assert (short/'status').read_text().strip() == 'error:incomplete-recording'
assert not (short/'audio-ready').exists()
assert pcm(tmp/'last.wav') == raw.read_bytes(), 'bad snapshot must not replace last good audio'

# A local HTTP fixture covers cloud retry and cleanup truncation without spending.
class Handler(http.server.BaseHTTPRequestHandler):
    payload = {}
    requests = 0
    fail_once = False
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        Handler.requests += 1
        if Handler.fail_once:
            Handler.fail_once = False
            self.send_response(503); self.end_headers(); return
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps(Handler.payload).encode())
    def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
endpoint = f'http://127.0.0.1:{server.server_port}'
clip = tmp/'short.wav'
with wave.open(str(clip), 'wb') as f:
    f.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
    f.writeframes(raw.read_bytes()[:64000])
Handler.payload = {'text': 'Первая мысль. Спасибо за просмотр. Вторая мысль остаётся.'}
Handler.fail_once = True
cloud, result = run([clip], DICTATION_ENGINE_ORDER='groq', GROQ_API_KEY='test-not-a-secret',
                    GROQ_ENDPOINT=endpoint, no_proxy='127.0.0.1', NO_PROXY='127.0.0.1')
assert result.returncode == 0 and Handler.requests == 2
assert 'Вторая мысль остаётся.' in (cloud/'transcript.txt').read_text()

original = 'Начало рассказа. Важная середина. Последнее предложение. 00000'
for reason, content, expected in [
    ('length', 'Начало рассказа.', original),
    ('stop', 'Начало рассказа. Последнее предложение. 00000', original),
    ('stop', 'Начало рассказа! Важная середина; последнее предложение. 00000',
     'Начало рассказа! Важная середина; последнее предложение. 00000'),
]:
    Handler.payload = {'choices': [{'finish_reason': reason, 'message': {'content': content}}]}
    cleaned, result = run([clip], TEST_TRANSCRIPT=original.rsplit(' ', 1)[0], DICTATION_LLM_CLEANUP='1',
                          GROQ_API_KEY='test-not-a-secret', GROQ_LLM_ENDPOINT=endpoint,
                          no_proxy='127.0.0.1', NO_PROXY='127.0.0.1')
    assert result.returncode == 0
    assert (cleaned/'transcript.txt').read_text().strip() == expected
server.shutdown()
print('PASS 321s PCM capture, exact chunk coverage, full-audio retry, partial failure, cloud retry, lossless cleanup')
PY
