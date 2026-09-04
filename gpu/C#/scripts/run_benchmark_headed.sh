#!/usr/bin/env bash
# run_benchmark_headed.sh - Run C# Avalonia GPU Benchmark with a visible desktop window
set -e
ulimit -n 10240 2>/dev/null || true

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

LOG_DIR="${BENCHMARK_LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/live}"
STREAM_COUNT="${STREAM_COUNT:-30}"
HW_ACCEL="${HW_ACCEL:-auto}"

echo "=== RTSP 30-Stream GPU Zero-Copy Benchmark (Headed Desktop Mode) ==="
echo "Working directory: $DIR"
echo "Log directory:     $LOG_DIR"
echo "Active streams:    $STREAM_COUNT"
echo "Target RTSP URL:   $RTSP_URL"
echo "Hardware Accel:    $HW_ACCEL"

PUBLISH_DIR="$DIR/bin/publish"
APP_DLL="$PUBLISH_DIR/rtsp-stress-test-csharp-gpu.dll"
APP_BIN="$PUBLISH_DIR/rtsp-stress-test-csharp-gpu"

if [ ! -f "$APP_DLL" ] && [ ! -f "$APP_BIN" ]; then
  echo "[*] Publishing C# Avalonia GPU benchmark application (Release)..."
  dotnet publish -c Release -o "$PUBLISH_DIR"
fi

if [ -f "$APP_BIN" ] && [ -x "$APP_BIN" ]; then
  "$APP_BIN" --url "$RTSP_URL" --streams "$STREAM_COUNT" --hw-accel "$HW_ACCEL" --log-dir "$LOG_DIR"
else
  dotnet "$APP_DLL" --url "$RTSP_URL" --streams "$STREAM_COUNT" --hw-accel "$HW_ACCEL" --log-dir "$LOG_DIR"
fi
