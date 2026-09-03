#!/usr/bin/env bash
# ec2_userdata.sh - Provision AWS EC2 Ubuntu instance for Rust Tauri GPU Zero-Copy Benchmark
# Target Instances: g6.xlarge, g6.8xlarge, g5.xlarge, g4dn.xlarge (NVIDIA GPU)
set -e

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt repositories..."
apt-get update -y

# 1. Install NVIDIA drivers and utilities if not already present
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[*] Installing NVIDIA driver..."
  apt-get install -y linux-headers-$(uname -r)
  apt-get install -y nvidia-driver-535 nvidia-utils-535
fi

# 2. Install VA-API, EGL, and graphics dependencies
apt-get install -y \
  libva2 \
  libva-drm2 \
  mesa-va-drivers \
  vainfo \
  libegl1-mesa \
  libgl1-mesa-dri \
  libdrm2

# 3. Install build tools, GStreamer (including RTSP server dev and VA-API plugins), and WebKitGTK
apt-get install -y \
  build-essential \
  curl \
  wget \
  git \
  pkg-config \
  libglib2.0-dev \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libgstrtspserver-1.0-dev \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly \
  gstreamer1.0-libav \
  gstreamer1.0-vaapi \
  gstreamer1.0-tools \
  libwebkit2gtk-4.1-dev \
  libappindicator3-dev \
  librsvg2-dev \
  patchelf \
  xvfb \
  ffmpeg \
  netcat-openbsd

# 4. Install Node.js 22 LTS
echo "[*] Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# 5. Install Rust toolchain
echo "[*] Installing Rust..."
if ! command -v rustc >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi

# 6. Install MediaMTX (for local RTSP testing if needed)
MEDIAMTX_VERSION="v1.9.0"
if ! command -v mediamtx >/dev/null 2>&1; then
  wget -q "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_amd64.tar.gz" -O /tmp/mediamtx.tar.gz
  tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin mediamtx
  chmod +x /usr/local/bin/mediamtx
  rm -f /tmp/mediamtx.tar.gz
fi

# 7. Ensure benchmark log directory exists and has open permissions
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

echo "[*] EC2 Environment provisioned successfully for Rust Tauri GPU Zero-Copy Benchmark."
