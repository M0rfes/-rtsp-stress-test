#!/usr/bin/env bash
# reset-clock.sh — clear GO and start a fresh phase1+phase2 clock.
# CPU baseline uses 1h+1h. Official 6h runs call go.sh only and keep 3h+3h from the unit file.
set -euo pipefail

GO_FILE="${GO_FILE:-/opt/rtsp-server/GO}"
PHASE1_SECONDS="${PHASE1_SECONDS:-3600}"
PHASE2_SECONDS="${PHASE2_SECONDS:-3600}"

install -d -m 0755 /etc/systemd/system/rtsp-phase2.service.d
cat >/etc/systemd/system/rtsp-phase2.service.d/duration.conf <<EOF
[Service]
Environment=PHASE1_SECONDS=${PHASE1_SECONDS}
Environment=PHASE2_SECONDS=${PHASE2_SECONDS}
EOF
systemctl daemon-reload

rm -f "$GO_FILE"
systemctl restart rtsp-phase2
sleep 2
exec /opt/rtsp-server/go.sh
