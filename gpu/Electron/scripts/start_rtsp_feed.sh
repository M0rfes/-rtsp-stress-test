#!/usr/bin/env bash
# start_rtsp_feed.sh - Starts MediaMTX and feeds a 1440p (2560x1440) 25 FPS H.264 stream
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTSP_PORT="${RTSP_PORT:-8554}"
FEED_URL="rtsp://127.0.0.1:${RTSP_PORT}/live"

# Check for mediamtx
MEDIAMTX_BIN=""
if command -v mediamtx >/dev/null 2>&1; then
  MEDIAMTX_BIN="mediamtx"
elif [ -x "/opt/homebrew/bin/mediamtx" ]; then
  MEDIAMTX_BIN="/opt/homebrew/bin/mediamtx"
elif [ -x "/usr/local/bin/mediamtx" ]; then
  MEDIAMTX_BIN="/usr/local/bin/mediamtx"
fi

if [ -z "$MEDIAMTX_BIN" ]; then
  echo "[!] MediaMTX not found in PATH or standard directories."
  echo "    On macOS: brew install mediamtx"
  echo "    On Ubuntu/Linux: wget https://github.com/bluenviron/mediamtx/releases/download/v1.9.0/mediamtx_v1.9.0_linux_amd64.tar.gz && tar -xzf ... && sudo mv mediamtx /usr/local/bin/"
  exit 1
fi

echo "[*] Starting MediaMTX on port ${RTSP_PORT}..."
# Run mediamtx in background with custom configuration
CONFIG_PATH="$DIR/../mediamtx.yml"
"$MEDIAMTX_BIN" "$CONFIG_PATH" &
MEDIAMTX_PID=$!

trap "echo '[*] Stopping RTSP server and generator...'; kill $MEDIAMTX_PID 2>/dev/null || true; exit" SIGINT SIGTERM EXIT

sleep 1

echo "[*] Publishing 1440p (2560x1440) 25 FPS H.264 stream to ${FEED_URL}..."
echo "[*] Keyframe interval: 25 frames (1 keyframe per second)"

if [ -n "$INPUT_VIDEO" ] && [ -f "$INPUT_VIDEO" ]; then
  echo "[*] Streaming from video file: $INPUT_VIDEO"
  ffmpeg -re -stream_loop -1 -i "$INPUT_VIDEO" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -s 2560x1440 -r 25 -g 25 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp "$FEED_URL"
else
  # Generate 1440p 25fps test pattern per BENCHMARK_FINDINGS.md
  ffmpeg -re -f lavfi -i "testsrc2=size=2560x1440:rate=25" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 25 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp "$FEED_URL"
fi
