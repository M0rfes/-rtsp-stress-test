# 30-Camera RTSP Video Grid Benchmark (Rust Tauri CPU Software Decode)

This implementation fulfills the **CPU-Only (Software Decoding)** benchmark specification for Rust Tauri from the root `README.md`, `BENCHMARK_FINDINGS.md` §9.0, and `cpu/Rust-Tauri/prompt.md`.

`src-tauri/src/platform.rs` raises `RLIMIT_NOFILE` and applies CPU WebView env (Linux software GL only). `VideoPlayer.tsx` uses `prefer-software` and tile-sized blit on macOS.

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
│  30 × GStreamer Demuxers (`gstreamer-rs`):                                  │
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
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ Local WS IPC (Zero Tauri invoke overhead)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ React Frontend (Tauri WebView)                                              │
│                                                                             │
│  Software Fallback Enforcement:                                             │
│   ├── `WEBKIT_DISABLE_COMPOSITING_MODE=1` & `LIBGL_ALWAYS_SOFTWARE=1`       │
│   └── WebCodecs `VideoDecoder` configured with `prefer-software`            │
│                                                                             │
│  Rendering: HTML5 Canvas 2D (`ctx.drawImage`) with immediate frame disposal │
│  UI Grid: Responsive 30-tile CSS Grid (6 columns × 5 rows)                  │
│  Decoupled State: Mutable frame counters in refs, direct DOM HUD updates    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1. Rust Backend (`src-tauri`)
- **GStreamer Demuxing (`gstreamer-rs`):**
  - Spawns 30 lightweight demuxer pipelines using `gstreamer-app::AppSink`.
  - Pipeline: `rtspsrc location=... protocols=tcp latency=0 drop-on-latency=true ! rtph264depay ! h264parse config-interval=-1 ! video/x-h264,stream-format=avc,alignment=au ! appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false`.
  - **Native C AVCC Formatting:** With GStreamer's `stream-format=avc,alignment=au`, GStreamer formats 4-byte length-delimited AVCC NAL units directly in C and provides `codec_data` (extradata) on caps. This completely eliminates the need for expensive byte-scanning loops in JavaScript.
  - **Low-Latency Channel Backpressure:** Channel capacity is tuned to 8 frames (~320ms buffer), ensuring instantaneous frame delivery and shedding stale frames under backpressure.
  - **Zero CPU Decode in Rust:** The backend strictly depayloads and demuxes, leaving CPU decoding to the frontend software decoders.

### 2. High-Throughput Zero-Copy WebSocket IPC (`ws_server.rs`)
- **Avoid Tauri IPC Bottlenecks:** Passing 750 uncompressed frames/second across standard Tauri `invoke()` or `window.emit()` serializes JSON or WebKit IPC messages and chokes at ~50 FPS aggregate.
- **Tokio WebSocket Server:** Built with `tokio-tungstenite` listening on `127.0.0.1:9999`.
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

### 3. React Frontend & Software Fallback (`src`)
- **WebCodecs Software Decoding:**
  - Each player tile initializes a native `VideoDecoder`.
  - Configured with `hardwareAcceleration: 'prefer-software'` and native GStreamer AVCC description (`avc1.42c032`).
  - Software rendering environment variables (`WEBKIT_DISABLE_COMPOSITING_MODE=1`, `LIBGL_ALWAYS_SOFTWARE=1`) ensure WebKitGTK operates in pure software mode without GPU compositor offload.
- **Rendering via `ImageBitmapRenderingContext`:**
  - Decoded frames are converted via `createImageBitmap(videoFrame)` and handed directly to the canvas compositor using `bitmapCtx.transferFromImageBitmap(bitmap)`.
  - Bypasses Canvas 2D software blitting bottlenecks and resolves WebKit `VideoFrame` draw limitations.
  - `videoFrame.close()` and `bitmap.close()` are called synchronously on every painted frame to guarantee zero VRAM or RAM accumulation.
- **UI Thread Starvation Prevention:**
  - Video decoding and painted frame counting bypass React state entirely (tracked via mutable `useRef`).
  - Player overlays update via direct DOM element mutation.
  - Master 1-second interval collects painted counts and synchronizes with the Rust backend telemetry manager.

### 4. Dual Telemetry Specification Adherence
- **Internal Time-in-State (`fps_metrics.log`):**
  - Categorizes stream frame rates into performance buckets every second:
    - **Acceptable:** `25_to_30_fps`, `20_to_24_fps`
    - **Unacceptable:** `10_to_19_fps`, `5_to_9_fps`, `under_5_fps`
  - Flushes exact JSON schema every 60 seconds (1,800 stream-seconds) to `/var/log/benchmark/fps_metrics.log` (with graceful fallback to `./logs/fps_metrics.log`).
- **External OS Polling (`hardware_metrics.csv`):**
  - `scripts/poll_hardware.sh` polls CPU % and RAM RSS MB every 10 seconds.
  - Columns: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`.

---

## Quickstart (Local Development & Testing)

### 1. Prerequisites
- **Rust Toolchain:** `rustc >= 1.92` (Install via `rustup update`)
- **Node.js:** Node.js >= 18 (Tested on Node 22/25)
- **GStreamer:**
  - macOS: `brew install gstreamer ffmpeg mediamtx`
  - Linux (Ubuntu): `sudo apt install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav libwebkit2gtk-4.1-dev ffmpeg`

### 2. Start the Local RTSP Test Feed (1440p 25 FPS)
In a dedicated terminal:
```bash
npm run rtsp:feed
```
This runs MediaMTX and publishes a 2560×1440 25 FPS test pattern to `rtsp://127.0.0.1:8554/live`.

### 3. Run the Tauri Application in Development Mode
```bash
npm run dev
```

### 4. Build for Release
```bash
npm run build
```
The compiled release binary is located at:
`src-tauri/target/release/rtsp-stress-test-tauri-cpu`

---

## Running on Headless Linux (AWS EC2 / Ubuntu via Xvfb)

### 1. Provision EC2 Instance
Run the automated user data script:
```bash
sudo ./scripts/ec2_userdata.sh
source "$HOME/.cargo/env"
```

### 2. Compile Release Binary
```bash
npm install
npm run build
```

### 3. Execute 6-Hour Benchmark (Standalone)
```bash
# Optional: specify remote RTSP URL or stream count
export RTSP_URL="rtsp://10.0.1.50:8554/live"
export STREAM_COUNT=30

./scripts/run_benchmark_headless.sh
```
This launches the benchmark application inside an Xvfb virtual display (`2560x1440x24`), starts external hardware polling, and logs all telemetry.

### 4. Configure 6-Hour Automated Systemd Daemon
To ensure the benchmark survives SSH disconnects and restarts automatically on reboot:
```bash
sudo ./scripts/setup_autostart.sh
```
* **Verify Service Status:** `sudo systemctl status rtsp-benchmark-tauri-cpu`
* **Tail Service Logs:** `journalctl -u rtsp-benchmark-tauri-cpu -f`
* **Stop Service:** `sudo systemctl stop rtsp-benchmark-tauri-cpu`

### 5. Live Telemetry Monitoring
```bash
# Monitor internal FPS performance buckets
tail -f /var/log/benchmark/fps_metrics.log

# Monitor external CPU and RAM utilization
tail -f /var/log/benchmark/hardware_metrics.csv
```
