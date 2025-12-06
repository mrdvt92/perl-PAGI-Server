# PAGI::Simple Streaming Bodies

Stream request bodies without buffering: decode UTF-8 on the fly or pipe raw bytes straight to disk.

## Quick Start
- Run: `pagi-server --app examples/simple-14-streaming/app.pl --port 5000`
- Open `http://localhost:5000/` for a small UI that exercises both endpoints.
- Default caps: 256KB for decoded text, or `content-length`/256KB for uploads. Override with `?limit=...`.

## Endpoints
- `POST /stream/decode?strict=0|1&limit=BYTES` — streams the body with `decode => 'UTF-8'`. Returns JSON: `decoded`, `bytes_read`, `strict`, `limit_bytes`, `content_length`. `strict=1` croaks on malformed/truncated UTF-8.
- `POST /stream/upload?limit=BYTES` — streams raw bytes to `/tmp/pagi-simple-stream-upload.bin` using `stream_to_file`. Returns JSON: `saved_to`, `bytes_written`, `limit_bytes`, `content_length`.

## Curl Samples
- Lenient decode: `curl -X POST --data-binary 'café 🌶️' 'http://localhost:5000/stream/decode'`
- Strict decode error: `printf 'caf\\xC3' | curl -X POST --data-binary @- 'http://localhost:5000/stream/decode?strict=1&limit=16'`
- Upload a file: `curl -X POST --data-binary @README.md 'http://localhost:5000/stream/upload?limit=131072'`
- Inspect the saved file: `ls -lh /tmp/pagi-simple-stream-upload.bin`

The UI page also shows JSON responses and demonstrates the size guard behavior.
