# Automated Linux Deployment & Autostart Guide (Rust Iced CPU Benchmark)

This document provides step-by-step instructions to deploy the 30-camera RTSP CPU benchmark from your macOS development machine to an AWS EC2 Ubuntu Linux instance and configure it to **start automatically as soon as the instance launches or boots**, requiring zero manual intervention.

---

## 1. AWS EC2 Instance Sizing & Configuration

1. **Instance Type:**
   - **Full Headroom Benchmark:** `c7i.8xlarge` (32 vCPUs / 16 physical cores, 64 GiB DDR5 RAM)
   - **Bare-Minimum Simulation:** `c7i.4xlarge` (16 vCPUs / 8 physical cores, 32 GiB DDR5 RAM)
2. **Operating System:** Ubuntu 22.04 LTS or 24.04 LTS AMD64 (`ami-xxxx`)
3. **Storage:** 40 GiB gp3 root volume (ensures sufficient space for Rust compilation, GStreamer, and telemetry logs)
4. **Security Group:**
   - Inbound SSH (Port 22, TCP) from your IP
   - Inbound RTSP (Port 8554, TCP) if receiving video from a separate VPC box
   - Outbound all traffic

---

## 2. Multi-Box Architecture: Separate RTSP Server Box in Same VPC

In production benchmarking, the RTSP video source runs on a **separate EC2 instance within the same AWS VPC** to isolate video encoding and networking overhead from video decoding and rendering performance.

```
+------------------------------------+         AWS VPC (Same Subnet / AZ)
|     Box A: RTSP Server Box         |         Low-latency private network (<0.5ms)
|  (e.g., c6i.large / c7i.large)     |         Throughput: ~250-300 Mbps (30 streams)
|  Private IP: 10.0.1.50             |
|                                    |
|  - MediaMTX (:8554 TCP)            |
|  - 1440p 25fps H.264 Test Feed     |==============================================+
+------------------------------------+                                              |
                                                                                    v
+---------------------------------------------------------------------------------------+
|     Box B: Benchmark Box (Rust Iced CPU)                                              |
|  Private IP: 10.0.1.100                                                               |
|                                                                                       |
|  - Connects to rtsp://10.0.1.50:8554/live across private VPC network                  |
|  - 30 × GStreamer avdec_h264 decoders + SIMD YUV->RGBA conversion                     |
|  - Lock-free ArcSwap frame handoff                                                    |
|  - Iced tiny-skia software rendering backend under Xvfb                               |
|  - Systemd autostart on instance boot                                                 |
|  - Internal telemetry (/var/log/benchmark/fps_metrics.log)                            |
+---------------------------------------------------------------------------------------+
```

### Setting Up Box A (Dedicated RTSP Server Box):
1. Launch an Ubuntu instance (e.g. `c7i.large` or `c6i.large`) in the **same VPC and Availability Zone** as your benchmark box.
2. In Box A's Security Group, allow **Inbound TCP Port 8554** from Box B's Security Group (or your VPC CIDR, e.g. `10.0.0.0/16`).
3. SSH into Box A and start the RTSP feed:
   ```bash
   # Install MediaMTX and FFmpeg
   sudo apt update && sudo apt install -y ffmpeg wget
   wget https://github.com/bluenviron/mediamtx/releases/download/v1.9.0/mediamtx_v1.9.0_linux_amd64.tar.gz
   tar -xzf mediamtx_v1.9.0_linux_amd64.tar.gz && sudo mv mediamtx /usr/local/bin/

   # Configure mediamtx.yml with high buffer queue
   cat << 'EOF' > mediamtx.yml
   api: yes
   protocols: [tcp]
   readBufferCount: 8192
   writeQueueSize: 8192
   paths:
     all:
   EOF

   mediamtx mediamtx.yml &

   # Publish 1440p 25 FPS H.264 stream
   ffmpeg -re -f lavfi -i "testsrc2=size=2560x1440:rate=25" \
     -c:v libx264 -preset ultrafast -tune zerolatency -threads 4 \
     -g 25 -pix_fmt yuv420p \
     -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
   ```
4. Note Box A's private IP (e.g. `10.0.1.50`). The stream is now live at `rtsp://10.0.1.50:8554/live`.

---

## 3. Configuring Box B (The Benchmark Box)

On Box B, configure `.env` (or environment variables) to point to Box A's private IP:
```bash
# In /opt/rtsp-stress-test/cpu/Rust-Iced/.env:
RTSP_URL=rtsp://10.0.1.50:8554/live
STREAM_COUNT=30
MACHINE_ID=c7i-8xlarge-node-1
BENCHMARK_LOG_DIR=/var/log/benchmark
```

Test network reachability from Box B to Box A:
```bash
nc -zv 10.0.1.50 8554
# Expected: Connection to 10.0.1.50 port 8554 [tcp/*] succeeded!
```

---

## 4. Zero-Touch Automatic Launch (Option A: AWS User Data)

When launching Box B in the AWS Management Console, paste the automated user-data script to configure and launch the benchmark upon first boot:

1. Open AWS EC2 Console -> **Launch Instance**.
2. Select **Ubuntu Server 24.04 LTS** (AMD64).
3. Choose instance type `c7i.8xlarge`.
4. Scroll down and expand **Advanced details**.
5. In the **User data** field, paste the contents of [`scripts/ec2_userdata.sh`](scripts/ec2_userdata.sh).
6. Click **Launch Instance**.
7. **Result:** The instance boots, installs Rust, GStreamer, Xvfb, compiles the release binary, registers the systemd daemon, and launches the 30-stream benchmark automatically.

---

## 5. Manual Build & Deployment from macOS (Option B: Rsync)

If deploying directly from your macOS development machine to an active EC2 instance:

### Step 1: Rsync Code to EC2
```bash
# From macOS local project root:
rsync -avz --exclude 'target' --exclude 'logs' \
  -e "ssh -i ~/.ssh/your-key.pem" \
  ./cpu/Rust-Iced/ ubuntu@<EC2_PUBLIC_IP>:/opt/rtsp-stress-test/cpu/Rust-Iced/
```

### Step 2: SSH into EC2 and Run User Data Provisioning
```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<EC2_PUBLIC_IP>
cd /opt/rtsp-stress-test/cpu/Rust-Iced
sudo ./scripts/ec2_userdata.sh
source "$HOME/.cargo/env"
```

### Step 3: Compile Optimized Release Binary
```bash
cargo build --release
```
The optimized binary is compiled at:
`/opt/rtsp-stress-test/cpu/Rust-Iced/target/release/rtsp-stress-test-iced-cpu`

### Step 4: Configure and Start 24-Hour Systemd Service
```bash
sudo ./scripts/setup_autostart.sh
```
This script:
1. Customizes `rtsp-benchmark-iced-cpu.service` with the current user and directory path.
2. Creates `/var/log/benchmark/` with full write permissions.
3. Copies the service to `/etc/systemd/system/`.
4. Enables the service to start automatically on every system boot.
5. Starts the service immediately.

---

## 6. Verifying Benchmark Execution & Monitoring

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-iced-cpu --no-pager
```
*Expected Status:* `Active: active (running)`.

### B. Verify Process Hierarchy
```bash
pgrep -a rtsp-stress-test-iced-cpu
pgrep -a Xvfb
pgrep -a poll_hardware.sh
```

### C. Live Telemetry Monitoring
```bash
# 1. Rolling 60-second JSON FPS metrics:
tail -f /var/log/benchmark/fps_metrics.log

# 2. 10-second external CPU / RAM hardware metrics:
tail -f /var/log/benchmark/hardware_metrics.csv

# 3. Live systemd service output:
journalctl -u rtsp-benchmark-iced-cpu -f
```

---

## 7. Service Management Commands

```bash
# Restart benchmark
sudo systemctl restart rtsp-benchmark-iced-cpu

# Stop benchmark
sudo systemctl stop rtsp-benchmark-iced-cpu

# Disable autostart
sudo systemctl disable rtsp-benchmark-iced-cpu
```
