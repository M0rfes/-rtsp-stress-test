#!/usr/bin/env bash
# run_benchmark_headless.sh - 24-Hour Benchmark Runner for Headless Linux (AWS Ubuntu)
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

LOG_DIR="${BENCHMARK_LOG_DIR:-/var/log/benchmark}"
sudo mkdir -p "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR"
sudo chmod 777 "$LOG_DIR" 2>/dev/null || true

echo "=== RTSP 30-Stream CPU Benchmark (Electron) ==="
echo "Working directory: $DIR"
echo "Log directory:     $LOG_DIR"
echo "Active streams:    ${STREAM_COUNT:-30}"
echo "RTSP URL:          ${RTSP_URL:-rtsp://127.0.0.1:8554/live}"

# Check for xvfb
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "[!] xvfb-run not found. On Ubuntu run: sudo apt update && sudo apt install -y xvfb"
  exit 1
fi

# Build project if dist does not exist
if [ ! -d "$DIR/dist" ]; then
  echo "[*] Building application..."
  npm run build
fi

echo "[*] Launching Electron inside Xvfb (Virtual Screen: 2560x1440x24)..."

# Launch Electron with software decode inside Xvfb
xvfb-run -a -s "-screen 0 2560x1440x24" npx electron . &
APP_PID=$!

echo "[*] Benchmark application running with PID: $APP_PID"

# Start external hardware polling script in background
echo "[*] Starting external hardware polling..."
"$DIR/scripts/poll_hardware.sh" "$APP_PID" &
POLL_PID=$!

trap "echo '[*] Stopping benchmark...'; kill $APP_PID $POLL_PID 2>/dev/null || true; exit" SIGINT SIGTERM

echo "[*] 24-Hour Benchmark is now actively running."
echo "[*] Monitor FPS metrics:      tail -f $LOG_DIR/fps_metrics.log"
echo "[*] Monitor Hardware metrics: tail -f $LOG_DIR/hardware_metrics.csv"

wait $APP_PID
