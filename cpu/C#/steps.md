# Automated Linux Deployment & Autostart Guide (C# Avalonia CPU Benchmark)

This document provides complete step-by-step instructions to deploy the 30-camera RTSP CPU benchmark to an AWS EC2 Ubuntu Linux instance and configure it to **start automatically on instance boot**, running continuously for 6-hour headless stress testing with zero manual intervention.

---

## 1. AWS EC2 Instance Sizing & Architecture

### Hardware Sizing Matrix
| Benchmark Role | AWS Instance Type | Specs | Target Purpose |
| :--- | :--- | :--- | :--- |
| **Baseline Headroom Benchmark** | **`c7i.8xlarge`** | 32 vCPUs (16 physical cores), 64 GiB DDR5 | Official 6-hour benchmark. Ensures total CPU usage stays strictly below the **85% headroom limit**. |
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
|     Box B: Benchmark Box (C# Avalonia CPU)                                            |
|  Private IP: 10.0.1.100                                                               |
|                                                                                       |
|  - Connects to rtsp://10.0.1.50:8554/live across private VPC network                  |
|  - 30 × FFmpeg.AutoGen software decoders on dedicated background Task threads         |
|  - Pre-allocated managed byte[] buffers (Zero GC thrashing)                           |
|  - WriteableBitmap.Lock() & Buffer.MemoryCopy() SIMD pixel transfer                   |
|  - Coalesced UI render dispatching avoiding dispatcher message spam                   |
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
2. Clone the repo and install the shared server (300 TCP readers):
   ```bash
   sudo ./rtsp-server/setup.sh
   ```
   Stream URL: `rtsp://<BOX_A_PRIVATE_IP>:8554/live`

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
cd /opt/rtsp-stress-test/cpu/C#
```

#### Step 3: Run System Provisioning Script
```bash
chmod +x scripts/*.sh
sudo ./scripts/ec2_userdata.sh
```

#### Step 4: Publish Optimized Release Binary
```bash
dotnet publish -c Release -o bin/publish
```

#### Step 5: Test Headless Benchmark Execution
```bash
export RTSP_URL="rtsp://10.0.1.50:8554/live"
export STREAM_COUNT=30

./scripts/run_benchmark_headless.sh
```

#### Step 6: Configure Autostart Systemd Service
```bash
sudo ./scripts/setup_autostart.sh
```

* **Verify Status:** `sudo systemctl status rtsp-benchmark-csharp-cpu.service`
* **Tail Live Output:** `journalctl -u rtsp-benchmark-csharp-cpu.service -f`
* **Tail FPS Telemetry:** `tail -f /var/log/benchmark/fps_metrics.log`
* **Tail Hardware Telemetry:** `tail -f /var/log/benchmark/hardware_metrics.csv`
