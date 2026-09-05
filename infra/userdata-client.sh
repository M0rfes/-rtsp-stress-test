#!/usr/bin/env bash
# userdata-client.sh — provision one benchmark client, wait for RTSP, start the UI.
# Expected env (written by deploy.sh cloud-init preamble):
#   AWS_DEFAULT_REGION, BENCHMARK_S3_BUCKET, BENCHMARK_RUN_ID, BENCHMARK_ROLE=client
#   BENCHMARK_FRAMEWORK, BENCHMARK_FRAMEWORK_DIR, RTSP_SERVER_IP, MACHINE_ID
set -euo pipefail

STATE_DIR="/var/lib/rtsp-benchmark"
LOG_DIR="/var/log/benchmark"
REPO_DIR="/opt/rtsp-stress-test"
ENV_FILE="/etc/rtsp-benchmark.env"
SYNC_SCRIPT="${REPO_DIR}/infra/sync-logs.sh"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-2}"
BUCKET="${BENCHMARK_S3_BUCKET:?}"
RUN_ID="${BENCHMARK_RUN_ID:?}"
FRAMEWORK="${BENCHMARK_FRAMEWORK:?}"
FRAMEWORK_DIR="${BENCHMARK_FRAMEWORK_DIR:?}"
RTSP_SERVER_IP="${RTSP_SERVER_IP:?}"
MACHINE_ID="${MACHINE_ID:-${FRAMEWORK}}"
APP_DIR="${REPO_DIR}/${FRAMEWORK_DIR}"
RTSP_URL_PATTERN="rtsp://${RTSP_SERVER_IP}:8554/cam%d"
RTSP_URL="rtsp://${RTSP_SERVER_IP}:8554/cam0"
RTSP_WAIT_SECONDS=1800
HARDWARE_MODE="cpu"
if [[ "$FRAMEWORK" == gpu-* ]]; then
  HARDWARE_MODE="gpu"
fi

mkdir -p "$STATE_DIR" "$LOG_DIR"
chmod 777 "$LOG_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y awscli unzip jq curl wget ca-certificates netcat-openbsd || true
if ! command -v aws >/dev/null 2>&1; then
  snap install aws-cli --classic || true
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "[!] App dir missing: $APP_DIR"
  exit 1
fi

chmod +x "${REPO_DIR}/infra/"*.sh
chmod +x "${APP_DIR}/scripts/"*.sh || true

if [[ "${CPU_BASELINE:-}" == "1" ]]; then
  for d in "cpu/C#" "cpu/CPP" "cpu/Rust-Iced" "cpu/Rust-Tauri"; do
    if [[ -x "${REPO_DIR}/${d}/scripts/ec2_userdata.sh" ]]; then
      bash "${REPO_DIR}/${d}/scripts/ec2_userdata.sh"
    fi
  done
  if [[ -d "${REPO_DIR}/cpu/Electron" ]]; then
    apt-get install -y ffmpeg xvfb git curl wget netcat-openbsd libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libgbm1 libasound2t64 || apt-get install -y libasound2 || true
    sudo -u ubuntu bash -lc "cd '${REPO_DIR}/cpu/Electron' && npm install && npm run build"
  fi
  sudo -u ubuntu bash -lc 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
elif [[ -x "${APP_DIR}/scripts/ec2_userdata.sh" ]]; then
  bash "${APP_DIR}/scripts/ec2_userdata.sh"
fi

# Existing Electron userdata may have started a localhost-targeted unit. Stop it.
systemctl stop 'rtsp-benchmark-*' 2>/dev/null || true
systemctl disable 'rtsp-benchmark-*' 2>/dev/null || true

if [[ "$FRAMEWORK_DIR" == *Rust* ]]; then
  if [[ ! -x /home/ubuntu/.cargo/bin/rustc ]]; then
    sudo -u ubuntu bash -lc 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
  fi
fi

chown -R ubuntu:ubuntu "$REPO_DIR" || true

cat >"$ENV_FILE" <<EOF
AWS_DEFAULT_REGION=${REGION}
BENCHMARK_S3_BUCKET=${BUCKET}
BENCHMARK_RUN_ID=${RUN_ID}
BENCHMARK_ROLE=client
BENCHMARK_FRAMEWORK=${FRAMEWORK}
BENCHMARK_FRAMEWORK_DIR=${FRAMEWORK_DIR}
BENCHMARK_LOG_DIR=${LOG_DIR}
RTSP_SERVER_IP=${RTSP_SERVER_IP}
RTSP_URL_PATTERN=${RTSP_URL_PATTERN}
RTSP_URL=${RTSP_URL}
STREAM_COUNT=${STREAM_COUNT:-30}
MACHINE_ID=${MACHINE_ID}
HARDWARE_MODE=${HARDWARE_MODE}
CPU_BASELINE=${CPU_BASELINE:-}
RTSP_SERVER_INSTANCE_ID=${RTSP_SERVER_INSTANCE_ID:-}
PATH=/home/ubuntu/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
chmod 0644 "$ENV_FILE"

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

cat >/etc/systemd/system/rtsp-benchmark-client.service <<EOF
[Unit]
Description=RTSP benchmark client (${FRAMEWORK})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/scripts/run_benchmark_headless.sh
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=20
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

if [[ "${CPU_BASELINE:-}" == "1" ]]; then
  cat >/etc/systemd/system/rtsp-cpu-baseline.service <<EOF
[Unit]
Description=RTSP CPU baseline sequence (5 frameworks x 6h)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${ENV_FILE}
ExecStart=${REPO_DIR}/infra/run-cpu-baseline-sequence.sh
Restart=on-failure
RestartSec=30
TimeoutStartSec=0
KillMode=mixed
TimeoutStopSec=30
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now rtsp-log-sync.timer

echo "provisioned" >"${STATE_DIR}/provisioned"

echo "[*] Waiting up to ${RTSP_WAIT_SECONDS}s for RTSP at ${RTSP_SERVER_IP}:8554"
elapsed=0
while ! nc -z -w 3 "$RTSP_SERVER_IP" 8554 2>/dev/null; do
  if (( elapsed >= RTSP_WAIT_SECONDS )); then
    echo "[!] RTSP server not reachable"
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

if [[ "${CPU_BASELINE:-}" == "1" ]]; then
  chmod +x "${REPO_DIR}/infra/run-cpu-baseline-sequence.sh"
  systemctl enable --now rtsp-cpu-baseline.service
  echo "[*] CPU baseline sequence started (ready after first fps_metrics.log)"
else
  systemctl enable --now rtsp-benchmark-client.service
  echo "running" >"${STATE_DIR}/ready"
  chmod 0644 "${STATE_DIR}/ready"
  echo "[✓] Client ${FRAMEWORK} started against ${RTSP_URL_PATTERN}"
fi
