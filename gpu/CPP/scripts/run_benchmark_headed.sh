#!/usr/bin/env bash
# run_benchmark_headed.sh - Run C++ Qt6 GPU Benchmark with visible desktop window
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

BINARY_PATH="$DIR/build/rtsp-stress-test-cpp-gpu"
if [ ! -f "$BINARY_PATH" ]; then
  echo "[*] Building C++ Qt6 GPU benchmark application (Release)..."
  cmake -B build -DCMAKE_BUILD_TYPE=Release
  NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  cmake --build build -j"$NPROC"
fi

# Run application directly with display
"$BINARY_PATH" --url "$RTSP_URL" --streams "$STREAM_COUNT" --hw-accel "$HW_ACCEL" --log-dir "$LOG_DIR"
