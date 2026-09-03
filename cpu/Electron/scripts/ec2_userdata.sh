#!/usr/bin/env bash
# ec2_userdata.sh - Cloud-Init User Data Script for AWS EC2 Ubuntu (CPU Benchmark)
# Paste this script into AWS EC2 Launch Instance -> Advanced Details -> User Data
set -ex

LOG_FILE="/var/log/ec2-userdata-rtsp.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== [$(date)] Initializing RTSP CPU Benchmark Automated Launch ==="

# 1. Update system packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# 2. Install Node.js 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# 3. Install multimedia, Xvfb headless display, and utilities
apt-get install -y ffmpeg xvfb git curl wget netcat-openbsd htop jq libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libgbm1 libasound2

# 4. Install MediaMTX (RTSP streaming server)
MEDIAMTX_VERSION="v1.9.0"
wget -q "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_amd64.tar.gz" -O /tmp/mediamtx.tar.gz
tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin mediamtx
chmod +x /usr/local/bin/mediamtx
rm -f /tmp/mediamtx.tar.gz

# 5. Prepare benchmark logging directory
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

# 6. Setup benchmark code in /opt/rtsp-stress-test
# Replace REPO_URL below with your repository if using private/custom repo, or sync via git/tarball
REPO_DIR="/opt/rtsp-stress-test"
APP_DIR="$REPO_DIR/cpu/Electron"

if [ ! -d "$REPO_DIR" ]; then
  echo "[*] Cloning benchmark repository..."
  # If git repo is provided:
  if [ -n "$BENCHMARK_GIT_REPO" ]; then
    git clone "$BENCHMARK_GIT_REPO" "$REPO_DIR"
  else
    # Default public fallback or directory create
    mkdir -p "$REPO_DIR"
  fi
fi

# Ensure permissions
chown -R ubuntu:ubuntu "$REPO_DIR" || true

if [ -d "$APP_DIR" ]; then
  cd "$APP_DIR"
  
  echo "[*] Installing npm dependencies..."
  sudo -u ubuntu npm install
  
  echo "[*] Building application..."
  sudo -u ubuntu npm run build

  # Make scripts executable
  chmod +x "$APP_DIR"/scripts/*.sh

  # 7. Configure systemd service
  echo "[*] Installing systemd autostart service..."
  cp "$APP_DIR/scripts/rtsp-benchmark-cpu.service" /etc/systemd/system/rtsp-benchmark-cpu.service
  
  systemctl daemon-reload
  systemctl enable rtsp-benchmark-cpu.service
  systemctl restart rtsp-benchmark-cpu.service
  
  echo "=== [$(date)] Benchmark started successfully via systemd! ==="
else
  echo "[!] Code directory $APP_DIR not found yet. Populate $REPO_DIR and run $APP_DIR/scripts/setup_autostart.sh"
fi
