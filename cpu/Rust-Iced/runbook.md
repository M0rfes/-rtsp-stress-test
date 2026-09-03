# Operations, Debugging & Troubleshooting Runbook (Rust Iced CPU Benchmark)

This runbook provides procedures for monitoring, verifying, debugging, and troubleshooting the 24-hour RTSP CPU benchmark running under systemd or headless CLI on AWS EC2 Ubuntu Linux using pure Rust and Iced (`tiny-skia` software rasterizer backend).

---

## 1. Quick Health Check (30-Second Verification)

Run these checks to confirm the benchmark is actively decoding 30 streams:

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-iced-cpu.service --no-pager
```
*Expected Output:* `Active: active (running)`.

### B. Verify Process Hierarchy
```bash
# Verify Rust Iced binary, Xvfb, and hardware poller are running
pgrep -a rtsp-stress-test-iced-cpu
pgrep -a Xvfb
pgrep -a poll_hardware.sh
```
*Expected Output:* The Iced benchmark binary, virtual display server (`Xvfb`), and polling script should all be active.

### C. Verify Log Output Generation
```bash
ls -lh /var/log/benchmark/
```
*Expected Output:* Both `fps_metrics.log` and `hardware_metrics.csv` should exist with non-zero size, growing continuously.

---

## 2. Live Telemetry & Metric Monitoring

### A. Monitor 60-Second FPS Time-in-State Windows
```bash
tail -f /var/log/benchmark/fps_metrics.log
```
To view cleanly formatted JSON payloads:
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
journalctl -u rtsp-benchmark-iced-cpu.service -f --output=cat
```
Shows pipeline startup, telemetry flushes, and any GStreamer bus notifications in real time.

---

## 3. Headroom Pass/Fail Evaluation Rules

According to the project specification, an implementation **FAILS** if it violates any of the following conditions for more than 5 consecutive minutes:

| Metric | Fail Threshold | Verification Command |
| :--- | :--- | :--- |
| **Total CPU Usage** | **> 85% sustained** | `tail -n 30 /var/log/benchmark/hardware_metrics.csv \| awk -F',' '{print $3}'` |
| **Stream FPS** | **< 20 FPS sustained** | Check `unacceptable` buckets in `fps_metrics.log` |
| **Process Crash** | **Application restarts** | `systemctl show rtsp-benchmark-iced-cpu -p NRestarts` |

---

## 4. Deep Debugging & Troubleshooting Playbook

### Issue 1: Stream FPS Reports Sub-20 or Sub-10
* **Symptom:** Video appears to decode, but `fps_metrics.log` reports high numbers in `10_to_19_fps` or `5_to_9_fps` buckets.
* **Root Causes & Diagnostics:**
  1. **Measuring Window Redraw Rate vs. Stream Frame Rate:**
     - In pure software rendering (`tiny-skia`), downscaling thirty 1440p images on the CPU takes ~100ms per UI frame. Therefore, the UI window redraw rate is physically limited to ~8–10 Hz.
     - **Verification:** Ensure stream frame increments are tracked in [`decoder.rs`](src/decoder.rs#L239) (`slot.last_sec_frames.fetch_add(1)`) upon frame handoff, **not** inside `ui.rs` `view()`.
  2. **MediaMTX TCP Buffer Saturation:**
     - When 30 streams connect over TCP, MediaMTX's default `readBufferCount: 512` overflows in ~20ms, logging `reader is too slow, discarding frames`.
     - **Fix:** In `mediamtx.yml`, set:
       ```yaml
       readBufferCount: 8192
       writeQueueSize: 8192
       ```
  3. **RTSP Source Encoding Starvation (Single-Box Testing):**
     - If running FFmpeg test generator and 30 software decoders on the **same machine**, FFmpeg's encoder will lag (`speed=0.85x`), causing the source stream itself to drop below 20 FPS.
     - **Fix:** Move the RTSP generator to a separate EC2 box (Box A) in the same VPC as outlined in [`steps.md`](steps.md).
  4. **CPU Core Sizing:**
     - Decoding 30 × 1440p @ 25 FPS (750 FPS aggregate) on pure CPU requires at least 16 physical cores. On 8-core or 10-core machines, the aggregate CPU capacity caps at ~500–600 FPS total (~16–20 FPS per stream).
     - **Fix:** For full 25 FPS across all 30 streams, verify on `c7i.8xlarge` (32 vCPUs / 16 physical cores). For lower-core testing, reduce stream count: `STREAM_COUNT=8 ./scripts/run_benchmark_headless.sh`.

---

### Issue 2: Stream FPS is 0 or Players Show "Connecting..."
* **Symptom:** UI tiles remain black or show "Connecting...", FPS badge shows `0 FPS`.
* **Root Causes & Diagnostics:**
  1. **VPC Network Unreachable (Separate Box Setup):**
     Test TCP connection to RTSP Server Box:
     ```bash
     nc -zv <RTSP_SERVER_PRIVATE_IP> 8554
     ```
     - If connection times out or is refused, verify AWS Security Group inbound rules on the RTSP box for **Port 8554 TCP**.
  2. **RTSP Handshake Test:**
     ```bash
     curl -v -X OPTIONS rtsp://<RTSP_SERVER_PRIVATE_IP>:8554/live
     ```
  3. **Local Stream Mode:**
     If running locally, verify MediaMTX is listening:
     ```bash
     lsof -i :8554
     pgrep -a mediamtx
     ```

---

### Issue 3: Service Crash Loop (`Active: failed` or Auto-Restarting)
* **Symptom:** `systemctl status rtsp-benchmark-iced-cpu` displays `Active: failed`.
* **Root Causes & Solutions:**
  1. **Release Binary Missing:**
     ```bash
     cd /opt/rtsp-stress-test/cpu/Rust-Iced && cargo build --release
     ```
  2. **Missing `xvfb-run`:**
     ```bash
     sudo apt update && sudo apt install -y xvfb
     ```
  3. **Inspect Exact Panic Reason:**
     ```bash
     journalctl -u rtsp-benchmark-iced-cpu.service -e --no-pager
     ```

---

### Issue 4: Xvfb Virtual Display Collisions
* **Symptom:** Log shows `Fatal server error: Server is already active for display 0`.
* **Solution:** Always invoke `xvfb-run` with the `-a` (auto-display allocation) flag:
  ```bash
  xvfb-run -a -s "-screen 0 2560x1440x24" ./target/release/rtsp-stress-test-iced-cpu
  ```

---

### Issue 5: Permission Denied on `/var/log/benchmark`
* **Symptom:** Logs appear in `./logs/` instead of `/var/log/benchmark/`.
* **Solution:**
  ```bash
  sudo mkdir -p /var/log/benchmark
  sudo chmod 777 /var/log/benchmark
  ```

---

### Issue 6: Verbose GStreamer Pipeline Debugging
To inspect low-level GStreamer element negotiation, RTP packet reception, and decoder state transitions:
```bash
# Level 3: Warnings and Errors
GST_DEBUG=3 ./target/release/rtsp-stress-test-iced-cpu

# Level 4: Information from rtspsrc and avdec_h264
GST_DEBUG=rtspsrc:4,avdec_h264:4 ./target/release/rtsp-stress-test-iced-cpu
```

---

## 5. Service Lifecycle Management

```bash
# Restart benchmark service
sudo systemctl restart rtsp-benchmark-iced-cpu

# Stop benchmark service
sudo systemctl stop rtsp-benchmark-iced-cpu

# View real-time service logs
journalctl -u rtsp-benchmark-iced-cpu -f
```
