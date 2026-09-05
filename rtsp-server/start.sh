#!/usr/bin/env bash
# start.sh - Shared RTSP publisher for all 10 benchmark clients (300 TCP readers).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null || true

MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-v1.20.1}"
BIN_DIR="$DIR/bin"
mkdir -p "$BIN_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[!] python3 not found (needed for config + Phase 2)."
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[!] ffmpeg not found in PATH."
  echo "    macOS:  brew install ffmpeg"
  echo "    Ubuntu: sudo apt-get install -y ffmpeg"
  exit 1
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *)
    echo "[!] Unsupported CPU architecture: $arch"
    exit 1
    ;;
esac

case "$os" in
  darwin) mtx_os="darwin" ;;
  linux) mtx_os="linux" ;;
  mingw*|msys*|cygwin*) mtx_os="windows" ;;
  *)
    echo "[!] Unsupported OS: $os"
    exit 1
    ;;
esac

MEDIAMTX_BIN="$BIN_DIR/mediamtx"
if [ "$mtx_os" = "windows" ]; then
  MEDIAMTX_BIN="$BIN_DIR/mediamtx.exe"
fi

if [ ! -x "$MEDIAMTX_BIN" ]; then
  asset="mediamtx_${MEDIAMTX_VERSION}_${mtx_os}_${arch}.tar.gz"
  if [ "$mtx_os" = "windows" ]; then
    asset="mediamtx_${MEDIAMTX_VERSION}_windows_amd64.zip"
  fi
  url="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/${asset}"
  echo "[*] Downloading MediaMTX ${MEDIAMTX_VERSION} ($asset)..."
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/$asset"
  if [ "$mtx_os" = "windows" ]; then
    unzip -o "$tmp/$asset" mediamtx.exe -d "$BIN_DIR" >/dev/null
  else
    tar -xzf "$tmp/$asset" -C "$BIN_DIR" mediamtx
  fi
  chmod +x "$MEDIAMTX_BIN"
  rm -rf "$tmp"
fi

PRIVATE_IP="$( { hostname -I 2>/dev/null || true; } | awk '{print $1}' )"
TOKEN="$(curl -s --max-time 1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
if [ -n "$TOKEN" ]; then
  AWS_IP="$(curl -s --max-time 1 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
  if [ -n "$AWS_IP" ]; then
    PRIVATE_IP="$AWS_IP"
  fi
fi
PRIVATE_IP="${PRIVATE_IP:-127.0.0.1}"

RUNTIME_YML="$DIR/mediamtx.runtime.yml"
python3 "$DIR/generate_mediamtx.py" > "$RUNTIME_YML"

echo "=== Shared RTSP server (AWS VPC private IP) ==="
echo "  Pattern: rtsp://${PRIVATE_IP}:8554/cam%d   (stream i = camera i)"
echo "  Origin:  rtsp://${PRIVATE_IP}:8554/origin"
echo "  Readers: 10 clients × 30 cameras = 300 TCP connections (same VPC)"
echo "  Phase 2: python3 $DIR/phase2.py  (auto at +3h via systemd)"
echo "  API:     http://127.0.0.1:9997/v3/paths/list"
echo "  Config:  $RUNTIME_YML"
echo ""

exec "$MEDIAMTX_BIN" "$RUNTIME_YML"
