# Automated Linux Deployment & Autostart Guide (Rust Tauri GPU Zero-Copy Benchmark)

This document provides step-by-step instructions to deploy the GPU zero-copy benchmark from your macOS development machine to an AWS EC2 Ubuntu Linux instance equipped with an NVIDIA GPU, and configure it to **start automatically upon instance launch or reboot**, requiring zero manual intervention.

---

## 1. AWS EC2 GPU Instance Sizing & Configuration

1. **Recommended Instance Types:**
   - **`g6.xlarge` / `g6.8xlarge`:** NVIDIA L4 (24 GiB VRAM), PCIe Gen4, optimal for modern NVDEC hardware acceleration.
   - **`g5.xlarge` / `g5.2xlarge`:** NVIDIA A10G (24 GiB VRAM), enterprise hardware decode engine.
   - **`g4dn.xlarge` / `g4dn.2xlarge`:** NVIDIA T4 (16 GiB VRAM), budget-friendly testing profile.
2. **Operating System & AMI:**
   - **Recommended:** **Ubuntu Server 22.04 LTS** (or AWS Deep Learning Base AMI with Nvidia Drivers).
3. **Storage:** 50 GiB gp3 volume.
4. **Security Group:**
   - Inbound SSH (Port 22) from your IP.
   - Inbound RTSP (Port 8554, TCP) if feeding video across boxes.
   - Inbound WebSocket / HTTP (Port 9999, 1420) if monitoring externally.

---

## 2. Multi-Box Architecture: Separate RTSP Server Box in Same VPC

In production benchmarking, the RTSP video source runs on a **separate EC2 instance within the same AWS VPC** to isolate video encoding/streaming overhead from video decoding/rendering performance:

```
+------------------------------------+         AWS VPC (Same Subnet / AZ)
|     Box A: RTSP Server Box         |         Low-latency private network (<0.5ms)
|  (e.g., c6i.large / t3.medium)     |         Throughput: ~250-300 Mbps (30 streams)
|  Private IP: 10.0.1.50             |
|                                    |
|  - MediaMTX (:8554 TCP)            |
|  - 1440p 25fps H.264 Test Feed     |==============================================+
+------------------------------------+                                              |
                                                                                    v
+---------------------------------------------------------------------------------------+
|     Box B: GPU Benchmark Box (NVIDIA L4 / A10G / T4)                                  |
|  Private IP: 10.0.1.100                                                               |
|                                                                                       |
|  - Connects to rtsp://10.0.1.50:8554/live across private VPC network                  |
|  - Demuxes 30 streams via gstreamer-rs (AVCC alignment)                               |
|  - WebCodecs (prefer-hardware) + BitmapRenderer (transferFromImageBitmap)             |
|  - Hardware decoding via NVDEC into VRAM textures with zero CPU copies                |
|  - Systemd autostart on instance boot                                                 |
|  - Internal telemetry (/var/log/benchmark/fps_metrics.log)                            |
+---------------------------------------------------------------------------------------+
```

### Setting Up Box A (Dedicated RTSP Server Box):
1. Launch an Ubuntu 22.04 instance (e.g. `c6i.large`, `c7i.large`, or `t3.medium`) in the **same VPC and Availability Zone** as your GPU benchmark box.
2. In Box A's Security Group, allow **Inbound TCP Port 8554** from Box B's Security Group (or your VPC CIDR, e.g. `10.0.0.0/16` or `172.31.0.0/16`).
3. SSH into Box A and run the automated setup script:
   ```bash
   ./scripts/start_rtsp_feed.sh
   ```
4. Note Box A's private IP (e.g. `10.0.1.50`). The stream is now live at `rtsp://<BOX_A_PRIVATE_IP>:8554/live`.

---

## 3. Configuring Box B (The GPU Benchmark Box)

On Box B, configure `.env` in `gpu/Rust-Tauri/.env` to point to Box A's private IP:
```bash
RTSP_URL=rtsp://<BOX_A_PRIVATE_IP>:8554/live
STREAM_COUNT=30
MACHINE_ID=g6-xlarge-node-1
BENCHMARK_LOG_DIR=/var/log/benchmark
```

Test network reachability from Box B to Box A:
```bash
nc -zv <BOX_A_PRIVATE_IP> 8554
# Expected: Connection to <BOX_A_PRIVATE_IP> port 8554 [tcp/*] succeeded!
```

---

## 4. Zero-Touch Automatic Launch (Option A: AWS User Data)

When launching an EC2 instance in the AWS Management Console, you can have the GPU benchmark configure and launch automatically upon the first boot:

1. Open AWS EC2 Console -> **Launch Instance**.
2. Select **Ubuntu Server 22.04 LTS**.
3. Choose a GPU instance type (e.g. `g6.xlarge` or `g4dn.xlarge`).
4. Scroll down and expand **Advanced details**.
5. In the **User data** field, paste the contents of [`scripts/ec2_userdata.sh`](file:///Users/morfes/projects/rtsp-stress-test/gpu/Rust-Tauri/scripts/ec2_userdata.sh).
6. *(Optional)* Set your git repository URL at the top:
   ```bash
   export BENCHMARK_GIT_REPO="https://github.com/your-org/rtsp-stress-test.git"
   ```
7. Click **Launch Instance**.
8. **Result:** The instance boots, installs Nvidia drivers, VA-API libraries, Rust, GStreamer, WebKitGTK, Node.js, Xvfb, builds the application, configures the systemd service, and launches the GPU benchmark automatically.

---

## 5. Transferring Code from macOS (Option B: Rsync / Tarball)

If you are launching an instance without User Data, or deploying your local macOS workspace directly:

### Option B1: Direct Rsync from macOS
Run this command from your macOS terminal inside the project root:

```bash
EC2_IP="<YOUR_EC2_PUBLIC_IP>"
KEY_PATH="~/.ssh/your-aws-key.pem"

ssh -i "$KEY_PATH" ubuntu@"$EC2_IP" "sudo mkdir -p /opt/rtsp-stress-test && sudo chown -R ubuntu:ubuntu /opt/rtsp-stress-test"

rsync -avz -e "ssh -i $KEY_PATH" \
  --exclude 'target' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude 'logs' \
  --exclude '.git' \
  ./ ubuntu@"$EC2_IP":/opt/rtsp-stress-test/
```

### Option B2: Tarball Archive
From your macOS terminal:
```bash
tar --exclude='target' --exclude='node_modules' --exclude='dist' --exclude='logs' --exclude='.git' -czvf rtsp-stress-test.tar.gz ./
scp -i "$KEY_PATH" rtsp-stress-test.tar.gz ubuntu@"$EC2_IP":/tmp/

ssh -i "$KEY_PATH" ubuntu@"$EC2_IP" << 'EOF'
  sudo mkdir -p /opt/rtsp-stress-test
  sudo chown -R ubuntu:ubuntu /opt/rtsp-stress-test
  tar -xzf /tmp/rtsp-stress-test.tar.gz -C /opt/rtsp-stress-test/
  rm /tmp/rtsp-stress-test.tar.gz
EOF
```

---

## 6. One-Command Autostart Setup on the Machine

Once the code is on the EC2 machine (in `/opt/rtsp-stress-test/gpu/Rust-Tauri`), SSH into the instance:

```bash
ssh -i "$KEY_PATH" ubuntu@"$EC2_IP"
```

### Step 6.1: Verify NVIDIA Driver & Install System Dependencies
Verify that the Nvidia driver is active:
```bash
nvidia-smi
```

Install Rust, GStreamer 1.0, WebKit2GTK, VA-API, Xvfb, and Node.js:
```bash
sudo apt update && sudo apt install -y \
  build-essential pkg-config libssl-dev curl wget git jq htop netcat-openbsd \
  libglib2.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-tools \
  libgstrtspserver-1.0-dev \
  libgtk-3-dev libsoup2.4-dev libjavascriptcoregtk-4.0-dev libwebkit2gtk-4.0-dev \
  libva2 libva-drm2 mesa-va-drivers vainfo libegl1-mesa libgl1-mesa-dri \
  xvfb ffmpeg

# Install Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Install Node.js 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs
```

### Step 6.2: Build the Application
```bash
cd /opt/rtsp-stress-test/gpu/Rust-Tauri
npm install
npm run build:frontend
cargo build --release --manifest-path src-tauri/Cargo.toml
```

### Step 6.3: Configure Autostart via Systemd
Run the automated autostart installer:
```bash
./scripts/setup_autostart.sh
```

This script automatically:
1. Creates `/var/log/benchmark` with full read/write permissions.
2. Installs `/etc/systemd/system/rtsp-benchmark-tauri-gpu.service`.
3. Enables the service so it **starts automatically on every system boot / reboot**.
4. Starts the service immediately.

---

## 7. Customizing Configuration via Environment Variables

To adjust stream counts or point to remote RTSP camera feeds, edit `/opt/rtsp-stress-test/gpu/Rust-Tauri/.env`:

```bash
# Number of concurrent streams (default 30)
STREAM_COUNT=30

# RTSP Stream Source (Separate Box in VPC or local):
RTSP_URL=rtsp://10.0.1.50:8554/live

# Identifier for telemetry metrics
MACHINE_ID=g6-xlarge-node-1

# Telemetry log directory
BENCHMARK_LOG_DIR=/var/log/benchmark
```

After modifying `.env`, restart the service:
```bash
sudo systemctl restart rtsp-benchmark-tauri-gpu.service
```

---

## 8. Verifying Autostart on Reboot

To prove that the GPU benchmark starts automatically without human intervention, reboot the instance:

```bash
sudo reboot
```

Wait 30–45 seconds, SSH back into the machine, and verify:
```bash
sudo systemctl status rtsp-benchmark-tauri-gpu.service
nvidia-smi
tail -f /var/log/benchmark/fps_metrics.log
```
The service will be active, Xvfb will be running, and NVDEC will be actively hardware-decoding all 30 streams in VRAM.
