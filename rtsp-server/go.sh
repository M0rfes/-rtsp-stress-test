#!/usr/bin/env bash
# go.sh - Start the shared 6-hour clock (Phase 1 3h + Phase 2 3h).
# Call this ONCE after all 10 clients are already connected.
set -euo pipefail

GO_FILE="${GO_FILE:-/opt/rtsp-server/GO}"

if [ -f "$GO_FILE" ]; then
  echo "[!] $GO_FILE already exists. Clock already started at:"
  cat "$GO_FILE"
  echo "    To reset: sudo rm -f $GO_FILE && sudo systemctl restart rtsp-phase2"
  exit 1
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
install_dir="$(dirname "$GO_FILE")"
if [ -w "$install_dir" ]; then
  printf '%s\n' "$TS" >"$GO_FILE"
else
  printf '%s\n' "$TS" | sudo tee "$GO_FILE" >/dev/null
fi

echo "T0 $TS  — Phase 1 (3h) starts now. Phase 2 at T0+3h. Snapshot logs at phase2_begin."
echo "Wrote $GO_FILE"
