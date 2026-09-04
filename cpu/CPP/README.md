# 30-Camera RTSP Video Grid Benchmark (C++ Qt6 CPU Software Decode)

This implementation fulfills the **CPU-Only (Software Decoding)** benchmark specification for C++ Qt6 from the root [README.md](../../README.md), [BENCHMARK_FINDINGS.md](../../BENCHMARK_FINDINGS.md) §9.0, and [cpu/CPP/prompt.md](prompt.md).

`src/platform.cpp` raises `RLIMIT_NOFILE` to 10240 and logs the OS path before `QApplication`. Stream stagger is `kStreamStaggerMs` (20ms).

## Architecture Overview

```
                          ┌────────────────────────┐
                          │  MediaMTX RTSP Server  │
                          │   (1440p @ 25 FPS)     │
                          └───────────┬────────────┘
                                      │ TCP (30 streams)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ C++ Qt6 Backend & Worker Threads                                            │
│                                                                             │
│  30 × Dedicated RTSP Decoders (`libavformat` + `libavcodec` on QThread):     │
│   avformat_open_input -> av_read_frame -> avcodec_receive_frame             │
│   ├── Pure CPU software decoding via `avcodec_find_decoder(AV_CODEC_ID_H264)`│
│   ├── Jitterbuffer & TCP socket buffer (4MB) with 500ms max latency         │
│   └── Auto-reconnection on network drops with exponential backoff           │
│                                                                             │
│  Color Conversion (Planar YUV to RGB32 via `libswscale`):                   │
│   ├── `sws_scale` converts YUV420p into native 32-bit RGB (Format_RGB32)    │
│   └── Direct SIMD transformation into 64-byte aligned pre-allocated memory  │
│                                                                             │
│  Wait-Free Lock-Free Triple-Buffer Handoff:                                 │
│   ├── 3 pre-allocated buffers per stream (Producer, Shared, Consumer)       │
│   ├── Atomic pointer exchange (`std::atomic<int>::exchange`)                │
│   └── Atomic counters (`uint64_t`) for decoupled stream-second telemetry    │
│                                                                             │
│  Telemetry Manager:                                                         │
│   ├── 1-Second performance bucket aggregation across 30 streams             │
│   └── 60-Second rolling window flush to `/var/log/benchmark/fps_metrics.log`│
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ Atomic buffer acquisition (Zero locks)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Qt6 Native GUI Frontend                                                     │
│                                                                             │
│  Rendering:                                                                 │
│   ├── `QImage` instantiated directly on pre-allocated RGB32 memory buffer   │
│   └── Blitted via `QPainter::drawImage()` onto custom `VideoWidget`         │
│                                                                             │
│  UI Grid:                                                                   │
│   ├── `QGridLayout` containing 30 widgets (6 columns × 5 rows)              │
│   ├── Real-time per-tile HUD (Camera label, resolution, color-coded FPS)   │
│   └── Master top dashboard (Streams, aggregate FPS, 60s countdown, buckets) │
│                                                                             │
│  Decoupled UI Loop:                                                         │
│   ├── 30 FPS RenderTick: triggers repaint without flooding Qt event queue   │
│   └── 1 FPS TelemetryTick: aggregates metrics and writes to disk            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architectural Principles & Constraints

### 1. Pure CPU Software Decoding (`stream_worker.cpp`)
- Each RTSP stream is processed by a dedicated OS worker thread running on its own `QThread`.
- **Software Decoder Selection:** Enforces pure CPU software decoding using `avcodec_find_decoder(codec_id)` (libavcodec H.264 software decoder), strictly bypassing any hardware accelerators (VA-API, NVDEC, VideoToolbox).
- **Thread Tuning:** Configures `codecCtx->thread_count = 1` per stream worker, ensuring 30 decoders map cleanly onto 16–32 vCPU host cores without thread scheduler thrashing.
- **Latency & TCP Backpressure:** `rtsp_transport=tcp`, `max_delay=500000` (500ms), `buffer_size=4194304` (4MB socket buffer).

### 2. Color Conversion (`libswscale`)
- Decoded raw planar `YUV420p` video frames are transformed to 32-bit `RGB32` using FFmpeg's `libswscale` (`sws_scale`) directly on the background worker thread.
- Output buffers are allocated with 64-byte memory alignment (`av_malloc`), unlocking native CPU SIMD vectorization (AVX2, AVX-512, ARM NEON).
- Zero color conversion operations are executed on the main UI rendering thread.

### 3. Memory Management: Zero-Copy `QImage`
- Memory is pre-allocated upon receiving the first video frame (three 14.7 MB buffers per stream for 2560×1440 RGB32).
- When blitting inside `VideoWidget::paintEvent()`, `QImage` is instantiated directly on top of the pre-allocated memory buffer:
  ```cpp
  QImage img(pixels, width, height, width * 4, QImage::Format_RGB32);
  ```
- This completely avoids deep copies within CPU RAM.

### 4. Wait-Free Lock-Free Triple-Buffer Handoff
- Wrapping 30 streams × 14.7 MB frames in a `std::mutex` causes lock contention and UI stalls.
- Instead, each worker uses a 3-buffer circulation:
  - **Producer Buffer:** Dedicated to the decoding thread for `sws_scale()`.
  - **Consumer Buffer:** Dedicated to the UI thread for `QPainter::drawImage()`.
  - **Shared Buffer:** Atomically swapped using `std::atomic<int>::exchange()`.
- Neither thread ever waits on the other, achieving wait-free $O(1)$ handoff.

### 5. UI Thread Starvation Prevention
- Emitting Qt signals/slots across threads 750 times/second saturates the Qt event queue, driving CPU usage above 95% and locking mouse interaction.
- The C++ Qt6 implementation decouples frame decoding from Qt events:
  - Worker threads write frames and increment atomic counters without posting Qt events.
  - A master `QTimer` on the UI thread fires at 30 Hz (`1000 / 30 = 33ms`), updating widgets.
  - A separate `QTimer` fires at 1 Hz, invoking the Telemetry Manager.

---

## Telemetry Specification

### 1. Internal FPS Logging (`fps_metrics.log`)
- **1-Second Tick:** Every second, frames painted per stream are categorized into performance buckets:
  - `acceptable.25_to_30_fps` (FPS ≥ 25)
  - `acceptable.20_to_24_fps` (20 ≤ FPS < 25)
  - `unacceptable.10_to_19_fps` (10 ≤ FPS < 20)
  - `unacceptable.5_to_9_fps` (5 ≤ FPS < 10)
  - `unacceptable.under_5_fps` (FPS < 5)
- **60-Second Flush:** Accumulates 1,800 stream-seconds (30 streams × 60s) and appends the JSON payload to `/var/log/benchmark/fps_metrics.log` (with graceful fallback to `./logs/fps_metrics.log`).

### 2. External Hardware Polling (`hardware_metrics.csv`)
- Polled by `scripts/poll_hardware.sh` every 10 seconds:
  ```csv
  timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent
  ```
- During CPU-only testing, GPU columns log `0`.

---

## Quick Start & Local Execution

### Prerequisites
- **macOS:**
  ```bash
  brew install cmake pkg-config qtbase ffmpeg mediamtx
  ```
- **Ubuntu 22.04 / 24.04 LTS:**
  ```bash
  sudo ./scripts/ec2_userdata.sh
  ```

### Build (Release Mode)
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)
```

### Run Benchmark
```bash
# Start 30-stream benchmark (auto-starts local MediaMTX if needed)
./scripts/run_benchmark_headless.sh

# Or run with custom parameters:
./build/rtsp-stress-test-cpp-cpu --url rtsp://127.0.0.1:8554/live --streams 30 --log-dir ./logs
```
