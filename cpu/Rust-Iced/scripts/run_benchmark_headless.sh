#!/usr/bin/env bash
# run_benchmark_headless.sh - 6-Hour Benchmark Runner for Headless Linux (AWS Ubuntu)
# Handles both local test feeds and remote/VPC separate RTSP server instances
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

LOG_DIR="${BENCHMARK_LOG_DIR:-/var/log/benchmark}"
sudo mkdir -p "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR"
sudo chmod 777 "$LOG_DIR" 2>/dev/null || true

RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/live}"
STREAM_COUNT="${STREAM_COUNT:-30}"

echo "=== RTSP 30-Stream CPU Benchmark (Rust Iced - tiny-skia) ==="
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
BINARY_PATH="$DIR/target/release/rtsp-stress-test-iced-cpu"
if [ ! -f "$BINARY_PATH" ]; then
  echo "[*] Building Rust Iced benchmark application (Release)..."
  cargo build --release
fi

FEED_PID=""
# Parse RTSP host and port
RTSP_HOST=$(echo "$RTSP_URL" | sed -e 's|^.*://||' -e 's|/.*$||' -e 's|:.*$||')
RTSP_PORT=$(echo "$RTSP_URL" | sed -e 's|^.*://||' -e 's|/.*$||' | grep ':' | sed -e 's|^.*:||')
RTSP_PORT="${RTSP_PORT:-8554}"

if [[ "$RTSP_HOST" == "127.0.0.1" ]] || [[ "$RTSP_HOST" == "localhost" ]]; then
  # Local feed test mode
  if ! (echo > /dev/tcp/127.0.0.1/8554) 2>/dev/null; then
    echo "[*] Local RTSP server not detected on port 8554. Starting local MediaMTX test feed..."
    "$DIR/scripts/start_rtsp_feed.sh" &
    FEED_PID=$!
    sleep 2
  fi
else
  # Remote / Separate VPC Box Mode
  echo "[*] RTSP stream hosted on separate VPC box: $RTSP_HOST:$RTSP_PORT"
  echo "[*] Testing network connectivity to $RTSP_HOST:$RTSP_PORT..."
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 3 "$RTSP_HOST" "$RTSP_PORT" 2>/dev/null; then
      echo "[✓] Successfully connected to RTSP server on $RTSP_HOST:$RTSP_PORT"
    else
      echo "[!] WARNING: Unable to connect to $RTSP_HOST:$RTSP_PORT."
      echo "    Ensure Box A has port $RTSP_PORT open in AWS Security Groups."
      echo "    The benchmark will continue and auto-reconnect as soon as the feed comes online."
    fi
  fi
fi

echo "[*] Launching Rust Iced CPU application (tiny-skia backend)..."

# On Linux, run inside Xvfb with pure software rendering flags
if [[ "$OSTYPE" == "linux"* ]]; then
  export LIBGL_ALWAYS_SOFTWARE=1
  xvfb-run -a -s "-screen 0 2560x1440x24" "$BINARY_PATH" &
  APP_PID=$!
else
  "$BINARY_PATH" &
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
