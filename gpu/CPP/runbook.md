# Operations, Debugging & Troubleshooting Runbook (C++ Qt6 GPU Benchmark)

This runbook provides complete operational procedures for deploying, verifying, debugging, and diagnosing the 24-hour RTSP GPU Zero-Copy benchmark on AWS EC2 Ubuntu Linux using native C++, Qt6, and `libavcodec` hardware acceleration (CUDA / NVDEC / VA-API).

---

## 1. Quick Health Check (30-Second Verification)

Execute these checks on the benchmark box to verify that all 30 streams are actively decoding and rendering on the GPU:

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-cpp-gpu.service --no-pager
```
*Expected Output:* `Active: active (running)`.

### B. Verify Process Hierarchy & GPU Offload
```bash
# Verify C++ Qt6 binary, Xvfb virtual display, hardware poller, and NVIDIA state
pgrep -a rtsp-stress-test-cpp-gpu
pgrep -a Xvfb
pgrep -a poll_hardware.sh

# Query NVIDIA GPU decoder utilization (NVDEC ASIC)
nvidia-smi --query-gpu=utilization.decoder,utilization.gpu,memory.used --format=csv,nounits
```
*Expected Output:*
- `rtsp-stress-test-cpp-gpu` running with 30 background decoder threads.
- `Xvfb :0 -screen 0 2560x1440x24` active.
- `nvidia-smi` reports `utilization.decoder` > 40% and VRAM allocated without spilling into system RAM.

### C. Verify Log Generation
```bash
ls -lh /var/log/benchmark/
```
*Expected Output:* Both `fps_metrics.log` and `hardware_metrics.csv` exist, are non-empty, and are updating continuously.

---

## 2. Live Telemetry & Metric Monitoring

### A. Monitor 60-Second FPS Time-in-State Windows
```bash
tail -f /var/log/benchmark/fps_metrics.log
```
*Success Criterion:* In every 60-second window, the vast majority of the 1,800 stream-seconds (30 streams × 60s) should reside in `acceptable.25_to_30_fps`.

#### Analyze Telemetry with `jq`:
```bash
cat /var/log/benchmark/fps_metrics.log | jq -s '
  map({
    timestamp: .timestamp,
    acc_25_30: .fps_stream_seconds.acceptable["25_to_30_fps"],
    acc_20_24: .fps_stream_seconds.acceptable["20_to_24_fps"],
    unacc_10_19: .fps_stream_seconds.unacceptable["10_to_19_fps"],
    unacc_under_5: .fps_stream_seconds.unacceptable["under_5_fps"]
  })'
```

### B. Monitor 10-Second Hardware Utilization
```bash
tail -f /var/log/benchmark/hardware_metrics.csv
```
*Expected Target Values on AWS EC2 `g6.xlarge` (NVIDIA L4) / `g4dn.xlarge` (NVIDIA T4):*
- **CPU %:** < 20% (NVDEC hardware ASIC handles decoding, GPU fragment shaders handle color conversion)
- **RAM RSS:** < 600 MB (Zero-copy VRAM texture mapping avoids CPU memory allocation)
- **GPU VRAM:** ~3,000–4,500 MB (Textures allocated directly in GPU memory)
- **GPU Decoder:** 60%–85%

---

## 3. Common Failure Modes & Diagnostics

### Issue 1: "Could not initialize device type cuda / vaapi"
- **Symptom:** Application logs warning: `Could not initialize device type cuda. Falling back to GPU-shaded direct rendering.`
- **Cause:** NVIDIA proprietary driver or CUDA runtime is missing, or user lacks access to `/dev/nvidia*` or `/dev/dri/renderD128`.
- **Remedy:**
  ```bash
  # Check if NVIDIA driver is loaded
  nvidia-smi
  
  # Ensure user is in render and video groups
  sudo usermod -a -G render,video $USER
  ```

### Issue 2: Font Warning or Blank/Misaligned HUD Text
- **Symptom:** Terminal outputs `qt.qpa.fonts: Populating font family aliases...` or text appears broken.
- **Cause:** CSS-only pseudo font names (like `-apple-system`) missing on Linux/Xvfb.
- **Resolution:** The implementation relies on native `QApplication::font()` and style hints (`QFont::SansSerif`) with bounded text rects (`Qt::AlignVCenter`), preventing font fallback penalties.

### Issue 3: Socket Exhaustion (`EMFILE: Too many open files`)
- **Symptom:** Decoder threads fail to open RTSP sockets after stream 15–20.
- **Cause:** OS per-process file descriptor limit default (`ulimit -n 1024`).
- **Remedy:** The application automatically raises `RLIMIT_NOFILE` to `10240` at `main()`. The systemd service unit also configures `LimitNOFILE=65536`.

### Issue 4: RTSP Server "Reader is too slow, discarding frames"
- **Symptom:** MediaMTX logs indicate dropped packets during the first 500ms of startup.
- **Remedy:** Ensure `mediamtx.yml` specifies:
  ```yaml
  readBufferCount: 8192
  writeQueueSize: 8192
  ```
  The C++ Qt6 GPU application staggers thread connection startup by 20ms per stream to prevent TCP socket stampedes.

### Issue 5: Telemetry Reports Unacceptable Buckets on Headless Linux
- **Symptom:** `fps_metrics.log` records counts in `10_to_19_fps` or `<5_fps` instead of `25_to_30_fps`.
- **Diagnostic Steps:**
  1. Verify the RTSP stream generation rate on Box A:
     ```bash
     ffmpeg -i rtsp://<rtsp-host>:8554/live -f null -
     ```
     Ensure ffmpeg reports `fps=25` and `speed=1.0x`.
  2. Verify that NVIDIA hardware acceleration is active:
     ```bash
     journalctl -u rtsp-benchmark-cpp-gpu.service -n 50 | grep HwAccel
     ```
     Should output: `[HwAccel] Successfully initialized GPU hardware acceleration: cuda`.
  3. Verify Xvfb virtual resolution:
     Ensure Xvfb is running with `-screen 0 2560x1440x24` so Qt's window manager can size the grid cleanly.
  4. Inspect CPU and GPU utilization:
     ```bash
     nvidia-smi --query-gpu=utilization.decoder,memory.used --format=csv -l 2
     ```
     NVDEC should show steady ~65–85% utilization across all 30 1440p streams.

---

## 4. Manual Headless Test Run (Pre-Flight Verification)

Before enabling the 24-hour systemd daemon, run the headless benchmark interactively for 2 minutes to inspect output:
```bash
cd /opt/rtsp-stress-test/gpu/CPP

# Run with Xvfb on display :99
xvfb-run -a -s "-screen 0 2560x1440x24" ./build/rtsp-stress-test-cpp-gpu \
  --url rtsp://127.0.0.1:8554/live \
  --streams 30 \
  --hw-accel cuda \
  --log-dir /var/log/benchmark
```
*Expected Console Output:*
```text
=================================================================
 24-Hour RTSP Video Grid Benchmark (C++ Qt6 GPU Zero-Copy Decode)
=================================================================
 Target RTSP URL:       rtsp://127.0.0.1:8554/live
 Active Streams:        30
 Telemetry Output:      /var/log/benchmark/fps_metrics.log
 Machine ID:            c7i-8xlarge-node-1
 Requested HwAccel:     cuda
 Active GPU Device:     cuda
 Rendering Pipeline:    QOpenGLWidget + BT.709 GPU NV12 Shaders
 UI Refresh Rate:       30 FPS
 Zero-Copy VRAM Rule:   Active (zero CPU RAM frame download)
=================================================================
[MainWindow] Starting 30 background RTSP GPU decoder threads...
[MainWindow] All GPU decoder threads started successfully.
[Telemetry] Flushed 60s window (1800 stream-seconds) to /var/log/benchmark/fps_metrics.log
            Acceptable (25-30: 1800, 20-24: 0) | Unacceptable (10-19: 0, 5-9: 0, <5: 0)
```

---

## 5. Benchmark Pass/Fail Criteria

An evaluation run is disqualified if any of these conditions persist for > 5 minutes:
- **Total Host CPU Usage:** > 85%
- **GPU 3D Engine Usage:** > 80%
- **GPU VRAM Allocation:** > 90% (Spilling into system RAM)
- **GPU Decoder (NVDEC):** > 90%
- **Acceptable Stream-Seconds:** Below 95% of total stream-seconds in a 60-second window.

---

## 6. Post-Benchmark Log Retrieval & Analysis

When the 24-hour run finishes, export the telemetry and hardware metrics:
```bash
# Verify total stream-seconds accumulated (30 streams * 86,400s = 2,592,000 stream-seconds)
grep -c "timestamp" /var/log/benchmark/fps_metrics.log

# Compute total acceptable vs unacceptable percentage
python3 -c "
import json

total_25_30 = 0
total_20_24 = 0
total_unacceptable = 0

with open('/var/log/benchmark/fps_metrics.log') as f:
    for block in f.read().strip().split('\n\n'):
        if not block.strip(): continue
        try:
            d = json.loads(block)
            acc = d.get('fps_stream_seconds', {}).get('acceptable', {})
            unacc = d.get('fps_stream_seconds', {}).get('unacceptable', {})
            total_25_30 += acc.get('25_to_30_fps', 0)
            total_20_24 += acc.get('20_to_24_fps', 0)
            total_unacceptable += sum(unacc.values())
        except Exception:
            pass

total = total_25_30 + total_20_24 + total_unacceptable
print(f'Total Stream-Seconds Analyzed: {total}')
print(f'Acceptable 25-30 FPS: {total_25_30} ({total_25_30/total*100:.2f}%)')
print(f'Acceptable 20-24 FPS: {total_20_24} ({total_20_24/total*100:.2f}%)')
print(f'Unacceptable <20 FPS:  {total_unacceptable} ({total_unacceptable/total*100:.2f}%)')
"
```
