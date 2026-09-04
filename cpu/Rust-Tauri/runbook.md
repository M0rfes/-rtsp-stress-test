# Operations & Troubleshooting Runbook (Rust Tauri CPU Benchmark)

This runbook provides procedures for monitoring, verifying, and troubleshooting the 6-hour RTSP CPU benchmark running under systemd or headless CLI on AWS EC2 Ubuntu Linux.

---

## 1. Quick Health Check (30-Second Verification)

Run these checks to confirm the benchmark is actively decoding 30 streams:

### A. Verify Process Hierarchy
```bash
# Verify Rust Tauri binary, Xvfb, and hardware poller are running
pgrep -a rtsp-stress-test-tauri-cpu
pgrep -a Xvfb
pgrep -a poll_hardware.sh
```
*Expected Output:* The Tauri benchmark binary and polling script should be active.

### B. Verify Log Output Generation
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

---

## 3. Headroom Pass/Fail Evaluation Rules

According to the project specification, an implementation **FAILS** if it violates any of the following conditions for more than 5 consecutive minutes:

| Metric | Fail Threshold | Verification Command |
| :--- | :--- | :--- |
| **Total CPU Usage** | **> 85% sustained** | `tail -n 30 /var/log/benchmark/hardware_metrics.csv \| awk -F',' '{print $3}'` |
| **Stream FPS** | **< 20 FPS sustained** | Check `unacceptable` buckets in `fps_metrics.log` |
| **Process Crash** | **Application restarts** | Check PID stability in `hardware_metrics.csv` |

---

## 4. Troubleshooting Playbook

### Issue 1: Stream FPS is 0 or players show "Waiting / Connecting"
* **Symptom:** UI tiles remain on "Connecting", FPS badge shows `0 FPS`.
* **Root Causes & Solutions:**
  1. **VPC Network Unreachable (Separate Box Setup):** If using a separate RTSP server box (Box A), test TCP reachability:
     ```bash
     # From Benchmark Box (Box B):
     nc -zv <BOX_A_PRIVATE_IP> 8554
     ```
     - If connection times out or is refused, check AWS EC2 Security Groups on Box A. Ensure an inbound rule exists for **Port 8554 TCP** from Box B's Security Group or VPC subnet.
  2. **Local Stream Mode (Single Box):** If running locally, verify port 8554:
     ```bash
     nc -zv 127.0.0.1 8554
     pgrep -a mediamtx
     ```
  3. **GStreamer Demuxer Logs:** Check backend console output for RTSP connection messages:
     ```bash
     # Inspect application stdout
     tail -f ~/.local/share/rtsp-stress-test-tauri-cpu/logs
     ```

### Issue 2: Permission Denied on `/var/log/benchmark`
* **Symptom:** Logs appear in `./logs/` instead of `/var/log/benchmark/`.
* **Solution:**
  ```bash
  sudo mkdir -p /var/log/benchmark
  sudo chmod 777 /var/log/benchmark
  ```

### Issue 3: High CPU Usage (> 85%) on Lower-Tier EC2 Instances
* **Symptom:** CPU usage is 90%–100% on instances with fewer than 16 physical cores.
* **Diagnosis:** 30 concurrent software decoders at 1440p require 750 FPS decoding throughput. On `c7i.4xlarge` (8 physical cores), this pushes the CPU to its limits by design.
* **Action:**
  - For official benchmark validation, use `c7i.8xlarge` (32 vCPUs / 16 physical cores).
  - To test fewer streams on lower-tier boxes, set `STREAM_COUNT`:
    ```bash
    STREAM_COUNT=16 ./scripts/run_benchmark_headless.sh
    ```

### Issue 4: Xvfb Display Server Collisions
* **Symptom:** `Fatal server error: Server is already active for display 99`.
* **Solution:** The launch script uses `xvfb-run -a`, which automatically scans for the next free display number. If an orphaned Xvfb lockfile remains:
  ```bash
  sudo rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
  sudo killall Xvfb 2>/dev/null || true
  ```
