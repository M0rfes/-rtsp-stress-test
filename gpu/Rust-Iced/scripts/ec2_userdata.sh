#!/usr/bin/env bash
# ec2_userdata.sh - Provision AWS EC2 Ubuntu instance for Rust Iced GPU (Zero-Copy) Benchmark
set -e

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt repositories..."
apt-get update -y
apt-get install -y \
  build-essential \
  curl \
  wget \
  git \
  pkg-config \
  libglib2.0-dev \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libgstreamer-gl1.0-0 \
  gstreamer1.0-gl \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly \
  gstreamer1.0-libav \
  gstreamer1.0-vaapi \
  gstreamer1.0-tools \
  libva-dev \
  libva2 \
  libva-drm2 \
  libegl1-mesa-dev \
  libgles2-mesa-dev \
  libgl1-mesa-dev \
  libvulkan-dev \
  vulkan-tools \
  libx11-dev \
  libxcursor-dev \
  libxrandr-dev \
  libxi-dev \
  libxkbcommon-dev \
  libwayland-dev \
  xvfb \
  ffmpeg \
  netcat-openbsd

# Ensure NVIDIA driver and CUDA tools are present
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[*] Installing NVIDIA headless driver..."
  apt-get install -y nvidia-headless-535 nvidia-utils-535 libnvidia-encode-535 || true
fi

# Install Rust toolchain
echo "[*] Installing Rust..."
if ! command -v rustc >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi

# Ensure benchmark log directory exists and has open permissions
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

echo "[*] EC2 Environment provisioned successfully for Rust Iced GPU Benchmark."
