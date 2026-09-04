# Operations, Debugging & Troubleshooting Runbook (Rust Iced GPU Benchmark)

This runbook provides procedures for monitoring, verifying, debugging, and troubleshooting the 6-hour RTSP GPU Zero-Copy benchmark running under systemd or headless CLI on AWS EC2 Ubuntu Linux (`g6.xlarge` / `g4dn.xlarge` with NVIDIA GPU) using pure Rust, `iced_wgpu`, and GStreamer NVDEC.

---

## 1. Quick Health Check (30-Second Verification)

Run these checks to confirm the benchmark is actively decoding 30 streams via GPU:

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-iced-gpu.service --no-pager
```
*Expected Output:* `Active: active (running)`.

### B. Verify Process Hierarchy & GPU Activity
```bash
# Verify Rust Iced binary, Xvfb, and hardware poller are running
pgrep -a rtsp-stress-test-iced-gpu
pgrep -a Xvfb
pgrep -a poll_hardware.sh

# Verify NVIDIA NVDEC hardware utilization
nvidia-smi --query-gpu=utilization.decoder,memory.used --format=csv
```
*Expected Output:* `utilization.decoder` should read > 40-75%, confirming active hardware video decoding on the GPU ASIC.

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
*Headroom Criterion:* CPU utilization should remain strictly `< 15-25%` because NVDEC and WGPU shaders execute all heavy lifting.

---

## 3. Headroom Pass/Fail Evaluation Rules

According to the project specification, an implementation **FAILS** if it violates any of the following conditions for more than 5 consecutive minutes:

| Metric | Fail Threshold | Verification Command |
| :--- | :--- | :--- |
| **Total CPU Usage** | **> 85% sustained** | `tail -n 30 /var/log/benchmark/hardware_metrics.csv \| awk -F',' '{print $3}'` |
| **GPU 3D Engine** | **> 80% sustained** | `nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader` |
| **GPU VRAM Allocation**| **> 90% sustained** | `nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader` |
| **GPU Decoder (NVDEC)**| **> 90% sustained** | `nvidia-smi --query-gpu=utilization.decoder --format=csv,noheader` |
| **Stream FPS** | **< 20 FPS sustained** | Check `unacceptable` buckets in `fps_metrics.log` |

---

## 4. Troubleshooting Playbook

### Issue 1: "Too many open files" / GLib GWakeup Pipe Error
* **Symptom:** App terminates on startup with `GLib-ERROR: Creating pipes for GWakeup: Too many open files`.
* **Fix:** The app raises `RLIMIT_NOFILE` automatically to `10240` in `main.rs`. If running via systemd, verify `LimitNOFILE=65536` in `rtsp-benchmark-iced-gpu.service`.

### Issue 2: NVIDIA NVDEC Not Found on Linux
* **Symptom:** Logs report `no element "nvdec"`.
* **Fix:**
  ```bash
  sudo apt-get install -y gstreamer1.0-plugins-bad nvidia-headless-535
  gst-inspect-1.0 nvdec
  ```

### Issue 3: WGPU Shader Backend Initialization on Linux
* **Symptom:** WGPU reports surface initialization errors under headless Xvfb.
* **Fix:** Ensure launch scripts pass `WGPU_BACKEND=gl` and run with `xvfb-run -a -s "-screen 0 2560x1440x24"`.

### Issue 4: Direct3D 11 Acceleration on Windows
* **Symptom:** Windows reports `avdec_h264` software decoding instead of hardware acceleration.
* **Fix:** Ensure GStreamer MSVC binaries with Direct3D 11 plugins (`d3d11h264dec`) are installed and on `PATH`. The auto-detector in `config.rs` will automatically select `d3d11h264dec`.

### Issue 5: macOS VideoToolbox NV12 Dual-Plane Shaders
* **Symptom:** Video tiles render black or purple artifacts during window resizing.
* **Fix:** The app dynamically manages $Y$ (`R8Unorm`) and $UV$ (`Rg8Unorm`) texture dimensions in `shader.rs`. Recreating the textures occurs automatically when caps change without dropping stream connections.
