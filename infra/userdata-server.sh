#!/usr/bin/env bash
# userdata-server.sh — provision the shared RTSP server and 5-minute S3 log sync.
# Expected env (written by deploy.sh cloud-init preamble):
#   AWS_DEFAULT_REGION, BENCHMARK_S3_BUCKET, BENCHMARK_RUN_ID, BENCHMARK_ROLE=server
set -euo pipefail

STATE_DIR="/var/lib/rtsp-benchmark"
LOG_DIR="/var/log/benchmark"
REPO_DIR="/opt/rtsp-stress-test"
ENV_FILE="/etc/rtsp-benchmark.env"
SYNC_SCRIPT="${REPO_DIR}/infra/sync-logs.sh"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-2}"
BUCKET="${BENCHMARK_S3_BUCKET:?}"
RUN_ID="${BENCHMARK_RUN_ID:?}"

mkdir -p "$STATE_DIR" "$LOG_DIR"
chmod 777 "$LOG_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y awscli unzip jq python3 ffmpeg curl wget ca-certificates || true
if ! command -v aws >/dev/null 2>&1; then
  snap install aws-cli --classic || true
fi

if [[ ! -d "${REPO_DIR}/rtsp-server" ]]; then
  echo "[!] ${REPO_DIR}/rtsp-server missing. Cloud-init must extract the source tarball first."
  exit 1
fi

chmod +x "${REPO_DIR}/infra/"*.sh "${REPO_DIR}/rtsp-server/"*.sh

cat >"$ENV_FILE" <<EOF
AWS_DEFAULT_REGION=${REGION}
BENCHMARK_S3_BUCKET=${BUCKET}
BENCHMARK_RUN_ID=${RUN_ID}
BENCHMARK_ROLE=server
BENCHMARK_FRAMEWORK=server
BENCHMARK_LOG_DIR=${LOG_DIR}
EOF
chmod 0644 "$ENV_FILE"

bash "${REPO_DIR}/rtsp-server/setup.sh"

cat >/etc/systemd/system/rtsp-log-sync.service <<EOF
[Unit]
Description=Sync RTSP benchmark logs to S3
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=${SYNC_SCRIPT} live
EOF

cat >/etc/systemd/system/rtsp-log-sync.timer <<'EOF'
[Unit]
Description=Sync RTSP benchmark logs to S3 every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now rtsp-log-sync.timer
systemctl start rtsp-log-sync.service || true

echo "server ready" >"${STATE_DIR}/ready"
chmod 0644 "${STATE_DIR}/ready"
echo "[✓] RTSP server provisioned. Clock not started. Run: sudo /opt/rtsp-server/go.sh"
