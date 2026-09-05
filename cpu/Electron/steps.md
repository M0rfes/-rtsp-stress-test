# Automated Linux Deployment & Autostart Guide (Electron CPU Benchmark)

This document provides step-by-step instructions to transfer the benchmark from your macOS development machine to an AWS EC2 Ubuntu Linux instance and configure it to **start automatically as soon as the instance launches or boots**, requiring zero manual intervention.

---

## 1. AWS EC2 Instance Sizing & Configuration

1. **Instance Type:**
   - **Full Headroom Benchmark:** `c7i.8xlarge` (32 vCPUs / 16 physical cores, 64 GiB DDR5 RAM)
   - **Bare-Minimum Simulation:** `c7i.4xlarge` (16 vCPUs / 8 physical cores, 32 GiB DDR5 RAM)
2. **Operating System:** Ubuntu 22.04 LTS or 24.04 LTS (x86_64)
3. **Storage:** 40 GiB gp3 root volume (ensures sufficient space for logs and dependencies)
4. **Security Group:**
   - Inbound SSH (Port 22) from your IP
   - Inbound RTSP (Port 8554, TCP) if feeding video externally
   - Inbound WebSocket / HTTP (Port 9999, 8889) if monitoring externally

---

## 2. Multi-Box Architecture: Separate RTSP Server Box in Same VPC

In production benchmarking, the RTSP video source runs on a **separate EC2 instance within the same AWS VPC** to isolate video encoding/streaming overhead from video decoding/rendering performance.

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
|     Box B: Benchmark Box (Electron CPU or GPU)                                         |
|  Private IP: 10.0.1.100                                                               |
|                                                                                       |
|  - Connects to rtsp://10.0.1.50:8554/live across private VPC network                  |
|  - Demuxes 30 streams via FFmpeg (-c:v copy)                                          |
|  - WebCodecs + OffscreenCanvas / Canvas Rendering under Xvfb                          |
|  - Systemd autostart on instance boot                                                 |
|  - Internal telemetry (/var/log/benchmark/fps_metrics.log)                            |
+---------------------------------------------------------------------------------------+
```

### Setting Up Box A (Dedicated RTSP Server Box):
1. Launch an Ubuntu 22.04 instance (e.g. `c6i.large`, `c7i.large`, or `t3.medium`) in the **same VPC and Availability Zone** as your benchmark box.
2. In Box A's Security Group, allow **Inbound TCP Port 8554** from Box B's Security Group (or your VPC CIDR, e.g. `10.0.0.0/16` or `172.31.0.0/16`).
3. SSH into Box A and run the automated setup script:
   ```bash
   # Clone repo or copy script to Box A
   sudo ../../rtsp-server/setup.sh
   ```
4. Note Box A's private IP (e.g. `10.0.1.50`). The stream is now live and auto-starts on boot at `rtsp://<BOX_A_PRIVATE_IP>:8554/live`.

---

## 3. Configuring Box B (The Benchmark Box)

On Box B, configure `.env` to point to Box A's private IP:
```bash
# In /opt/rtsp-stress-test/cpu/Electron/.env:
RTSP_URL=rtsp://<BOX_A_PRIVATE_IP>:8554/live
STREAM_COUNT=30
MACHINE_ID=c7i-8xlarge-node-1
BENCHMARK_LOG_DIR=/var/log/benchmark
```

Test network reachability from Box B to Box A:
```bash
nc -zv <BOX_A_PRIVATE_IP> 8554
# Expected: Connection to <BOX_A_PRIVATE_IP> port 8554 [tcp/*] succeeded!
```

---

## 4. Zero-Touch Automatic Launch (Option A: AWS User Data)

When launching a brand-new EC2 instance in the AWS Management Console, you can have the benchmark configure and launch automatically upon the first boot:

1. Open AWS EC2 Console -> **Launch Instance**.
2. Select **Ubuntu Server 22.04 LTS**.
3. Choose instance type (e.g. `c7i.8xlarge`).
4. Scroll down and expand **Advanced details**.
5. In the **User data** field, paste the contents of [`scripts/ec2_userdata.sh`](file:///Users/morfes/projects/rtsp-stress-test/cpu/Electron/scripts/ec2_userdata.sh).
6. *(Optional)* If pulling code from a git repository, export your repository URL at the top of the user data script:
   ```bash
   export BENCHMARK_GIT_REPO="https://github.com/your-org/rtsp-stress-test.git"
   ```
7. Click **Launch Instance**.
8. **Result:** The instance boots, installs Node.js, FFmpeg, Xvfb, and MediaMTX, pulls and builds the project, installs the systemd service, and launches the 30-stream benchmark automatically.

---

## 5. Transferring Code from macOS (Option B: Rsync / Tarball)

If you are launching an instance without User Data, or deploying your local macOS workspace directly:

### Option B1: Direct Rsync from macOS
Run this command from your macOS terminal inside the project root:

```bash
# Define your EC2 instance IP and SSH key
EC2_IP="<YOUR_EC2_PUBLIC_IP>"
KEY_PATH="~/.ssh/your-aws-key.pem"

# Rsync code to /opt/rtsp-stress-test on the EC2 machine
ssh -i "$KEY_PATH" ubuntu@"$EC2_IP" "sudo mkdir -p /opt/rtsp-stress-test && sudo chown -R ubuntu:ubuntu /opt/rtsp-stress-test"

rsync -avz -e "ssh -i $KEY_PATH" \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude 'logs' \
  --exclude '.git' \
  ./ ubuntu@"$EC2_IP":/opt/rtsp-stress-test/
```

### Option B2: Tarball Archive
From your macOS terminal:
```bash
tar --exclude='node_modules' --exclude='dist' --exclude='logs' --exclude='.git' -czvf rtsp-stress-test.tar.gz ./
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

Once the code is on the EC2 machine (in `/opt/rtsp-stress-test/cpu/Electron`), SSH into the instance:

```bash
ssh -i "$KEY_PATH" ubuntu@"$EC2_IP"
```

### Step 6.1: Install System Prerequisites (One-Time)
```bash
sudo apt update && sudo apt install -y curl ffmpeg xvfb git netcat-openbsd htop jq
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs

# Install MediaMTX for local test streams
wget -q https://github.com/bluenviron/mediamtx/releases/download/v1.9.0/mediamtx_v1.9.0_linux_amd64.tar.gz -O /tmp/mediamtx.tar.gz
sudo tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin mediamtx
sudo chmod +x /usr/local/bin/mediamtx
rm /tmp/mediamtx.tar.gz
```

### Step 6.2: Build the Application
```bash
cd /opt/rtsp-stress-test/cpu/Electron
npm install
npm run build
```

### Step 6.3: Configure Autostart via Systemd
Run the automated autostart setup script:
```bash
./scripts/setup_autostart.sh
```

This script automatically:
1. Creates `/var/log/benchmark` with full read/write permissions.
2. Installs `/etc/systemd/system/rtsp-benchmark-cpu.service`.
3. Enables the service so it **starts automatically on every system boot / reboot**.
4. Starts the service immediately.

---

## 7. Customizing Configuration via Environment Variables

To change stream counts or point to external RTSP camera feeds, create or edit `/opt/rtsp-stress-test/cpu/Electron/.env`:

```bash
# Number of concurrent streams (default 30)
STREAM_COUNT=30

# RTSP Stream Source (Separate Box in VPC or local):
RTSP_URL=rtsp://10.0.1.50:8554/live

# Or 30 unique camera streams:
# RTSP_URL_PATTERN=rtsp://10.0.1.50:8554/stream%d

# Identifier for telemetry metrics
MACHINE_ID=c7i-8xlarge-node-1

# Telemetry log directory
BENCHMARK_LOG_DIR=/var/log/benchmark
```

After modifying `.env`, restart the service:
```bash
sudo systemctl restart rtsp-benchmark-cpu.service
```

---

## 8. Verifying Autostart on Reboot

To prove that the benchmark starts automatically without human intervention, reboot the instance:

```bash
sudo reboot
```

Wait 30 seconds, SSH back into the machine, and verify:
```bash
sudo systemctl status rtsp-benchmark-cpu.service
tail -f /var/log/benchmark/fps_metrics.log
```
The service will be active, Xvfb will be running, and metrics will be streaming to disk.
