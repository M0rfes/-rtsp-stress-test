#!/usr/bin/env bash
# ec2_userdata.sh - Provision AWS EC2 Ubuntu instance for C++ Qt6 GPU Benchmark
set -e

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt repositories..."
apt-get update -y
apt-get install -y \
  build-essential \
  cmake \
  pkg-config \
  curl \
  wget \
  git \
  qt6-base-dev \
  libqt6opengl6-dev \
  libavcodec-dev \
  libavformat-dev \
  libswscale-dev \
  libavutil-dev \
  libva-dev \
  libva-drm2 \
  vainfo \
  libegl1-mesa-dev \
  libgl1-mesa-dev \
  ffmpeg \
  xvfb \
  netcat-openbsd

# Check if NVIDIA GPU is present and install driver if not present
if lspci | grep -i nvidia >/dev/null 2>&1; then
  echo "[*] NVIDIA hardware detected. Verifying drivers..."
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "[*] Installing NVIDIA driver and CUDA toolkit..."
    apt-get install -y nvidia-driver-535 nvidia-utils-535 nvidia-cuda-toolkit || true
  fi
fi

# Ensure benchmark log directory exists and has open permissions
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

echo "[*] EC2 Environment provisioned successfully for C++ Qt6 GPU Benchmark."
