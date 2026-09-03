# Operations & Troubleshooting Runbook (Electron GPU Zero-Copy Benchmark)

This runbook provides procedures for monitoring, verifying, and troubleshooting the 24-hour RTSP GPU Zero-Copy hardware benchmark running under systemd on AWS EC2 Ubuntu Linux with NVIDIA GPUs.

---

## 1. Quick Health Check (30-Second Verification)

Run these checks to confirm the benchmark is actively utilizing the NVIDIA GPU for zero-copy hardware decoding across all 30 streams:

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-gpu.service --no-pager
```
*Expected Output:* `Active: active (running)`.

### B. Verify NVIDIA GPU & Hardware Decoder Activity
```bash
nvidia-smi
```
*Expected Output:*
- Electron processes listed under **Processes** table consuming VRAM.
- VRAM usage between ~2,000 MB and ~8,000 MB depending on stream resolution and buffer depth.

### C. Live NVDEC Decoder Utilization Check
```bash
nvidia-smi dmon -s u
```
*Expected Output:* The `dec` column should show active hardware decoding (e.g. `40%–75%`), confirming frames are being decoded by NVDEC hardware rather than the CPU.

### D. Verify Telemetry Logs
```bash
ls -lh /var/log/benchmark/
```
*Expected Output:* Both `fps_metrics.log` and `hardware_metrics.csv` should exist and have non-zero size, growing continuously.

---

## 2. Live Telemetry & Metric Monitoring

### A. Monitor 60-Second FPS Time-in-State Windows
```bash
tail -f /var/log/benchmark/fps_metrics.log
```
*Success Criterion:* In GPU mode, `fps_stream_seconds.acceptable["25_to_30_fps"]` should be near 1,800 stream-seconds per 60-second window, with 0 stream-seconds in `unacceptable["under_5_fps"]`.

### B. Monitor 10-Second Hardware Utilization CSV
```bash
tail -f /var/log/benchmark/hardware_metrics.csv
```
Columns:
```csv
timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent
```
*Expected in GPU Mode:* `gpu_vram_mb` > 0 and `gpu_decoder_percent` > 0.

### C. Monitor Live Application & Renderer Logs
```bash
journalctl -u rtsp-benchmark-gpu.service -f --output=cat
```

---

## 3. Headroom Pass/Fail Evaluation Rules

An implementation **FAILS** if it violates any of the following headroom limits for more than 5 consecutive minutes:

| Metric | Fail Threshold | Verification Command |
| :--- | :--- | :--- |
| **Total CPU Usage** | **> 85% sustained** | `tail -n 30 /var/log/benchmark/hardware_metrics.csv \| awk -F',' '{print $3}'` |
| **GPU 3D Engine Usage** | **> 80% sustained** | `nvidia-smi --query-gpu=utilization.gpu --format=csv` |
| **GPU VRAM Allocation** | **> 90% sustained** | `nvidia-smi --query-gpu=memory.used,memory.total --format=csv` |
| **GPU Decoder (NVDEC)** | **> 90% sustained** | `tail -n 30 /var/log/benchmark/hardware_metrics.csv \| awk -F',' '{print $6}'` |
| **Stream FPS** | **< 20 FPS sustained** | Check `unacceptable` buckets in `fps_metrics.log` |

---

## 4. Troubleshooting Playbook

### Issue 1: NVDEC utilization is 0% (`dec=0`) or CPU usage is unusually high (> 80%)
* **Symptom:** Electron is running, but `nvidia-smi dmon` shows `dec=0` and CPU load is high (~80%–95%), indicating Chromium has fallen back to software decode.
* **Root Causes & Solutions:**
  1. **Missing VA-API Chromium Flags:** Ensure the launch script passed all required flags:
     ```bash
     ps aux | grep electron
     ```
     Verify that `--enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiOnNvidiaGPUs --use-gl=egl --disable-software-rasterizer` are in the command line arguments.
  2. **VA-API Driver Permissions:** Check `/dev/dri/renderD128` permissions:
     ```bash
     ls -l /dev/dri/renderD*
     sudo chmod 666 /dev/dri/renderD*
     ```
  3. **Verify VA-API with `vainfo`:**
     ```bash
     vainfo --display drm --device /dev/dri/renderD128
     ```
     Ensure `VAProfileH264Main` and `VAProfileH264High` are listed with `VAEntrypointVLD`.

### Issue 2: Service is in a restart crash loop
* **Symptom:** `systemctl status rtsp-benchmark-gpu` displays `Active: failed`.
* **Root Causes & Solutions:**
  1. **Build missing:**
     ```bash
     cd /opt/rtsp-stress-test/gpu/Electron && npm run build
     ```
  2. **Check exact exit reason:**
     ```bash
     journalctl -u rtsp-benchmark-gpu.service -e --no-pager
     ```
  3. **NVIDIA Kernel Module not loaded:**
     ```bash
     sudo modprobe nvidia
     nvidia-smi
     ```

### Issue 3: GPU VRAM Spilling (> 90%)
* **Symptom:** VRAM usage climbs until memory allocation error occurs.
* **Root Causes & Solutions:**
  1. **Unclosed VideoFrames:** The renderer in `src/renderer/components/VideoPlayer.tsx` immediately invokes `videoFrame.close()` inside the `createImageBitmap().then()` callback and drops incoming frames if `pendingFramesRef.current > 2`.
  2. If VRAM is constrained on smaller GPUs (e.g. 16 GB T4), lower `STREAM_COUNT` to 16 or 20 in `/opt/rtsp-stress-test/gpu/Electron/.env`.

### Issue 4: Stream FPS is 0 / Tiles show "Connecting"
* **Symptom:** Video tiles remain on "Connecting" placeholder.
* **Root Causes & Solutions:**
  1. **VPC Network Unreachable (Separate Box Setup):** If using a separate RTSP server box (Box A), test TCP reachability:
     ```bash
     # From GPU Benchmark Box (Box B):
     nc -zv <BOX_A_PRIVATE_IP> 8554
     ```
     - If connection times out or is refused, check AWS EC2 Security Groups on Box A. Ensure an inbound rule exists for **Port 8554 TCP** from Box B's Security Group or VPC subnet (`10.0.0.0/16` / `172.31.0.0/16`).
     - Test RTSP options handshake from Box B:
       ```bash
       curl -v -X OPTIONS rtsp://<BOX_A_PRIVATE_IP>:8554/live
       ```
  2. **Verify Stream Status on Box A:**
     SSH into Box A and verify the MediaMTX service is publishing:
     ```bash
     sudo systemctl status rtsp-feed-server.service
     ffmpeg -rtsp_transport tcp -i rtsp://127.0.0.1:8554/live -t 3 -f null -
     ```
  3. **Local Stream Mode (Single Box):** If running locally, verify port 8554:
     ```bash
     nc -zv 127.0.0.1 8554
     pgrep -a mediamtx
     ```
  4. **Demuxer FFmpeg Errors:** Check demuxer stderr messages:
     ```bash
     journalctl -u rtsp-benchmark-gpu.service -f | grep -i demuxer
     ```

### Issue 5: Xvfb Display Server Collisions
* **Symptom:** `Fatal server error: Server is already active for display 99`.
* **Solution:**
  ```bash
  sudo rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
  sudo killall Xvfb 2>/dev/null || true
  sudo systemctl restart rtsp-benchmark-gpu.service
  ```

---

## 5. Useful Operational Commands

### Control Service
```bash
# Restart GPU benchmark
sudo systemctl restart rtsp-benchmark-gpu.service

# Stop GPU benchmark
sudo systemctl stop rtsp-benchmark-gpu.service

# Check service status
sudo systemctl status rtsp-benchmark-gpu.service --no-pager
```

### Clean Logs for a Fresh Benchmark Run
```bash
sudo systemctl stop rtsp-benchmark-gpu.service
sudo rm -f /var/log/benchmark/fps_metrics.log /var/log/benchmark/hardware_metrics.csv
sudo systemctl start rtsp-benchmark-gpu.service
```

### Archive and Download 24-Hour Benchmark Results
On the EC2 instance:
```bash
tar -czvf /tmp/gpu_benchmark_results_$(date +%F).tar.gz /var/log/benchmark/
```
From your macOS machine:
```bash
scp -i ~/.ssh/your-aws-key.pem ubuntu@<EC2_IP>:/tmp/gpu_benchmark_results_*.tar.gz ./
```
