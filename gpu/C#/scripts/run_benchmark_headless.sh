#!/usr/bin/env bash
# run_benchmark_headless.sh - 6-Hour GPU Benchmark Runner (AWS Ubuntu NVIDIA + Xvfb, local macOS/Windows headed fallback)
set -e
ulimit -n 10240 2>/dev/null || true

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

LOG_DIR="${BENCHMARK_LOG_DIR:-/var/log/benchmark}"
sudo mkdir -p "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR"
sudo chmod 777 "$LOG_DIR" 2>/dev/null || true

RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/live}"
STREAM_COUNT="${STREAM_COUNT:-30}"
HW_ACCEL="${HW_ACCEL:-auto}"

echo "=== RTSP 30-Stream GPU Zero-Copy Benchmark (C# Avalonia - FFmpeg.AutoGen) ==="
echo "Working directory: $DIR"
echo "Log directory:     $LOG_DIR"
echo "Active streams:    $STREAM_COUNT"
echo "Target RTSP URL:   $RTSP_URL"
echo "Hardware Accel:    $HW_ACCEL"

if [[ "$OSTYPE" == "linux"* ]] && ! command -v xvfb-run >/dev/null 2>&1; then
  echo "[!] xvfb-run not found. On Ubuntu run: sudo apt update && sudo apt install -y xvfb"
  exit 1
fi

PUBLISH_DIR="$DIR/bin/publish"
APP_DLL="$PUBLISH_DIR/rtsp-stress-test-csharp-gpu.dll"
APP_BIN="$PUBLISH_DIR/rtsp-stress-test-csharp-gpu"

if [ ! -f "$APP_DLL" ] && [ ! -f "$APP_BIN" ]; then
  echo "[*] Publishing C# Avalonia GPU benchmark application (Release)..."
  dotnet publish -c Release -o "$PUBLISH_DIR"
fi

FEED_PID=""
RTSP_HOST=$(echo "$RTSP_URL" | sed -e 's|^.*://||' -e 's|/.*$||' -e 's|:.*$||')
RTSP_PORT=$(echo "$RTSP_URL" | sed -e 's|^.*://||' -e 's|/.*$||' | grep ':' | sed -e 's|^.*:||')
RTSP_PORT="${RTSP_PORT:-8554}"

if [[ "$RTSP_HOST" == "127.0.0.1" ]] || [[ "$RTSP_HOST" == "localhost" ]]; then
  if ! (echo > /dev/tcp/127.0.0.1/8554) 2>/dev/null; then
    echo "[*] Local RTSP server not detected on port 8554. Starting local MediaMTX test feed..."
    "$DIR/scripts/start_rtsp_feed.sh" &
    FEED_PID=$!
    sleep 2
  fi
else
  echo "[*] RTSP stream hosted on separate VPC box: $RTSP_HOST:$RTSP_PORT"
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 3 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
      echo "[✓] Successfully connected to RTSP server on $RTSP_HOST:$RTSP_PORT"
    else
      echo "[!] WARNING: Unable to connect to $RTSP_HOST:$RTSP_PORT."
    fi
  fi
fi

echo "[*] Launching C# Avalonia GPU application (zero-copy hardware decoding)..."

CMD=()
if [ -f "$APP_BIN" ] && [ -x "$APP_BIN" ]; then
  CMD=("$APP_BIN" --url "$RTSP_URL" --streams "$STREAM_COUNT" --hw-accel "$HW_ACCEL" --log-dir "$LOG_DIR")
else
  CMD=(dotnet "$APP_DLL" --url "$RTSP_URL" --streams "$STREAM_COUNT" --hw-accel "$HW_ACCEL" --log-dir "$LOG_DIR")
fi

if [[ "$OSTYPE" == "linux"* ]]; then
  export AVALONIA_GLOBAL_SCALE_FACTOR=1
  xvfb-run -a -s "-screen 0 2560x1440x24" "${CMD[@]}" &
  APP_PID=$!
else
  "${CMD[@]}" &
  APP_PID=$!
fi

echo "[*] Benchmark application running with PID: $APP_PID"
echo "[*] Starting external hardware polling..."
"$DIR/scripts/poll_hardware.sh" "$APP_PID" &
POLL_PID=$!

cleanup() {
  echo "[*] Stopping benchmark..."
  kill "$APP_PID" "$POLL_PID" 2>/dev/null || true
  if [ -n "$FEED_PID" ]; then
    kill "$FEED_PID" 2>/dev/null || true
  fi
  exit 0
}

trap cleanup SIGINT SIGTERM

echo "[*] 6-Hour Benchmark is now actively running."
echo "[*] Monitor FPS metrics:      tail -f $LOG_DIR/fps_metrics.log"
echo "[*] Monitor Hardware metrics: tail -f $LOG_DIR/hardware_metrics.csv"

wait $APP_PID
