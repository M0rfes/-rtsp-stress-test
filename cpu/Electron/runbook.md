# Operations & Troubleshooting Runbook (Electron CPU Benchmark)

This runbook provides procedures for monitoring, verifying, and troubleshooting the 6-hour RTSP CPU benchmark running under systemd on AWS EC2 Ubuntu Linux.

---

## 1. Quick Health Check (30-Second Verification)

Run these checks to confirm the benchmark is actively decoding 30 streams:

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-cpu.service --no-pager
```
*Expected Output:* `Active: active (running)`.

### B. Verify Process Hierarchy
```bash
# Verify Electron, Xvfb, FFmpeg demuxers, and hardware poller are running
pgrep -a electron
pgrep -a Xvfb
echo "Active FFmpeg Demuxers: $(pgrep -c ffmpeg)"
```
*Expected Count:* `30` active FFmpeg processes (1 per stream) plus 1 FFmpeg test feed generator if using MediaMTX.

### C. Verify Log Output Generation
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
To view cleanly formatted JSON payloads using `jq`:
```bash
tail -f /var/log/benchmark/fps_metrics.log | grep -E '^{|^  "timestamp"|^  "fps_stream_seconds"'
```
*Success Criterion:* The `fps_stream_seconds.acceptable["25_to_30_fps"]` bucket should hold the vast majority of the 1,800 stream-seconds per 60-second window.

### B. Monitor 10-Second Hardware Utilization
```bash
tail -f /var/log/benchmark/hardware_metrics.csv
```
Columns: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`

### C. Monitor Systemd Live Execution Logs
```bash
journalctl -u rtsp-benchmark-cpu.service -f --output=cat
```
Shows renderer console messages, demuxer connections, and flush events in real time.

---

## 3. Headroom Pass/Fail Evaluation Rules

According to the project specification, an implementation **FAILS** if it violates any of the following conditions for more than 5 consecutive minutes:

| Metric | Fail Threshold | Verification Command |
| :--- | :--- | :--- |
| **Total CPU Usage** | **> 85% sustained** | `tail -n 30 /var/log/benchmark/hardware_metrics.csv \| awk -F',' '{print $3}'` |
| **Stream FPS** | **< 20 FPS sustained** | Check `unacceptable` buckets in `fps_metrics.log` |
| **Process Crash** | **Service restarts** | `systemctl show rtsp-benchmark-cpu -p NRestarts` |

---

## 4. Troubleshooting Playbook

### Issue 1: Service is in `failed` or `auto-restart` crash loop
* **Symptom:** `systemctl status rtsp-benchmark-cpu` displays `Active: failed (Result: exit-code)`.
* **Root Causes & Solutions:**
  1. **Build missing:** Ensure `dist/` exists:
     ```bash
     cd /opt/rtsp-stress-test/cpu/Electron && npm run build
     ```
  2. **Missing `xvfb-run`:**
     ```bash
     sudo apt update && sudo apt install -y xvfb
     ```
  3. **Check exact exit reason:**
     ```bash
     journalctl -u rtsp-benchmark-cpu.service -e --no-pager
     ```

### Issue 2: Stream FPS is 0 or players show "Waiting / Connecting"
* **Symptom:** UI tiles remain on "Connecting", FPS badge shows `0 FPS`.
* **Root Causes & Solutions:**
  1. **VPC Network Unreachable (Separate Box Setup):** If using a separate RTSP server box (Box A), test TCP reachability:
     ```bash
     # From Benchmark Box (Box B):
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
     journalctl -u rtsp-benchmark-cpu.service -f | grep -i demuxer
     ```

### Issue 3: Permission Denied on `/var/log/benchmark`
* **Symptom:** Logs appear in `./logs/` instead of `/var/log/benchmark/`, or service logs show `EACCES: permission denied`.
* **Solution:**
  ```bash
  sudo mkdir -p /var/log/benchmark
  sudo chmod 777 /var/log/benchmark
  sudo systemctl restart rtsp-benchmark-cpu.service
  ```

### Issue 4: High CPU Usage (> 85%) on Lower-Tier EC2 Instances
* **Symptom:** CPU usage is 90%–100% on instances with fewer than 16 physical cores.
* **Diagnosis:** 30 concurrent software decoders at 1440p require 750 FPS decoding throughput. On `c7i.4xlarge` (8 physical cores), this pushes the CPU to its limits by design.
* **Action:**
  - For the official headroom benchmark, run on `c7i.8xlarge` (32 vCPUs / 16 physical cores).
  - To test fewer streams on lower-tier boxes, reduce `STREAM_COUNT` in `.env`:
    ```bash
    echo "STREAM_COUNT=16" | sudo tee -a /opt/rtsp-stress-test/cpu/Electron/.env
    sudo systemctl restart rtsp-benchmark-cpu.service
    ```

### Issue 5: Xvfb Display Server Collisions
* **Symptom:** `Fatal server error: Server is already active for display 99`.
* **Solution:** The launch script uses `xvfb-run -a`, which automatically scans for the next free display number. If an orphaned Xvfb lockfile remains in `/tmp`:
  ```bash
  sudo rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
  sudo killall Xvfb 2>/dev/null || true
  sudo systemctl restart rtsp-benchmark-cpu.service
  ```

---

## 5. Useful Operational Commands

### Control Service
```bash
# Restart benchmark
sudo systemctl restart rtsp-benchmark-cpu.service

# Stop benchmark
sudo systemctl stop rtsp-benchmark-cpu.service

# Temporarily disable autostart on boot
sudo systemctl disable rtsp-benchmark-cpu.service
```

### Clean Logs for a Fresh Benchmark Run
```bash
sudo systemctl stop rtsp-benchmark-cpu.service
sudo rm -f /var/log/benchmark/fps_metrics.log /var/log/benchmark/hardware_metrics.csv
sudo systemctl start rtsp-benchmark-cpu.service
```

### Archive and Download 6-Hour Benchmark Results
On the EC2 instance:
```bash
tar -czvf /tmp/cpu_benchmark_results_$(date +%F).tar.gz /var/log/benchmark/
```
From your macOS machine:
```bash
scp -i ~/.ssh/your-aws-key.pem ubuntu@<EC2_IP>:/tmp/cpu_benchmark_results_*.tar.gz ./
```
