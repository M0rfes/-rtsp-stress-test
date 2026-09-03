#!/usr/bin/env bash
# ec2_userdata.sh - Cloud-Init User Data Script for AWS EC2 Ubuntu (GPU Zero-Copy Benchmark)
# Recommended Instance: g6.xlarge, g6.8xlarge, g5.xlarge, or g4dn.xlarge
# Paste this script into AWS EC2 Launch Instance -> Advanced Details -> User Data
set -ex

LOG_FILE="/var/log/ec2-userdata-rtsp-gpu.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== [$(date)] Initializing RTSP GPU Zero-Copy Benchmark Automated Launch ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# 1. Ensure NVIDIA drivers and utilities are present
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[*] Installing NVIDIA driver..."
  apt-get install -y linux-headers-$(uname -r)
  apt-get install -y nvidia-driver-535 nvidia-utils-535
fi

# 2. Install VA-API, EGL, and graphics dependencies
apt-get install -y libva2 libva-drm2 mesa-va-drivers vainfo libegl1-mesa libgl1-mesa-dri libdrm2

# 3. Install Node.js 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# 4. Install multimedia, Xvfb headless display, and utilities
apt-get install -y ffmpeg xvfb git curl wget netcat-openbsd htop jq libnss3 libatk-bridge2.0-0 libxkbcommon0 libgbm1 libasound2

# 5. Install MediaMTX (RTSP streaming server)
MEDIAMTX_VERSION="v1.9.0"
wget -q "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_amd64.tar.gz" -O /tmp/mediamtx.tar.gz
tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin mediamtx
chmod +x /usr/local/bin/mediamtx
rm -f /tmp/mediamtx.tar.gz

# 6. Prepare benchmark logging directory
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

# 7. Setup benchmark code in /opt/rtsp-stress-test
REPO_DIR="/opt/rtsp-stress-test"
APP_DIR="$REPO_DIR/gpu/Electron"

if [ ! -d "$REPO_DIR" ]; then
  echo "[*] Cloning benchmark repository..."
  if [ -n "$BENCHMARK_GIT_REPO" ]; then
    git clone "$BENCHMARK_GIT_REPO" "$REPO_DIR"
  else
    mkdir -p "$REPO_DIR"
  fi
fi

chown -R ubuntu:ubuntu "$REPO_DIR" || true

if [ -d "$APP_DIR" ]; then
  cd "$APP_DIR"
  
  echo "[*] Installing npm dependencies..."
  sudo -u ubuntu npm install
  
  echo "[*] Building application..."
  sudo -u ubuntu npm run build

  chmod +x "$APP_DIR"/scripts/*.sh

  # 8. Configure systemd service
  echo "[*] Installing systemd autostart service for GPU benchmark..."
  cp "$APP_DIR/scripts/rtsp-benchmark-gpu.service" /etc/systemd/system/rtsp-benchmark-gpu.service
  
  systemctl daemon-reload
  systemctl enable rtsp-benchmark-gpu.service
  systemctl restart rtsp-benchmark-gpu.service
  
  echo "=== [$(date)] GPU Benchmark started successfully via systemd! ==="
else
  echo "[!] Code directory $APP_DIR not found yet. Populate $REPO_DIR and run $APP_DIR/scripts/setup_autostart.sh"
fi
