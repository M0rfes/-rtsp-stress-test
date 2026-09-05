# 30-Camera RTSP Video Grid Benchmark (Rust Iced CPU Software Decode)

This implementation fulfills the **CPU-Only (Software Decoding)** benchmark specification for Rust Iced from the root [README.md](../../README.md), [BENCHMARK_FINDINGS.md](../../BENCHMARK_FINDINGS.md) §9.0, and [cpu/Rust-Iced/prompt.md](prompt.md).

`src/platform.rs`: `NOFILE_TARGET=10240`, `STREAM_STAGGER_MS=20`.

## Architecture Overview

```
                          ┌────────────────────────┐
                          │  MediaMTX RTSP Server  │
                          │   (1440p @ 25 FPS)     │
                          └───────────┬────────────┘
                                      │ TCP (30 streams)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Rust Backend & Worker Threads                                               │
│                                                                             │
│  30 × Dedicated RTSP Decoders (`gstreamer-rs`):                             │
│   rtspsrc ! rtph264depay ! h264parse ! avdec_h264 ! I420 ! appsink          │
│   ├── Pure CPU software decoding via `avdec_h264` (libavcodec wrapper)      │
│   ├── Jitterbuffer latency=50ms to prevent packet drops on high load        │
│   └── Auto-reconnection on network drops or stream interruption             │
│                                                                             │
│  Color Conversion (SIMD on background threads):                             │
│   ├── `yuv::yuv420_to_rgba` using AVX2 / SSE4.1 / ARM NEON instructions     │
│   └── Direct SIMD transformation into pre-allocated memory buffers          │
│                                                                             │
│  Lock-Free Frame Handoff:                                                   │
│   ├── Pre-allocated uncompressed RGB allocations in `Arc<RwLock<Vec<u8>>>` │
│   ├── `ArcSwap<Option<Arc<FrameData>>>` for atomic, wait-free pointer swaps │
│   └── Atomic counters (`AtomicU64`, `AtomicU32`) for decoupled metrics      │
│                                                                             │
│  Telemetry Manager:                                                         │
│   ├── 1-Second performance bucket aggregation                               │
│   └── 60-Second rolling window flush to `/var/log/benchmark/fps_metrics.log`│
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ Lock-free atomic load (Zero UI contention)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Iced Native GUI Frontend                                                    │
│                                                                             │
│  Rendering Backend:                                                         │
│   └── `tiny-skia` software rasterization (`iced --features tiny-skia`)      │
│                                                                             │
│  UI Grid:                                                                   │
│   ├── Responsive 30-tile layout (6 columns × 5 rows)                        │
│   ├── Real-time per-tile HUD (Camera label, resolution, color-coded FPS)   │
│   └── Master top dashboard (Streams, aggregate FPS, 60s countdown, buckets) │
│                                                                             │
│  Decoupled UI Loop:                                                         │
│   ├── 30 FPS RenderTick: loads latest frames atomically without locks       │
│   └── 1 FPS TelemetryTick: synchronizes metrics and writes to disk          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architectural Principles & Constraints

### 1. Pure CPU Software Decoding (`decoder.rs`)
- Each RTSP stream is processed by a dedicated OS worker thread running a `gstreamer-rs` pipeline:
  ```text
  rtspsrc location="{url}" protocols=tcp latency=50 drop-on-latency=false ! \
  rtph264depay ! \
  h264parse ! \
  avdec_h264 output-corrupt=false max-threads=1 ! \
  video/x-raw,format=I420 ! \
  appsink name=sink sync=false max-buffers=2 drop=true emit-signals=false
  ```
- **CPU Software Decode:** `avdec_h264` forces CPU software decoding via FFmpeg's libavcodec, strictly preventing any GPU/hardware decoding offload.
- **Latency & Backpressure:** A 50ms jitterbuffer ensures RTP stability under heavy multi-stream load, while `max-buffers=2 drop=true` prevents latency accumulation.

### 2. SIMD YUV-to-RGB Color Conversion
- Decoded raw `I420` (YUV420p) planar video frames are converted to 32-bit RGBA on the background threads before reaching the UI.
- The conversion uses the `yuv` crate (`yuv::yuv420_to_rgba`), which dynamically utilizes CPU SIMD extensions:
  - **x86_64:** AVX2 and SSE4.1 vector instructions
  - **AArch64:** ARM NEON vector instructions
- Zero color conversion work is performed on the UI rendering thread.

### 3. Lock-Free Frame Handoff (`ArcSwap` & `Arc<RwLock<[u8]>>`)
- Wrapping massive uncompressed 1440p video frames (14.7 MB per frame) in a standard `std::sync::Mutex` causes catastrophic lock contention when 30 threads write 750 frames/second against an active UI thread.
- **Handoff Architecture:**
  - Raw uncompressed buffer allocations are held in `Arc<RwLock<Vec<u8>>>`.
  - Frame pointers are stored via `ArcSwap<Option<Arc<FrameData>>>`.
  - The decoder thread writes a frame and performs an atomic pointer swap.
  - The Iced UI thread loads the pointer via `slot.get_current_frame()`, which is an atomic, wait-free read.
  - No lock contention, no UI thread pauses, and zero Mutex stalls.

### 4. `tiny-skia` Software Rendering Backend
- The `iced` dependency in `Cargo.toml` explicitly enables `tiny-skia` while disabling `wgpu`:
  ```toml
  iced = { version = "0.14", default-features = false, features = ["tiny-skia", "image", "tokio", "crisp", "x11", "wayland"] }
  ```
- This forces Iced to use CPU software rasterization via `tiny-skia` and `softbuffer` to blit pixel buffers directly to the OS window manager.

### 5. UI Thread Starvation Prevention
- **Decoupled Render Loop:** The Iced UI does *not* process reactive messages for each decoded frame (which would trigger 750 events/second and flood the event queue).
- Instead, the UI subscribes to two distinct timers:
  - `RenderTick` (~30 Hz): Renders the latest available frame from each stream's `ArcSwap` slot.
  - `TelemetryTick` (1 Hz): Aggregates painted frame counts from atomic counters, updates HUD state, and flushes rolling windows.

---

## Dual Telemetry Specification Adherence

### 1. Internal Time-in-State (`fps_metrics.log`)
- Every 1 second, the application checks painted frame counts for each of the 30 streams and categorizes them into performance buckets:
  - **Acceptable:** `25_to_30_fps`, `20_to_24_fps`
  - **Unacceptable:** `10_to_19_fps`, `5_to_9_fps`, `under_5_fps`
- Every 60 seconds (1,800 stream-seconds accumulated), it appends the JSON payload to `/var/log/benchmark/fps_metrics.log` (with fallback to `./logs/fps_metrics.log`):

```json
{
  "timestamp": "2026-09-04T12:05:00Z",
  "machine_id": "c7i-8xlarge-node-1",
  "framework": "rust_iced",
  "hardware_mode": "cpu",
  "window_duration_seconds": 60,
  "active_streams": 30,
  "fps_stream_seconds": {
    "acceptable": {
      "25_to_30_fps": 1785,
      "20_to_24_fps": 15
    },
    "unacceptable": {
      "10_to_19_fps": 0,
      "5_to_9_fps": 0,
      "under_5_fps": 0
    }
  }
}
```

### 2. External OS Hardware Polling (`hardware_metrics.csv`)
- `scripts/poll_hardware.sh` runs as a separate background process, polling the OS every 10 seconds:
  ```csv
  timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent
  2026-09-04T12:05:00Z,4432,68.2,2840,0,0
  2026-09-04T12:05:10Z,4432,67.8,2845,0,0
  ```
- In CPU benchmarks, GPU fields remain `0`.

---

## Quickstart (Local Development & Testing)

### 1. Prerequisites
- **Rust Toolchain:** `rustc >= 1.88` (Recommended: `rustup update`)
- **GStreamer:**
  - macOS: `brew install gstreamer ffmpeg`
  - Ubuntu / Debian: `sudo apt install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-tools libx11-dev libxcursor-dev libxrandr-dev libxi-dev libxkbcommon-dev libwayland-dev ffmpeg xvfb`

### 2. Start the shared RTSP server
From the repo root:
```bash
./rtsp-server/start.sh
```
Serves `rtsp://127.0.0.1:8554/live` for all 10 clients (300 TCP readers).

### 3. Run in Development Mode
```bash
cargo run
```

### 4. Build Optimized Release Binary
```bash
cargo build --release
```
The executable is produced at:
`target/release/rtsp-stress-test-iced-cpu`

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
cargo build --release
```

### 3. Execute 6-Hour Benchmark (Standalone)
```bash
# Optional environment overrides:
export RTSP_URL="rtsp://10.0.1.50:8554/live"
export STREAM_COUNT=30

./scripts/run_benchmark_headless.sh
```
This initializes the virtual display buffer (`xvfb-run -a -s "-screen 0 2560x1440x24"`), launches the Iced application with `LIBGL_ALWAYS_SOFTWARE=1`, starts external hardware polling, and flushes metrics.

### 4. Configure 6-Hour Automated Systemd Daemon
To ensure the benchmark survives SSH disconnects and restarts automatically on reboot:
```bash
sudo ./scripts/setup_autostart.sh
```
- **Service Status:** `sudo systemctl status rtsp-benchmark-iced-cpu`
- **Tail Service Logs:** `journalctl -u rtsp-benchmark-iced-cpu -f`
- **Stop Service:** `sudo systemctl stop rtsp-benchmark-iced-cpu`

### 5. Live Telemetry Monitoring
```bash
# 1. Monitor internal rolling 60-second FPS buckets:
tail -f /var/log/benchmark/fps_metrics.log

# 2. Monitor external 10-second CPU / RAM utilization:
tail -f /var/log/benchmark/hardware_metrics.csv
```

---

## Configuration Reference

The application can be configured via environment variables or a `.env` file:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `STREAM_COUNT` | `30` | Number of concurrent RTSP camera streams to render |
| `RTSP_URL` | `rtsp://127.0.0.1:8554/live` | RTSP server stream endpoint |
| `RTSP_URL_PATTERN` | None | Pattern for multi-URL setups (e.g. `rtsp://server/live%d`) |
| `BENCHMARK_LOG_DIR` | `/var/log/benchmark` | Directory for log outputs (fallback: `./logs`) |
| `FPS_METRICS_LOG_PATH` | `/var/log/benchmark/fps_metrics.log` | Path for rolling window JSON metrics |
| `HARDWARE_METRICS_LOG_PATH` | `/var/log/benchmark/hardware_metrics.csv` | Path for external hardware polling CSV |
| `MACHINE_ID` | `c7i-8xlarge-node-1` | Node identifier recorded in JSON telemetry |
| `VIDEO_WIDTH` | `2560` | Target video frame width in pixels |
| `VIDEO_HEIGHT` | `1440` | Target video frame height in pixels |
| `TARGET_FPS` | `25` | Expected frame rate per stream |
| `UI_RENDER_FPS` | `30` | Target UI repaint rate (Hz) |
