#!/usr/bin/env bash
# run_benchmark_headed.sh - Runs Benchmark in Headed Mode on Desktop Window Manager
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$DIR/.." && pwd)"

export RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/live}"
export STREAM_COUNT="${STREAM_COUNT:-30}"
export BENCHMARK_LOG_DIR="${BENCHMARK_LOG_DIR:-$PROJECT_ROOT/logs}"

# Raise file descriptor limits
ulimit -n 65535 2>/dev/null || ulimit -n 10240 2>/dev/null || true

mkdir -p "$BENCHMARK_LOG_DIR"

BINARY="$PROJECT_ROOT/target/release/rtsp-stress-test-iced-gpu"
if [ ! -f "$BINARY" ]; then
  echo "[*] Compiling optimized release binary..."
  cargo build --release --manifest-path "$PROJECT_ROOT/Cargo.toml"
fi

echo "=== Launching Headed Rust Iced GPU Benchmark ==="
echo "Stream Count:  $STREAM_COUNT"
echo "RTSP URL:      $RTSP_URL"
echo "Log Directory: $BENCHMARK_LOG_DIR"

# Launch binary directly on native desktop display
"$BINARY" &
BENCH_PID=$!

echo "[*] Benchmark running under PID $BENCH_PID"

# Start background OS hardware polling
"$DIR/poll_hardware.sh" "$BENCH_PID" &
POLL_PID=$!

trap "kill $BENCH_PID $POLL_PID 2>/dev/null || true; exit" SIGINT SIGTERM EXIT

wait "$BENCH_PID"
