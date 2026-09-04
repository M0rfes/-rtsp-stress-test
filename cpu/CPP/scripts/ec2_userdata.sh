#!/usr/bin/env bash
# ec2_userdata.sh - Provision AWS EC2 Ubuntu instance for C++ Qt6 CPU Benchmark
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
  libavcodec-dev \
  libavformat-dev \
  libswscale-dev \
  libavutil-dev \
  ffmpeg \
  xvfb \
  netcat-openbsd

# Ensure benchmark log directory exists and has open permissions
mkdir -p /var/log/benchmark
chmod 777 /var/log/benchmark

echo "[*] EC2 Environment provisioned successfully for C++ Qt6 CPU Benchmark."
