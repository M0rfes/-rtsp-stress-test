#!/usr/bin/env bash
# ec2_userdata.sh - Provision AWS EC2 Ubuntu instance for C# Avalonia CPU Benchmark
set -e

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating apt repositories..."
apt-get update -y
apt-get install -y \
  build-essential \
  pkg-config \
  curl \
  wget \
  git \
  libavcodec-dev \
  libavformat-dev \
  libswscale-dev \
  libavutil-dev \
  ffmpeg \
  xvfb \
  libx11-dev \
  libx11-xcb-dev \
  libxi-dev \
  libice-dev \
  libsm-dev \
  netcat-openbsd

echo "[*] Installing .NET SDK..."
if ! command -v dotnet >/dev/null 2>&1; then
  curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 --install-dir /usr/share/dotnet
  ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
fi

echo "[*] Verifying .NET version: $(dotnet --version)"

# Ensure benchmark log directory exists and has open permissions
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

echo "[*] EC2 Environment provisioned successfully for C# Avalonia CPU Benchmark."
