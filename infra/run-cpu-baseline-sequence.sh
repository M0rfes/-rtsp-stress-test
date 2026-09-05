#!/usr/bin/env bash
# run-cpu-baseline-sequence.sh — 5 CPU frameworks × 6h on one c7i.4xlarge.
# Resets the RTSP server clock at the start of each framework.
set -euo pipefail

ENV_FILE="/etc/rtsp-benchmark.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
fi

REPO_DIR="/opt/rtsp-stress-test"
LOG_DIR="${BENCHMARK_LOG_DIR:-/var/log/benchmark}"
STATE_DIR="/var/lib/rtsp-benchmark"
SYNC_SCRIPT="${REPO_DIR}/infra/sync-logs.sh"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-2}"
SERVER_ID="${RTSP_SERVER_INSTANCE_ID:?RTSP_SERVER_INSTANCE_ID is required}"
RUN_HOURS="${CPU_BASELINE_HOURS:-2}"
RUN_SECONDS=$((RUN_HOURS * 3600))
PATH="/home/ubuntu/.cargo/bin:/usr/share/dotnet:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH AWS_DEFAULT_REGION="$REGION"

SPECS=(
  "cpu-csharp|cpu/C#|m7i-flex-large-cpu-csharp"
  "cpu-cpp|cpu/CPP|m7i-flex-large-cpu-cpp"
  "cpu-iced|cpu/Rust-Iced|m7i-flex-large-cpu-iced"
  "cpu-tauri|cpu/Rust-Tauri|m7i-flex-large-cpu-tauri"
  "cpu-electron|cpu/Electron|m7i-flex-large-cpu-electron"
)

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 777 "$LOG_DIR"

reset_server_clock() {
  local cmd
  cmd="$(aws ssm send-command --region "$REGION" --instance-ids "$SERVER_ID" \
    --document-name AWS-RunShellScript \
    --comment "rtsp reset-clock ${BENCHMARK_FRAMEWORK:-}" \
    --parameters 'commands=["sudo /opt/rtsp-server/reset-clock.sh"]' \
    --query 'Command.CommandId' --output text)"
  echo "[*] reset-clock command ${cmd}"
  sleep 8
}

write_env() {
  local fw="$1"
  local dir="$2"
  local machine="$3"
  cat >"$ENV_FILE" <<EOF
AWS_DEFAULT_REGION=${REGION}
BENCHMARK_S3_BUCKET=${BENCHMARK_S3_BUCKET}
BENCHMARK_RUN_ID=${BENCHMARK_RUN_ID}
BENCHMARK_ROLE=client
BENCHMARK_FRAMEWORK=${fw}
BENCHMARK_FRAMEWORK_DIR=${dir}
BENCHMARK_LOG_DIR=${LOG_DIR}
RTSP_SERVER_IP=${RTSP_SERVER_IP}
RTSP_SERVER_INSTANCE_ID=${SERVER_ID}
RTSP_URL_PATTERN=rtsp://${RTSP_SERVER_IP}:8554/cam%d
RTSP_URL=rtsp://${RTSP_SERVER_IP}:8554/cam0
STREAM_COUNT=${STREAM_COUNT:-8}
MACHINE_ID=${machine}
HARDWARE_MODE=cpu
CPU_BASELINE=1
PATH=${PATH}
EOF
  chmod 0644 "$ENV_FILE"
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
}

wait_fps() {
  local i
  for i in $(seq 1 180); do
    if [[ -s "${LOG_DIR}/fps_metrics.log" ]]; then
      return 0
    fi
    sleep 10
  done
  echo "[!] fps_metrics.log not created"
  return 1
}

archive_logs() {
  local fw="$1"
  local dest="${LOG_DIR}/archive/${fw}"
  mkdir -p "$dest"
  mv -f "${LOG_DIR}/fps_metrics.log" "${dest}/fps_metrics.log" 2>/dev/null || true
  mv -f "${LOG_DIR}/hardware_metrics.csv" "${dest}/hardware_metrics.csv" 2>/dev/null || true
}

prebuild() {
  echo "[*] Prebuilding CPU frameworks"
  sudo -u ubuntu bash -lc "cd '${REPO_DIR}/cpu/C#' && dotnet publish -c Release -o bin/publish"
  sudo -u ubuntu bash -lc "cd '${REPO_DIR}/cpu/CPP' && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j\$(nproc)"
  sudo -u ubuntu bash -lc "source /home/ubuntu/.cargo/env 2>/dev/null; cd '${REPO_DIR}/cpu/Rust-Iced' && cargo build --release"
  sudo -u ubuntu bash -lc "source /home/ubuntu/.cargo/env 2>/dev/null; cd '${REPO_DIR}/cpu/Rust-Tauri' && npm install && npm run build"
  sudo -u ubuntu bash -lc "cd '${REPO_DIR}/cpu/Electron' && npm install && npm run build"
}

prebuild

for spec in "${SPECS[@]}"; do
  IFS='|' read -r fw dir machine <<<"$spec"
  echo "=== ${fw} ${machine} ==="
  write_env "$fw" "$dir" "$machine"
  rm -f "${LOG_DIR}/fps_metrics.log" "${LOG_DIR}/hardware_metrics.csv"
  touch "${LOG_DIR}/fps_metrics.log"
  chmod 666 "${LOG_DIR}/fps_metrics.log" "${LOG_DIR}/hardware_metrics.csv" 2>/dev/null || true

  sudo -u ubuntu bash -lc "set -a; source ${ENV_FILE}; set +a; cd '${REPO_DIR}/${dir}' && exec '${REPO_DIR}/${dir}/scripts/run_benchmark_headless.sh'" \
    >"${LOG_DIR}/${fw}-stdout.log" 2>&1 &
  APP_WRAP_PID=$!
  echo "$APP_WRAP_PID" >"${STATE_DIR}/current.pid"

  wait_fps
  echo "running-${fw}" >"${STATE_DIR}/ready"
  reset_server_clock
  echo "[*] ${fw} clock started; 1h phase1 then 1h phase2"
  sleep $((RUN_SECONDS / 2))
  bash "$SYNC_SCRIPT" "phase1-${fw}" || true
  sleep $((RUN_SECONDS / 2))

  kill -- -"$APP_WRAP_PID" 2>/dev/null || true
  pkill -u ubuntu -f run_benchmark_headless.sh 2>/dev/null || true
  pkill -u ubuntu -f xvfb-run 2>/dev/null || true
  sleep 5
  bash "$SYNC_SCRIPT" "final-${fw}" || true
  archive_logs "$fw"
done

echo "sequence-complete" >"${STATE_DIR}/ready"
bash "$SYNC_SCRIPT" final || true
if [[ -n "${SERVER_ID:-}" ]]; then
  aws ssm send-command --region "$REGION" --instance-ids "$SERVER_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["shutdown -h now"]' >/dev/null || true
fi
shutdown -h now
