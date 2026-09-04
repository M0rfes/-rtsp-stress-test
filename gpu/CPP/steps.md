# Automated Linux Deployment & Autostart Guide (C++ Qt6 GPU Benchmark)

This document provides step-by-step instructions to deploy the 30-camera RTSP GPU Zero-Copy benchmark from your development machine to an AWS EC2 Ubuntu Linux instance equipped with an NVIDIA GPU (`g6.xlarge` / `g4dn.xlarge`) and configure it to **start automatically as soon as the instance launches or boots**, requiring zero manual intervention.

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
|     Box B: Benchmark Box (C++ Qt6 GPU - g6.xlarge / g4dn.xlarge)                      |
|  Private IP: 10.0.1.100                                                               |
|                                                                                       |
|  - Connects to rtsp://10.0.1.50:8554/live across private VPC network                  |
|  - 30 × libavcodec CUDA hardware decoders (NVIDIA NVDEC ASIC)                         |
|  - Zero CPU RAM copies: direct VRAM frame preservation                                |
|  - QOpenGLWidget rendering with GLSL BT.709 hardware shaders                          |
|  - Systemd autostart on instance boot                                                 |
|  - Internal telemetry (/var/log/benchmark/fps_metrics.log)                            |
+---------------------------------------------------------------------------------------+
```

---

## 3. Deployment Steps

### Step 1: Clone Repository on Benchmark Box
```bash
git clone https://github.com/your-org/rtsp-stress-test.git /opt/rtsp-stress-test
cd /opt/rtsp-stress-test/gpu/CPP
```

### Step 2: System Provisioning
```bash
chmod +x scripts/*.sh
sudo ./scripts/ec2_userdata.sh
```

### Step 3: Build Release Binary
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

The optimized executable is generated at `build/rtsp-stress-test-cpp-gpu`.

### Step 4: Pre-Flight Headless Smoke Test (2 Minutes)
Before enabling the 24-hour daemon, run the headless benchmark interactively for 1–2 minutes to verify NVIDIA CUDA acceleration, Xvfb resolution, and the first 60-second JSON flush:
```bash
# Ensure log directory exists
sudo mkdir -p /var/log/benchmark && sudo chown -R $USER:$USER /var/log/benchmark

# Run headless test with CUDA hardware acceleration
xvfb-run -a -s "-screen 0 2560x1440x24" ./build/rtsp-stress-test-cpp-gpu \
  --url rtsp://<rtsp-server-ip>:8554/live \
  --streams 30 \
  --hw-accel cuda \
  --log-dir /var/log/benchmark
```
*Verification Check:*
- Watch terminal output for `[HwAccel] Successfully initialized GPU hardware acceleration: cuda`.
- Check that the 60-second flush outputs `Acceptable (25-30: 1800, 20-24: 0)`.
- Press `Ctrl+C` to terminate the test run.

### Step 5: Configure 24-Hour Automated Systemd Daemon
Install and activate the automated systemd daemon that starts on instance boot:
```bash
sudo ./scripts/setup_autostart.sh
```

This installs `/etc/systemd/system/rtsp-benchmark-cpp-gpu.service`, raises `LimitNOFILE=65536`, and sets `Restart=always` with `RestartSec=5` for self-healing in case of power or network glitches.

### Step 6: Monitor Execution & Telemetry
```bash
# 1. Verify systemd service status
sudo systemctl status rtsp-benchmark-cpp-gpu.service --no-pager

# 2. Tail 60-second FPS performance buckets
tail -f /var/log/benchmark/fps_metrics.log

# 3. Tail 10-second external CPU / RAM / GPU metrics
tail -f /var/log/benchmark/hardware_metrics.csv

# 4. Monitor NVIDIA NVDEC hardware utilization in real time
watch -n 2 "nvidia-smi --query-gpu=utilization.gpu,utilization.decoder,memory.used,temperature.gpu --format=csv"
```

### Step 7: Post-Benchmark Stopping & Log Archival
When the 24-hour benchmark completes:
```bash
# Stop the daemon
sudo systemctl stop rtsp-benchmark-cpp-gpu.service

# Compress telemetry artifacts for reporting
tar -czvf /home/ubuntu/cpp_gpu_benchmark_results.tar.gz \
  /var/log/benchmark/fps_metrics.log \
  /var/log/benchmark/hardware_metrics.csv

echo "[+] Benchmark artifacts packaged: /home/ubuntu/cpp_gpu_benchmark_results.tar.gz"
```
