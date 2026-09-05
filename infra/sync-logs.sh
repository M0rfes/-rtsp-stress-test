#!/usr/bin/env bash
# sync-logs.sh — copy benchmark logs (and server journals) to S3.
# Usage: sync-logs.sh [live|phase1|final]
set -euo pipefail

ENV_FILE="/etc/rtsp-benchmark.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$ENV_FILE"
  set +a
fi

PHASE="${1:-live}"
BUCKET="${BENCHMARK_S3_BUCKET:?BENCHMARK_S3_BUCKET is required}"
RUN_ID="${BENCHMARK_RUN_ID:?BENCHMARK_RUN_ID is required}"
FRAMEWORK="${BENCHMARK_FRAMEWORK:-server}"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-2}"
LOG_DIR="${BENCHMARK_LOG_DIR:-/var/log/benchmark}"

export AWS_DEFAULT_REGION="$REGION"

mkdir -p "$LOG_DIR"

if [[ "${BENCHMARK_ROLE:-}" == "server" ]]; then
  journalctl -u rtsp-feed-server -u rtsp-phase2 --no-pager >"$LOG_DIR/server-journal.log" 2>/dev/null || true
  hostname -I >"$LOG_DIR/server-private-ip.txt" 2>/dev/null || true
fi

DEST="s3://${BUCKET}/runs/${RUN_ID}/${FRAMEWORK}/${PHASE}/"
echo "[*] Syncing ${LOG_DIR} -> ${DEST}"
aws s3 sync "$LOG_DIR" "$DEST" --sse AES256 --only-show-errors
echo "[✓] Sync complete (${PHASE})"
