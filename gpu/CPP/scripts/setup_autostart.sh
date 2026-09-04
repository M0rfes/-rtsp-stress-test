#!/usr/bin/env bash
# setup_autostart.sh - Configures systemd autostart for RTSP C++ Qt6 GPU Benchmark on Ubuntu EC2
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_USER="$(whoami)"
SERVICE_SRC="$DIR/scripts/rtsp-benchmark-cpp-gpu.service"
SERVICE_DEST="/etc/systemd/system/rtsp-benchmark-cpp-gpu.service"

echo "=== Configuring Autostart Service for RTSP C++ Qt6 GPU Benchmark ==="
echo "Application directory: $DIR"
echo "Running user:          $CURRENT_USER"

# Create benchmark log directory
sudo mkdir -p /var/log/benchmark
sudo chmod 777 /var/log/benchmark

# Copy and customize systemd service file with current directory and user
TMP_SERVICE=$(mktemp)
sed -e "s|User=ubuntu|User=$CURRENT_USER|g" \
    -e "s|Group=ubuntu|Group=$(id -gn "$CURRENT_USER")|g" \
    -e "s|/opt/rtsp-stress-test/gpu/CPP|$DIR|g" \
    "$SERVICE_SRC" > "$TMP_SERVICE"

sudo cp "$TMP_SERVICE" "$SERVICE_DEST"
sudo chmod 644 "$SERVICE_DEST"
rm "$TMP_SERVICE"

echo "[*] Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "[*] Enabling service on system boot..."
sudo systemctl enable rtsp-benchmark-cpp-gpu.service

echo "[*] Starting service now..."
sudo systemctl restart rtsp-benchmark-cpp-gpu.service

echo "[*] Service status:"
sudo systemctl status rtsp-benchmark-cpp-gpu.service --no-pager

echo ""
echo "=== Setup Complete! ==="
echo "The benchmark is now running and will automatically start on every box reboot."
echo "View live service logs:   journalctl -u rtsp-benchmark-cpp-gpu -f"
echo "View FPS metrics:         tail -f /var/log/benchmark/fps_metrics.log"
echo "View hardware metrics:    tail -f /var/log/benchmark/hardware_metrics.csv"
