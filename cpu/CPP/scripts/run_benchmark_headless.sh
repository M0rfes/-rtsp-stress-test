#!/usr/bin/env bash
# run_benchmark_headless.sh - 6-Hour Benchmark Runner for Headless Linux (AWS Ubuntu)
set -e
ulimit -n 10240 2>/dev/null || true

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

LOG_DIR="${BENCHMARK_LOG_DIR:-/var/log/benchmark}"
sudo mkdir -p "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR"
sudo chmod 777 "$LOG_DIR" 2>/dev/null || true

RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/live}"
STREAM_COUNT="${STREAM_COUNT:-30}"

echo "=== RTSP 30-Stream CPU Benchmark (C++ Qt6 - libavcodec) ==="
echo "Working directory: $DIR"
echo "Log directory:     $LOG_DIR"
echo "Active streams:    $STREAM_COUNT"
echo "Target RTSP URL:   $RTSP_URL"

# Check for xvfb on Linux
if [[ "$OSTYPE" == "linux"* ]] && ! command -v xvfb-run >/dev/null 2>&1; then
  echo "[!] xvfb-run not found. On Ubuntu run: sudo apt update && sudo apt install -y xvfb"
  exit 1
fi

# Build optimized release binary if not present
BINARY_PATH="$DIR/build/rtsp-stress-test-cpp-cpu"
if [ ! -f "$BINARY_PATH" ]; then
  echo "[*] Building C++ Qt6 benchmark application (Release)..."
  cmake -B build -DCMAKE_BUILD_TYPE=Release
  NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  cmake --build build -j"$NPROC"
fi

RTSP_HOST=$(echo "$RTSP_URL" | sed -e 's|^.*://||' -e 's|/.*$||' -e 's|:.*$||')
RTSP_PORT=$(echo "$RTSP_URL" | sed -e 's|^.*://||' -e 's|/.*$||' | grep ':' | sed -e 's|^.*:||')
RTSP_PORT="${RTSP_PORT:-8554}"
RTSP_SERVER_DIR="$(cd "$DIR/../.." && pwd)/rtsp-server"

echo "[*] Shared RTSP server (10 × 30 = 300 readers): $RTSP_HOST:$RTSP_PORT"
if command -v nc >/dev/null 2>&1; then
  if nc -z -w 3 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
    echo "[✓] RTSP server reachable at $RTSP_HOST:$RTSP_PORT"
  else
    echo "[!] RTSP server not reachable at $RTSP_HOST:$RTSP_PORT"
    echo "    Start it with: $RTSP_SERVER_DIR/start.sh"
    echo "    Dedicated box: sudo $RTSP_SERVER_DIR/setup.sh"
  fi
elif [[ "$RTSP_HOST" == "127.0.0.1" ]] || [[ "$RTSP_HOST" == "localhost" ]]; then
  if ! (echo > /dev/tcp/127.0.0.1/"$RTSP_PORT") 2>/dev/null; then
    echo "[!] Local RTSP server not detected on port $RTSP_PORT"
    echo "    Start it with: $RTSP_SERVER_DIR/start.sh"
  fi
fi

echo "[*] Launching C++ Qt6 CPU application (software decoding backend)..."

# On Linux, run inside Xvfb with pure software rendering flags
if [[ "$OSTYPE" == "linux"* ]]; then
  export LIBGL_ALWAYS_SOFTWARE=1
  export QT_QPA_PLATFORM=xcb
  xvfb-run -a -s "-screen 0 2560x1440x24" "$BINARY_PATH" --url "$RTSP_URL" --streams "$STREAM_COUNT" --log-dir "$LOG_DIR" &
  APP_PID=$!
else
  "$BINARY_PATH" --url "$RTSP_URL" --streams "$STREAM_COUNT" --log-dir "$LOG_DIR" &
  APP_PID=$!
fi

echo "[*] Benchmark application running with PID: $APP_PID"

# Start external hardware polling script in background
echo "[*] Starting external hardware polling..."
"$DIR/scripts/poll_hardware.sh" "$APP_PID" &
POLL_PID=$!

cleanup() {
  echo "[*] Stopping benchmark..."
  kill "$APP_PID" "$POLL_PID" 2>/dev/null || true
  exit 0
}

trap cleanup SIGINT SIGTERM

echo "[*] 6-Hour Benchmark is now actively running."
echo "[*] Monitor FPS metrics:      tail -f $LOG_DIR/fps_metrics.log"
echo "[*] Monitor Hardware metrics: tail -f $LOG_DIR/hardware_metrics.csv"

wait $APP_PID
