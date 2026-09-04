# Automated Linux Deployment & Autostart Guide (C++ Qt6 CPU Benchmark)

This document provides complete step-by-step instructions to deploy the 30-camera RTSP CPU benchmark to an AWS EC2 Ubuntu Linux instance and configure it to **start automatically on instance boot**, running continuously for 24-hour headless stress testing with zero manual intervention.

---

## 1. AWS EC2 Instance Sizing & Architecture

### Hardware Sizing Matrix
| Benchmark Role | AWS Instance Type | Specs | Target Purpose |
| :--- | :--- | :--- | :--- |
| **Baseline Headroom Benchmark** | **`c7i.8xlarge`** | 32 vCPUs (16 physical cores), 64 GiB DDR5 | Official 24-hour benchmark. Ensures total CPU usage stays strictly below the **85% headroom limit**. |
| **Bare-Minimum Simulation** | **`c7i.4xlarge`** | 16 vCPUs (8 physical cores), 32 GiB DDR5 | Simulates a bare-minimum production 8-core desktop PC. Pushes CPU decoders to ~80%–90% load. |
| **RTSP Server Box (Box A)** | **`c7i.large`** / **`c6i.large`** | 2 vCPUs, 4 GiB RAM | Dedicated instance serving the 1440p RTSP stream to isolate video streaming from decoding. |

* **Operating System:** Ubuntu 24.04 LTS or 22.04 LTS AMD64 (`ami-xxxx`)
* **Storage:** 40 GiB gp3 root volume
* **Security Groups:**
  - **Box A (RTSP Server):** Inbound TCP port `22` (SSH), Inbound TCP port `8554` (RTSP from Box B or VPC CIDR `10.0.0.0/16`).
  - **Box B (Benchmark):** Inbound TCP port `22` (SSH), Outbound all traffic.

---

## 2. Multi-Box Architecture Overview

To eliminate encoding interference, Box A publishes the feed while Box B runs the 30 software decoders:

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
|     Box B: Benchmark Box (C++ Qt6 CPU)                                                |
|  Private IP: 10.0.1.100                                                               |
|                                                                                       |
|  - Connects to rtsp://10.0.1.50:8554/live across private VPC network                  |
|  - 30 × libavcodec software decoders on dedicated QThreads                            |
|  - libswscale planar YUV -> RGB32 conversion on background threads                    |
|  - Wait-free lock-free triple buffer handoff                                          |
|  - Zero-copy QImage blit via QPainter inside Xvfb                                     |
|  - Automated systemd daemon starts on instance launch                                 |
|  - Internal FPS logging: /var/log/benchmark/fps_metrics.log                           |
|  - External OS polling:  /var/log/benchmark/hardware_metrics.csv                     |
+---------------------------------------------------------------------------------------+
```

---

## 3. Step-by-Step Deployment Runbook

### Phase 1: Set Up Box A (Dedicated RTSP Server Box)
1. SSH into Box A:
   ```bash
   ssh -i your-key.pem ubuntu@<BOX_A_PUBLIC_IP>
   ```
2. Install MediaMTX and FFmpeg:
   ```bash
   sudo apt update && sudo apt install -y ffmpeg wget netcat-openbsd
   wget https://github.com/bluenviron/mediamtx/releases/download/v1.9.0/mediamtx_v1.9.0_linux_amd64.tar.gz
   tar -xzf mediamtx_v1.9.0_linux_amd64.tar.gz && sudo mv mediamtx /usr/local/bin/
   ```
3. Configure `mediamtx.yml` with large buffer queues for 30 concurrent readers:
   ```bash
   cat << 'EOF' > mediamtx.yml
   api: yes
   protocols: [tcp]
   readBufferCount: 8192
   writeQueueSize: 8192
   paths:
     all:
   EOF
   ```
4. Start MediaMTX and publish the 1440p 25 FPS stream:
   ```bash
   mediamtx mediamtx.yml &

   ffmpeg -re -f lavfi -i "testsrc2=size=2560x1440:rate=25" \
     -c:v libx264 -preset ultrafast -tune zerolatency -threads 4 \
     -g 25 -pix_fmt yuv420p \
     -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
   ```

---

### Phase 2: Deploy & Provision Box B (Benchmark Box)

#### Step 1: Connect to Box B
```bash
ssh -i your-key.pem ubuntu@<BOX_B_PUBLIC_IP>
```

#### Step 2: Clone Repository
```bash
sudo git clone https://github.com/your-org/rtsp-stress-test.git /opt/rtsp-stress-test
sudo chown -R ubuntu:ubuntu /opt/rtsp-stress-test
cd /opt/rtsp-stress-test/cpu/CPP
```

#### Step 3: Run Automated Provisioning
```bash
chmod +x scripts/*.sh
sudo ./scripts/ec2_userdata.sh
```
This script installs:
- Build tools: `build-essential`, `cmake`, `pkg-config`, `git`
- Qt6 libraries: `qt6-base-dev`
- FFmpeg development libraries: `libavcodec-dev`, `libavformat-dev`, `libswscale-dev`, `libavutil-dev`, `ffmpeg`
- Virtual display server: `xvfb`
- Networking tools: `netcat-openbsd`
- Initializes `/var/log/benchmark` with 777 permissions.

#### Step 4: Compile Release Binary
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```
The optimized executable is generated at:
`/opt/rtsp-stress-test/cpu/CPP/build/rtsp-stress-test-cpp-cpu`

#### Step 5: Test Network Connectivity to Box A
```bash
# Verify connectivity to Box A private IP on port 8554
nc -z -v -w 3 10.0.1.50 8554
```
*Expected Output:* `Connection to 10.0.1.50 8554 port [tcp/*] succeeded!`

#### Step 6: Configure Environment Variables
Set the target RTSP URL pointing to Box A in `/etc/environment` or directly in the systemd unit:
```bash
# Add to /etc/environment
sudo sh -c 'echo "RTSP_URL=rtsp://10.0.1.50:8554/live" >> /etc/environment'
sudo sh -c 'echo "STREAM_COUNT=30" >> /etc/environment'
```

#### Step 7: Configure Automated Autostart via Systemd
```bash
cd /opt/rtsp-stress-test/cpu/CPP
sudo ./scripts/setup_autostart.sh
```
This script automatically:
1. Customizes `rtsp-benchmark-cpp-cpu.service` with current user and paths.
2. Installs the service to `/etc/systemd/system/`.
3. Enables the service to start automatically on every system boot.
4. Starts the service immediately.

---

### Phase 3: Post-Deployment Verification

#### 1. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-cpp-cpu.service --no-pager
```

#### 2. Monitor Live Application Output
```bash
journalctl -u rtsp-benchmark-cpp-cpu.service -f --output=cat
```

#### 3. Monitor Telemetry Metrics
```bash
# 1. Rolling 60-second FPS performance buckets:
tail -f /var/log/benchmark/fps_metrics.log

# 2. 10-second OS hardware utilization:
tail -f /var/log/benchmark/hardware_metrics.csv
```

#### 4. Reboot Test (Verify Zero-Intervention Autostart)
```bash
sudo reboot
```
Wait 60 seconds, reconnect via SSH, and confirm the benchmark resumed immediately:
```bash
sudo systemctl status rtsp-benchmark-cpp-cpu.service
tail -n 25 /var/log/benchmark/fps_metrics.log
```
