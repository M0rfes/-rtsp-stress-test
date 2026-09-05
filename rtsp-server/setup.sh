#!/usr/bin/env bash
# setup.sh - Install the shared RTSP server as a systemd service (Linux).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Run as root: sudo $DIR/setup.sh"
  exit 1
fi

echo "=== Installing shared RTSP server (300 TCP readers) ==="

apt-get update -y
apt-get install -y ffmpeg curl wget ca-certificates python3

install -d -m 0755 /opt/rtsp-server/bin
install -m 0755 "$DIR/start.sh" /opt/rtsp-server/start.sh
install -m 0755 "$DIR/generate_mediamtx.py" /opt/rtsp-server/generate_mediamtx.py
install -m 0755 "$DIR/phase2.py" /opt/rtsp-server/phase2.py
install -m 0755 "$DIR/go.sh" /opt/rtsp-server/go.sh
install -m 0755 "$DIR/reset-clock.sh" /opt/rtsp-server/reset-clock.sh
install -m 0644 "$DIR/rtsp-feed-server.service" /etc/systemd/system/rtsp-feed-server.service
install -m 0644 "$DIR/rtsp-phase2.service" /etc/systemd/system/rtsp-phase2.service
rm -f /opt/rtsp-server/GO

cat >/etc/sysctl.d/99-rtsp-server.conf <<'EOF'
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 1048576
EOF
sysctl --system >/dev/null

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
esac
if [ ! -x /opt/rtsp-server/bin/mediamtx ]; then
  asset="mediamtx_v1.20.1_linux_${arch}.tar.gz"
  curl -fsSL "https://github.com/bluenviron/mediamtx/releases/download/v1.20.1/${asset}" -o /tmp/mediamtx.tar.gz
  tar -xzf /tmp/mediamtx.tar.gz -C /opt/rtsp-server/bin mediamtx
  chmod +x /opt/rtsp-server/bin/mediamtx
  rm -f /tmp/mediamtx.tar.gz
fi

systemctl daemon-reload
systemctl enable rtsp-feed-server.service rtsp-phase2.service
systemctl restart rtsp-feed-server.service
sleep 2
systemctl restart rtsp-phase2.service

PRIVATE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
TOKEN="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
if [ -n "$TOKEN" ]; then
  AWS_IP="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)"
  if [ -n "$AWS_IP" ]; then
    PRIVATE_IP="$AWS_IP"
  fi
fi

echo ""
echo "========================================================================="
echo " Shared RTSP feed is running. The 6-hour clock has NOT started."
echo "   systemd: rtsp-feed-server (encoding) + rtsp-phase2 (waiting for GO)"
echo " Pattern:  rtsp://${PRIVATE_IP}:8554/cam%d"
echo ""
echo " After all 10 clients are built and started together:"
echo "   sudo /opt/rtsp-server/go.sh"
echo " That writes /opt/rtsp-server/GO and starts the shared 3h+3h clock."
echo ""
echo " Security group: inbound TCP 8554 from the VPC CIDR (or client SG)."
echo " On each of the 10 client instances:"
echo "   export RTSP_URL_PATTERN=rtsp://${PRIVATE_IP}:8554/cam%d"
echo "   export STREAM_COUNT=30"
echo "========================================================================="
