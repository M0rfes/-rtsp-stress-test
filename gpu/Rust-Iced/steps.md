# Automated Linux Deployment & Autostart Guide (Rust Iced GPU Benchmark)

This document provides step-by-step instructions to deploy the 30-camera RTSP GPU Zero-Copy benchmark from your macOS development machine to an AWS EC2 Ubuntu Linux instance equipped with an NVIDIA GPU (`g6.xlarge` / `g4dn.xlarge` / `g5.xlarge`) and configure it to **start automatically as soon as the instance launches or boots**, requiring zero manual intervention.

---

## 1. AWS EC2 Instance Sizing & Configuration

1. **Instance Type:**
   - **Target Benchmark:** `g6.xlarge` (4 vCPUs, 16 GiB RAM, NVIDIA L4 GPU) or `g4dn.xlarge` (4 vCPUs, 16 GiB RAM, NVIDIA T4 GPU)
2. **Operating System:** Ubuntu 22.04 LTS or 24.04 LTS AMD64
3. **Storage:** 50 GiB gp3 root volume
4. **Security Group:**
   - Inbound SSH (Port 22, TCP) from your IP
   - Inbound RTSP (Port 8554, TCP) if receiving video from a separate VPC box
   - Outbound all traffic

---

## 2. Multi-Box Architecture: Dedicated RTSP Server Box in Same VPC

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
|     Box B: Benchmark Box (Rust Iced GPU - g6.xlarge / g4dn.xlarge)                    |
|  Private IP: 10.0.1.100                                                               |
|                                                                                       |
|  - Connects to rtsp://10.0.1.50:8554/live across private VPC network                  |
|  - 30 × GStreamer nvdec decoders (NVIDIA hardware decode)                             |
|  - OpenGL VRAM texture extraction with zero CPU memory copies                         |
|  - Iced iced_wgpu backend rendering WGSL shader textured quads                        |
|  - Systemd autostart on instance boot                                                 |
|  - Internal telemetry (/var/log/benchmark/fps_metrics.log)                            |
+---------------------------------------------------------------------------------------+
```

---

## 3. Deployment Steps

### Step 1: Clone Repository on Benchmark Box
```bash
git clone https://github.com/your-org/rtsp-stress-test.git /opt/rtsp-stress-test
cd /opt/rtsp-stress-test/gpu/Rust-Iced
```

### Step 2: System Provisioning
```bash
chmod +x scripts/*.sh
sudo ./scripts/ec2_userdata.sh
source "$HOME/.cargo/env"
```

### Step 3: Build Release Binary
```bash
cargo build --release
```

### Step 4: Configure 6-Hour Automated Systemd Daemon
```bash
sudo ./scripts/setup_autostart.sh
```

### Step 5: Monitor Execution & Telemetry
```bash
# Verify systemd service status
sudo systemctl status rtsp-benchmark-iced-gpu.service

# Tail 60-second FPS performance buckets
tail -f /var/log/benchmark/fps_metrics.log

# Tail 10-second external CPU / RAM / GPU metrics
tail -f /var/log/benchmark/hardware_metrics.csv
```
