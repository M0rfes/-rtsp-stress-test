# 30-Camera RTSP Video Grid Benchmark (Rust Tauri GPU Zero-Copy Hardware Decode)

This implementation fulfills the **GPU-Accelerated (Zero-Copy)** benchmark specification for Rust Tauri from the root `README.md`, `BENCHMARK_FINDINGS.md`, and `gpu/Rust-Tauri/prompt.md`.

## Architecture Overview

```
                          ┌────────────────────────┐
                          │  MediaMTX RTSP Server  │
                          │   (1440p @ 25 FPS)     │
                          └───────────┬────────────┘
                                      │ TCP (30 streams)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Rust Backend (src-tauri)                                                    │
│                                                                             │
│  30 × GStreamer Demuxers (`gstreamer-rs` + `gstreamer-rtsp-server`):       │
│   rtspsrc ! rtph264depay ! h264parse ! alignment=au ! appsink               │
│   ├── Assemble multi-slice NALs into complete Access Units (AUs)            │
│   ├── SPS/PPS caching (guarantees [SPS][PPS][IDR] on every keyframe)        │
│   └── Microsecond timestamp generation                                      │
│                                                                             │
│  Tokio WebSocket Server (`tokio-tungstenite` on 127.0.0.1:9999):            │
│   ├── `/stream/:id` -> High-throughput binary frame streaming               │
│   └── `/control`    -> Bidirectional HUD telemetry & 1s tick synchronization│
│                                                                             │
│  Telemetry Manager:                                                         │
│   ├── 1-Second performance bucket aggregation                               │
│   └── 60-Second rolling window flush to `/var/log/benchmark/fps_metrics.log`│
│                                                                             │
│  Launch Flags & WebKitGTK Hardware Acceleration:                            │
│   ├── `WEBKIT_FORCE_COMPOSITING_MODE=1` & `GST_VAAPI_ALL_DRIVERS=1`         │
│   ├── `LIBVA_DRIVER_NAME=nvidia` & `__GLX_VENDOR_LIBRARY_NAME=nvidia`       │
│   └── WebKitGTK Settings: hardware acceleration policy = Always             │
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ Local WS IPC (Zero Tauri invoke overhead)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ React Frontend (Tauri WebView)                                              │
│                                                                             │
│  Hardware Decode via Native WebCodecs:                                      │
│   ├── `VideoDecoder` configured with `hardwareAcceleration: 'prefer-hardware'`│
│   └── Dynamic profile/level extraction (`avc1.42c032` for 1440p Level 5.0+) │
│                                                                             │
│  Zero-Copy GPU Rendering:                                                   │
│   ├── `OffscreenCanvas` with `bitmaprenderer` context                       │
│   ├── `createImageBitmap(videoFrame)` keeps decoded frames in VRAM          │
│   └── `transferFromImageBitmap(bitmap)` swaps texture with zero CPU copies  │
│                                                                             │
│  UI Grid: Responsive 30-tile CSS Grid (6 columns × 5 rows)                  │
│  Decoupled State: Mutable frame counters in refs, direct DOM HUD updates    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Technical Constraints & Architecture Implementation

### 1. Rust Backend Demuxer (`src-tauri/src/demuxer.rs`)
- **GStreamer Demuxing (`gstreamer-rs` + `gstreamer-rtsp-server`):**
  - Spawns 30 lightweight demuxer pipelines using `gstreamer-app::AppSink`.
  - Links and references `gstreamer-rtsp-server` for RTSP server and protocol support.
  - Pipeline:
    ```text
    rtspsrc location=... protocols=tcp latency=0 drop-on-latency=true !
    rtph264depay !
    h264parse config-interval=-1 !
    video/x-h264,stream-format=avc,alignment=au !
    appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false
    ```
  - **Native C AVCC Formatting:** Formats 4-byte length-delimited AVCC NAL units in C and emits `codec_data` (extradata) on caps, avoiding costly byte scanning in JavaScript.
  - **Low-Latency Channel Backpressure:** Broadcast buffer is limited to 8 frames (~320ms buffer), ensuring instantaneous frame delivery and shedding stale frames under load.

### 2. High-Throughput Zero-Copy WebSocket IPC (`src-tauri/src/ws_server.rs`)
- **Zero Tauri Invoke Overhead:** Video payloads bypass Tauri's native `invoke()` commands entirely, eliminating IPC serialization bottlenecks.
- **Tokio WebSocket Server:** Built with `tokio-tungstenite` listening on `127.0.0.1:9999` (configurable via `WS_PORT`).
- **Zero-Copy Payload Distribution:** Broadcast channels utilize `bytes::Bytes`. Transmitting binary WebSocket frames requires zero heap copying.
- **Binary Frame Format (`/stream/:id`):**
  - Byte 0: `isKey` (`1` = keyframe/IDR, `0` = delta frame)
  - Bytes 1..8: `timestampUs` (Big-Endian `u64` microsecond timestamp)
  - Bytes 9..10: `descLen` (Big-Endian `u16` length of AVCC description/extradata)
  - Bytes 11..11+descLen: AVCC `codec_data` (extradata used to configure `VideoDecoder`)
  - Remaining bytes: Raw AVCC 4-byte length-delimited Access Unit data
- **Control Channel (`/control`):**
  - Sends initial benchmark parameters (`streamCount`, `machineId`, `logPath`, etc.).
  - Receives `tick_fps` arrays from React every 1 second.
  - Broadcasts live telemetry updates to the HUD.

### 3. React Frontend & Zero-Copy GPU Rendering (`src/components/VideoPlayer.tsx`)
- **Native WebCodecs Hardware Decoding:**
  - Each player tile initializes a native `VideoDecoder`.
  - Configured with `hardwareAcceleration: 'prefer-hardware'` to mandate GPU hardware decoding.
  - Dynamically extracts codec profile and level from the AVCC description (e.g. `avc1.42c032`).
- **Zero-Copy GPU Presentation via `OffscreenCanvas` & `BitmapRenderer`:**
  - Standard Canvas 2D `drawImage(videoFrame, ...)` forces an expensive CPU readback / conversion before re-uploading to the compositor.
  - In this implementation, the canvas control is transferred to an `OffscreenCanvas` with `bitmaprenderer` context (`ImageBitmapRenderingContext`).
  - `createImageBitmap(videoFrame)` produces a hardware-backed bitmap in VRAM, which is handed directly to the canvas swapchain via `bitmapCtx.transferFromImageBitmap(bitmap)`.
  - Decoded frames remain in GPU memory throughout decoding, color-conversion, and display presentation.
  - `videoFrame.close()` and `bitmap.close()` are called synchronously on every painted frame to guarantee zero VRAM leakage.
- **UI Thread Starvation Prevention:**
  - Video decoding and painted frame counting bypass React state entirely (tracked via mutable `useRef`).
  - Player overlays update via direct DOM element mutation.
  - Master 1-second interval collects painted counts and synchronizes with the Rust backend telemetry manager.

### 4. WebKitGTK / Chromium Launch Flags & VA-API Configuration (`src-tauri/src/lib.rs`)
- On Linux, WebKitGTK and Chromium WebView initialization is configured with hardware acceleration flags:
  - Environment variables set before webview startup:
    - `WEBKIT_FORCE_COMPOSITING_MODE=1`
    - `GST_VAAPI_ALL_DRIVERS=1`
    - `WEBKIT_DISABLE_DMABUF_RENDERER=0`
    - `LIBVA_DRIVER_NAME=nvidia` (when Nvidia VA-API driver is present)
    - `__GLX_VENDOR_LIBRARY_NAME=nvidia`
  - WebKitGTK Settings configured in Rust:
    - `settings.set_enable_webgl(true)`
    - `settings.set_enable_accelerated_2d_canvas(true)`
    - `settings.set_hardware_acceleration_policy(webkit2gtk::HardwareAccelerationPolicy::Always)`
  - Headless launch script passes VA-API translation flags:
    - `--enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiOnNvidiaGPUs`
    - `--use-gl=egl`
    - `--disable-software-rasterizer`
    - `--no-sandbox`
    - `--disable-dev-shm-usage`

### 5. Dual Telemetry Specification Adherence
- **Internal Time-in-State (`fps_metrics.log`):**
  - Categorizes stream frame rates into performance buckets every second:
    - **Acceptable:** `25_to_30_fps`, `20_to_24_fps`
    - **Unacceptable:** `10_to_19_fps`, `5_to_9_fps`, `under_5_fps`
  - Flushes exact JSON schema every 60 seconds (1,800 stream-seconds) to `/var/log/benchmark/fps_metrics.log` (with graceful fallback to `./logs/fps_metrics.log`).
- **External OS Polling (`hardware_metrics.csv`):**
  - `scripts/poll_hardware.sh` polls CPU %, RAM RSS MB, GPU VRAM MB, and GPU Decoder % every 10 seconds.
  - Uses `nvidia-smi` to log GPU metrics: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`.

---

## Quickstart (Local Development & Testing)

### 1. Prerequisites
- **Rust Toolchain:** `rustc >= 1.90` (Install via `rustup update`)
- **Node.js:** Node.js >= 18 (Tested on Node 22)
- **GStreamer:**
  - macOS: `brew install gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-rtsp-server mediamtx ffmpeg`
  - Ubuntu/Debian: `sudo ./scripts/ec2_userdata.sh`

### 2. Install Frontend Dependencies
```bash
npm install
```

### 3. Start Local MediaMTX RTSP Server (Optional for standalone testing)
```bash
npm run rtsp:feed
```

### 4. Run Development Mode
```bash
npm run dev
```

### 5. Build Release Binary
```bash
npm run build
```
The optimized executable is generated at:
`src-tauri/target/release/rtsp-stress-test-tauri-gpu`

---

## Headless Linux (AWS EC2) 24-Hour Benchmark Deployment

### 1. Recommended EC2 Instance
- **Instance Type:** `g6.xlarge` (NVIDIA L4 GPU) or `g4dn.xlarge` (NVIDIA T4 GPU).
- **OS:** Ubuntu 24.04 LTS or 22.04 LTS AMD64.

### 2. System Provisioning
Execute the automated user-data provisioner:
```bash
sudo ./scripts/ec2_userdata.sh
source "$HOME/.cargo/env"
```

### 3. Run Benchmark Headless Under Xvfb
```bash
# Optional: specify remote RTSP URL and stream count
export RTSP_URL="rtsp://10.0.1.50:8554/live"
export STREAM_COUNT=30

./scripts/run_benchmark_headless.sh
```

### 4. Setup 24-Hour Systemd Daemon
To ensure the benchmark survives SSH disconnects and restarts automatically on reboot:
```bash
sudo ./scripts/setup_autostart.sh
```
- **Check status:** `sudo systemctl status rtsp-benchmark-tauri-gpu`
- **Tail logs:** `journalctl -u rtsp-benchmark-tauri-gpu -f`
- **Stop service:** `sudo systemctl stop rtsp-benchmark-tauri-gpu`

### 5. Monitor Benchmark Telemetry
```bash
# Monitor 60-second FPS performance buckets:
tail -f /var/log/benchmark/fps_metrics.log

# Monitor 10-second external CPU / RAM / GPU utilization:
tail -f /var/log/benchmark/hardware_metrics.csv
```
