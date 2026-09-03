#!/usr/bin/env bash
# poll_hardware.sh - External OS Hardware Polling for 24-Hour RTSP Video Grid Benchmark
# Polling interval: 10 seconds
# Output format: /var/log/benchmark/hardware_metrics.csv
# Columns: timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent

TARGET_PID="$1"
LOG_FILE="${HARDWARE_METRICS_LOG_PATH:-/var/log/benchmark/hardware_metrics.csv}"

# Ensure output directory exists or fallback to local ./logs
LOG_DIR=$(dirname "$LOG_FILE")
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
  LOG_DIR="./logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/hardware_metrics.csv"
fi

if [ -z "$TARGET_PID" ]; then
  # Auto-detect Rust Iced benchmark process if PID not supplied
  TARGET_PID=$(pgrep -f "rtsp-stress-test-iced-cpu" | head -n 1)
fi

if [ -z "$TARGET_PID" ]; then
  echo "Usage: $0 <PID>"
  echo "Or start the Iced app first to allow auto-detection."
  exit 1
fi

echo "Starting hardware polling for PID: $TARGET_PID"
echo "Logging every 10 seconds to: $LOG_FILE"

# Write CSV header if file doesn't exist
if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
  echo "timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent" > "$LOG_FILE"
fi

while kill -0 "$TARGET_PID" 2>/dev/null; do
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Detect OS and poll CPU % and RSS MB
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS ps
    PS_OUT=$(ps -p "$TARGET_PID" -o %cpu,rss 2>/dev/null | tail -n 1)
    CPU_PERCENT=$(echo "$PS_OUT" | awk '{print $1}')
    RSS_KB=$(echo "$PS_OUT" | awk '{print $2}')
    if [ -n "$RSS_KB" ] && [ "$RSS_KB" -gt 0 ] 2>/dev/null; then
      RAM_RSS_MB=$(awk "BEGIN {printf \"%.1f\", $RSS_KB / 1024}")
    else
      RAM_RSS_MB="0.0"
    fi
  else
    # Linux ps / top
    PS_OUT=$(ps -p "$TARGET_PID" -o %cpu,rss --no-headers 2>/dev/null)
    CPU_PERCENT=$(echo "$PS_OUT" | awk '{print $1}')
    RSS_KB=$(echo "$PS_OUT" | awk '{print $2}')
    if [ -n "$RSS_KB" ] && [ "$RSS_KB" -gt 0 ] 2>/dev/null; then
      RAM_RSS_MB=$(awk "BEGIN {printf \"%.1f\", $RSS_KB / 1024}")
    else
      RAM_RSS_MB="0.0"
    fi
  fi

  # In CPU-only benchmark, GPU metrics remain 0 or empty per specification
  GPU_VRAM_MB="0"
  GPU_DECODER_PERCENT="0"

  # Optional check if nvidia-smi exists (e.g. if running on GPU machine in CPU mode)
  if command -v nvidia-smi >/dev/null 2>&1; then
    NV_INFO=$(nvidia-smi --query-gpu=memory.used,utilization.decoder --format=csv,noheader,nounits 2>/dev/null | head -n 1)
    if [ -n "$NV_INFO" ]; then
      GPU_VRAM_MB=$(echo "$NV_INFO" | awk -F', ' '{print $1}')
      GPU_DECODER_PERCENT=$(echo "$NV_INFO" | awk -F', ' '{print $2}')
    fi
  fi

  # Append CSV row
  echo "${TIMESTAMP},${TARGET_PID},${CPU_PERCENT:-0},${RAM_RSS_MB:-0},${GPU_VRAM_MB},${GPU_DECODER_PERCENT}" >> "$LOG_FILE"

  sleep 10
done

echo "Process $TARGET_PID terminated. Hardware polling stopped."
