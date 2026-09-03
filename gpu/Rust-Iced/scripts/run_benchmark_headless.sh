#!/usr/bin/env bash
# run_benchmark_headless.sh - Runs 24-Hour Benchmark Headless via Xvfb on AWS EC2
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$DIR/.." && pwd)"

export RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/live}"
export STREAM_COUNT="${STREAM_COUNT:-30}"
export BENCHMARK_LOG_DIR="${BENCHMARK_LOG_DIR:-/var/log/benchmark}"
export H264_DECODER="${H264_DECODER:-nvdec}"
export WGPU_BACKEND="${WGPU_BACKEND:-gl}"
export LIBVA_DRIVER_NAME=nvidia
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export GST_VAAPI_ALL_DRIVERS=1

# Raise file descriptor limits
ulimit -n 65535 2>/dev/null || ulimit -n 10240 2>/dev/null || true

# Ensure output directory exists or fallback to ./logs
if ! mkdir -p "$BENCHMARK_LOG_DIR" 2>/dev/null || [ ! -w "$BENCHMARK_LOG_DIR" ]; then
  echo "[WARN] $BENCHMARK_LOG_DIR is not writable. Falling back to $PROJECT_ROOT/logs"
  export BENCHMARK_LOG_DIR="$PROJECT_ROOT/logs"
  mkdir -p "$BENCHMARK_LOG_DIR"
fi

BINARY="$PROJECT_ROOT/target/release/rtsp-stress-test-iced-gpu"
if [ ! -f "$BINARY" ]; then
  echo "[*] Compiling optimized release binary..."
  cargo build --release --manifest-path "$PROJECT_ROOT/Cargo.toml"
fi

echo "=== Launching Headless 24-Hour Rust Iced GPU Benchmark ==="
echo "Stream Count:       $STREAM_COUNT"
echo "RTSP URL:           $RTSP_URL"
echo "Hardware Decoder:   $H264_DECODER"
echo "WGPU Backend:       $WGPU_BACKEND"
echo "Log Directory:      $BENCHMARK_LOG_DIR"

# Launch headless via Xvfb with matching 2560x1440 resolution
xvfb-run -a -s "-screen 0 2560x1440x24" "$BINARY" &
BENCH_PID=$!

echo "[*] Benchmark running under PID $BENCH_PID"

# Start background OS hardware polling
"$DIR/poll_hardware.sh" "$BENCH_PID" &
POLL_PID=$!

trap "kill $BENCH_PID $POLL_PID 2>/dev/null || true; exit" SIGINT SIGTERM EXIT

wait "$BENCH_PID"
