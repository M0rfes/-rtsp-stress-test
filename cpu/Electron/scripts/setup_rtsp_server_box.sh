#!/usr/bin/env bash
# setup_rtsp_server_box.sh - Run this on the SEPARATE RTSP Server Box in the same VPC
# Installs MediaMTX, publishes 1440p 25fps H.264 feed, and configures systemd autostart on boot
set -e

echo "=== Configuring Dedicated RTSP Server Box (AWS VPC) ==="

# 1. Install prerequisites
sudo apt-get update -y
sudo apt-get install -y ffmpeg curl wget netcat-openbsd

# 2. Install MediaMTX
MEDIAMTX_VERSION="v1.9.0"
wget -q "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_amd64.tar.gz" -O /tmp/mediamtx.tar.gz
sudo tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin mediamtx
sudo chmod +x /usr/local/bin/mediamtx
rm -f /tmp/mediamtx.tar.gz

# 3. Create MediaMTX configuration
sudo mkdir -p /etc/mediamtx
cat << 'EOF' | sudo tee /etc/mediamtx/mediamtx.yml
api: yes
protocols: [tcp]
rtspAddress: :8554
paths:
  all:
EOF

# 4. Create generator script
sudo mkdir -p /opt/rtsp-server
cat << 'EOF' | sudo tee /opt/rtsp-server/start_feed.sh
#!/usr/bin/env bash
set -e
/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml &
MTX_PID=$!
sleep 2

trap "kill $MTX_PID 2>/dev/null || true; exit" SIGINT SIGTERM EXIT

# Publish continuous 1440p 25fps H.264 test feed with keyframe every second (g=25)
ffmpeg -re -f lavfi -i "testsrc2=size=2560x1440:rate=25" \
  -c:v libx264 -preset ultrafast -tune zerolatency \
  -g 25 -pix_fmt yuv420p \
  -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
EOF
sudo chmod +x /opt/rtsp-server/start_feed.sh

# 5. Create and enable systemd service on boot
cat << 'EOF' | sudo tee /etc/systemd/system/rtsp-feed-server.service
[Unit]
Description=Dedicated MediaMTX RTSP Video Stream Publisher (1440p 25fps)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/bin/bash /opt/rtsp-server/start_feed.sh
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rtsp-feed-server.service
sudo systemctl restart rtsp-feed-server.service

sleep 2

# Detect Private VPC IP
PRIVATE_IP=$(hostname -I | awk '{print $1}')
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  AWS_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || true)
  if [ -n "$AWS_IP" ]; then
    PRIVATE_IP="$AWS_IP"
  fi
fi

echo ""
echo "========================================================================="
echo " [SUCCESS] RTSP Server Box is active and configured for autostart on boot"
echo "========================================================================="
echo " Private VPC IP: $PRIVATE_IP"
echo " RTSP Stream URL: rtsp://${PRIVATE_IP}:8554/live"
echo ""
echo " Next step on Benchmark Box (CPU or GPU):"
echo " Set in .env:"
echo " RTSP_URL=rtsp://${PRIVATE_IP}:8554/live"
echo ""
echo " Security Group Reminder:"
echo " Ensure the Security Group on this box allows TCP Port 8554 inbound from"
echo " the benchmark box or VPC subnet (e.g. 10.0.0.0/16 or 172.31.0.0/16)."
echo "========================================================================="
