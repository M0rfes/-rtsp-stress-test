# Operations & Troubleshooting Runbook (Rust Tauri GPU Zero-Copy Benchmark)

This runbook provides complete procedures for operating, monitoring, verifying, and debugging the 24-hour RTSP GPU Zero-Copy benchmark running under systemd or headless CLI on AWS EC2 Ubuntu Linux (e.g. `g6.xlarge`, `g4dn.xlarge`), with local desktop debugging notes for macOS.

---

## 1. Quick Health Check (30-Second Verification)

Run these checks to confirm the benchmark is actively decoding 30 streams with GPU acceleration:

### A. Verify Process Hierarchy
```bash
# Verify Rust Tauri binary, Xvfb, and hardware poller are running
pgrep -a rtsp-stress-test-tauri-gpu
pgrep -a Xvfb
pgrep -a poll_hardware.sh
```

### B. Verify NVIDIA GPU Utilization & Hardware Decoding
```bash
nvidia-smi
nvidia-smi --query-gpu=memory.used,utilization.gpu,utilization.decoder --format=csv
```
*Expected Output:*
- Memory used should show VRAM allocation for the 30 decoder surfaces.
- Decoder utilization (`utilization.decoder`) should be active (> 0%).

### C. Verify Log Output Generation
```bash
ls -lh /var/log/benchmark/
```
*Expected Output:* Both `fps_metrics.log` and `hardware_metrics.csv` should exist and grow continuously.

---

## 2. Live Telemetry & Metric Monitoring

### A. Monitor 60-Second FPS Time-in-State Windows
```bash
tail -f /var/log/benchmark/fps_metrics.log
```
To view formatted JSON payloads using `jq`:
```bash
tail -f /var/log/benchmark/fps_metrics.log | jq .
```
*Success Criterion:* The `fps_stream_seconds.acceptable["25_to_30_fps"]` bucket should hold the vast majority of the 1,800 stream-seconds per 60-second window.

### B. Monitor 10-Second Hardware Utilization
```bash
tail -f /var/log/benchmark/hardware_metrics.csv
```
Columns: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`

### C. Check Systemd Service Logs
```bash
journalctl -u rtsp-benchmark-tauri-gpu.service -f -n 100
```

---

## 3. Headroom Pass/Fail Evaluation Rules

According to the benchmark specification, an implementation **FAILS** if it violates any of the following conditions for more than 5 consecutive minutes:

| Metric | Fail Threshold | Verification Command |
| :--- | :--- | :--- |
| **Total CPU Usage** | **> 85% sustained** | `tail -n 30 /var/log/benchmark/hardware_metrics.csv \| awk -F',' '{print $3}'` |
| **GPU 3D Engine Usage** | **> 80% sustained** | `nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits` |
| **GPU VRAM Allocation** | **> 90% (spilling into system RAM)** | `nvidia-smi --query-gpu=memory.used,memory.total --format=csv` |
| **GPU Decoder (NVDEC)** | **> 90% sustained** | `nvidia-smi --query-gpu=utilization.decoder --format=csv,noheader,nounits` |
| **Stream FPS** | **< 20 FPS sustained** | Check `unacceptable` buckets in `fps_metrics.log` |
| **Process Crash** | **Application restarts** | Check PID stability in `hardware_metrics.csv` |

---

## 4. Deep Troubleshooting Playbook

### Issue 1: `VideoDecoder error: Decoding task did not complete` (macOS Desktop Only)
* **Symptom:** Logs show `[Renderer WARN] VideoDecoder error: Decoding task did not complete`. Video decoders close and attempt restarts, and FPS drops below 5.
* **Root Cause:**
  - On macOS, WebKit (`WKWebView`) routes `VideoDecoder` directly to Apple's **VideoToolbox** (`VTDecompressionSession`).
  - Apple Silicon VPUs enforce a strict hardware session concurrency limit (~8–16 simultaneous 1440p decode contexts).
  - Demanding 30 simultaneous 1440p streams at 25 FPS (750 FPS total) overflows the hardware queue.
* **Resolution:**
  - **For macOS Local Testing:** Test with 4 to 8 streams (`STREAM_COUNT=4 npm run dev` or `STREAM_COUNT=8 npm run dev`). 4 streams run smoothly at a full 25 FPS without VPU queue saturation.
  - **For AWS EC2 Deployment:** This error **does not occur on Linux**. WebKitGTK on Ubuntu uses GStreamer (`libavcodec` / VA-API) without Apple VideoToolbox session caps.

### Issue 2: WebProcess Crashes / UI Keeps Reloading (macOS WebKit Watchdog)
* **Symptom:** The Tauri window suddenly flickers, restarts, or reloads every 10–30 seconds.
* **Root Cause:**
  - 30 streams of 1440p RGBA produce `11.05 GB/second` of pixel throughput.
  - macOS `com.apple.WebKit.WebContent` has an aggressive OS memory/responsiveness watchdog. If memory buffers exceed ~2–3 GB or CoreAnimation stalls waiting for display V-Sync, macOS terminates the process.
* **Resolution:**
  - Run locally with `STREAM_COUNT=4 npm run dev`.
  - On the target Linux AWS EC2 instance, headless `Xvfb` has no display refresh lock or macOS CoreAnimation watchdog killing the process.

### Issue 3: GStreamer Jitterbuffer Drops RTP Packets Prematurely
* **Symptom:** Pipeline connects, but stream FPS is erratic or drops 50%+ of frames on local loopback.
* **Root Cause:**
  - Pipeline configured with `rtspsrc latency=0 drop-on-latency=true`. When 30 pipelines run concurrently, thread scheduling delays (1–5ms) cause GStreamer's `rtpjitterbuffer` to treat packets as late and drop them.
* **Resolution:**
  - Use `rtspsrc protocols=tcp latency=50 drop-on-latency=false !` in `src-tauri/src/demuxer.rs`. This provides a ~1.25 frame buffer at 25 FPS without dropping frames.

### Issue 4: NVDEC Hardware Decoder shows 0% Utilization on Linux
* **Symptom:** `gpu_decoder_percent` is 0 in `hardware_metrics.csv`, CPU is elevated.
* **Diagnostic Steps:**
  1. Test VA-API support with `vainfo`:
     ```bash
     vainfo --display drm --device /dev/dri/renderD128
     ```
     Ensure `VAProfileH264High` is listed under supported profiles.
  2. Verify Nvidia VA-API driver is present:
     ```bash
     ls -l /usr/lib/x86_64-linux-gnu/dri/nvidia_drv_video.so
     ```
  3. Ensure required environment variables are exported before launch:
     ```bash
     export WEBKIT_FORCE_COMPOSITING_MODE=1
     export GST_VAAPI_ALL_DRIVERS=1
     export WEBKIT_DISABLE_DMABUF_RENDERER=0
     export LIBVA_DRIVER_NAME=nvidia
     export __GLX_VENDOR_LIBRARY_NAME=nvidia
     ```
  4. Ensure Chromium/WebKit flags are passed:
     ```bash
     --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiOnNvidiaGPUs --use-gl=egl --disable-software-rasterizer
     ```

### Issue 5: Stream FPS is 0 or Players Show "Connecting"
* **Symptom:** UI tiles remain on "Connecting", FPS badge shows `0 FPS`.
* **Diagnostic Steps:**
  1. **Test RTSP Feed Reachability:**
     ```bash
     nc -zv <RTSP_HOST> 8554
     ```
     If timed out, verify AWS Security Group permits inbound TCP 8554 from the benchmark instance.
  2. **Verify Stream Demuxer in GStreamer CLI:**
     ```bash
     gst-launch-1.0 rtspsrc location=rtsp://<RTSP_HOST>:8554/live protocols=tcp ! rtph264depay ! fakesink
     ```
  3. **Check WebSocket Control Logs:**
     Check `/var/log/benchmark/` or stdout for demuxer connection status:
     ```bash
     journalctl -u rtsp-benchmark-tauri-gpu.service | grep -E "Demuxer|Pipeline"
     ```

### Issue 6: Permission Denied on `/var/log/benchmark`
* **Symptom:** Logs appear in `./logs/` instead of `/var/log/benchmark/`.
* **Resolution:**
  ```bash
  sudo mkdir -p /var/log/benchmark
  sudo chown -R ubuntu:ubuntu /var/log/benchmark
  sudo chmod 777 /var/log/benchmark
  ```

### Issue 7: Xvfb Display Server Collisions
* **Symptom:** `Fatal server error: Server is already active for display 99`.
* **Resolution:**
  ```bash
  sudo rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
  sudo killall Xvfb 2>/dev/null || true
  ```
