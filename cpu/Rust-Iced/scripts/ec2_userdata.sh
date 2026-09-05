#!/usr/bin/env bash
# ec2_userdata.sh - Provision AWS EC2 Ubuntu instance for Rust Iced CPU Benchmark
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
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly \
  gstreamer1.0-libav \
  gstreamer1.0-tools \
  libx11-dev \
  libxcursor-dev \
  libxrandr-dev \
  libxi-dev \
  libxkbcommon-dev \
  libwayland-dev \
  xvfb \
  ffmpeg \
  netcat-openbsd

# Install Rust toolchain
echo "[*] Installing Rust..."
if ! command -v rustc >/dev/null 2>&1; then
  export HOME="${HOME:-/root}"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  source "${HOME}/.cargo/env"
fi

# Ensure benchmark log directory exists and has open permissions
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

echo "[*] EC2 Environment provisioned successfully for Rust Iced CPU Benchmark."
