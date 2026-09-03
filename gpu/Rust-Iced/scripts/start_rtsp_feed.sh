#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTSP_PORT="${RTSP_PORT:-8554}"
FEED_URL="rtsp://127.0.0.1:${RTSP_PORT}/live"

MEDIAMTX_BIN="/opt/homebrew/bin/mediamtx"
if [ ! -x "$MEDIAMTX_BIN" ]; then
  MEDIAMTX_BIN="mediamtx"
fi

CONFIG_PATH="$DIR/../mediamtx.yml"
echo "[*] Starting MediaMTX..."
"$MEDIAMTX_BIN" "$CONFIG_PATH" &
MEDIAMTX_PID=$!

trap "kill $MEDIAMTX_PID 2>/dev/null || true; exit" SIGINT SIGTERM EXIT

sleep 1

echo "[*] Publishing 1440p (2560x1440) 25 FPS H.264 stream to ${FEED_URL}..."
ffmpeg -re -f lavfi -i "testsrc2=size=2560x1440:rate=25" \
  -c:v libx264 -preset ultrafast -tune zerolatency -threads 4 \
  -g 25 -pix_fmt yuv420p \
  -f rtsp -rtsp_transport tcp "$FEED_URL"
