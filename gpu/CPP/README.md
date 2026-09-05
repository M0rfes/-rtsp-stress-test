# 30-Camera RTSP Video Grid Benchmark (C++ Qt6 GPU Zero-Copy Hardware Decode)

This implementation fulfills the **GPU-Accelerated (Zero-Copy)** benchmark specification for C++ Qt6 from the root [README.md](../../README.md), [BENCHMARK_FINDINGS.md](../../BENCHMARK_FINDINGS.md) §9.0, and [gpu/CPP/prompt.md](prompt.md).

`src/platform.cpp` raises `RLIMIT_NOFILE` and, on macOS, sets `QSurfaceFormat` 4.1 Core **before** `QApplication`. `hw_accel.cpp` auto-selects VideoToolbox / CUDA+VA-API / D3D11VA by OS.

---

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
│  30 × Dedicated RTSP Hardware Decoders (`libavformat` + `libavcodec`):     │
│   avformat_open_input -> av_read_frame -> avcodec_receive_frame             │
│   ├── Hardware decode via CUDA, VA-API, VideoToolbox, or D3D11VA (OS auto)   │
│   ├── Decodes compressed H.264 bitstream directly into GPU VRAM              │
│   ├── In-band SPS/PPS Access Unit framing via `h264_mp4toannexb`            │
│   └── Sockets configured with `rtsp_transport=tcp`, 500ms max delay, 4MB buf│
│                                                                             │
│  Zero-Copy VRAM Rule:                                                       │
│   ├── Decoded frames remain 100% in GPU VRAM                                │
│   ├── Strictly NO CPU RAM transfers (`av_hwframe_transfer_data` bypassed)   │
│   └── Lock-free reference-counted frame swap (`av_frame_clone` pointer bump)│
│                                                                             │
│  Telemetry Engine:                                                          │
│   ├── 1-Second performance bucket aggregation across 30 streams             │
│   └── 60-Second rolling window flush to `/var/log/benchmark/fps_metrics.log`│
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ Atomic frame acquisition (Zero locks)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Qt6 Native Hardware-Accelerated Frontend                                    │
│                                                                             │
│  Zero-Copy OpenGL Rendering:                                                │
│   ├── Subclassed `QOpenGLWidget` with OpenGL 3.3 / GLES 3.0 shaders          │
│   ├── Direct VRAM plane mapping (NV12 Y/UV planes uploaded to GL textures)  │
│   └── Custom GLSL fragment shader executes BT.709 YUV->RGB on GPU           │
│                                                                             │
│  UI Grid & HUD:                                                             │
│   ├── `QGridLayout` containing 30 hardware-accelerated widgets              │
│   ├── Per-tile HUD (CAM label, resolution, color-coded FPS, GPU badge)      │
│   └── Master top dashboard (Streams, aggregate FPS, 60s countdown, buckets) │
│                                                                             │
│  Decoupled UI Loop:                                                         │
│   ├── 30 FPS RenderTick: triggers repaint without flooding Qt event queue   │
│   └── 1 FPS TelemetryTick: aggregates metrics and writes to disk            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architectural Principles & Zero-Copy Constraints

### 1. Hardware Video Decoding (`src/hw_accel.cpp` & `src/stream_worker.cpp`)
- **GPU Hardware Offload:** Each stream worker connects to the RTSP feed using FFmpeg `libavcodec` configured with dedicated hardware acceleration:
  - **Linux (Target AWS EC2 with NVIDIA GPU):** NVIDIA CUDA (`AV_HWDEVICE_TYPE_CUDA` / NVDEC ASIC).
  - **Linux (Intel / AMD):** VA-API (`AV_HWDEVICE_TYPE_VAAPI`).
  - **macOS (Development):** Apple VideoToolbox (`AV_HWDEVICE_TYPE_VIDEOTOOLBOX`).
  - **Windows:** D3D11VA (`AV_HWDEVICE_TYPE_D3D11VA`).
- **Zero-Copy VRAM Rule:** Decoded video frames reside exclusively in GPU VRAM surfaces (`AV_PIX_FMT_CUDA`, `AV_PIX_FMT_VAAPI`, `AV_PIX_FMT_VIDEOTOOLBOX`). The application **never** copies raw YUV frame pixels back to system host RAM via `av_hwframe_transfer_data()`.
- **H.264 Access Unit Framing:** In-band SPS/PPS parameter set reconstruction and Annex B start-code synchronization via `h264_mp4toannexb` bitstream filtering ensure that hardware decoders never stall upon mid-stream joins.
- **Dedicated Threading:** Demux and decode loops execute on dedicated background `QThread`s with `thread_count = 1` per worker, avoiding CPU scheduler contention.

### 2. GPU Hardware Color Conversion & Quad Blitting (`src/video_widget.cpp` & `src/gl_shader.cpp`)
- **Direct Shader Color Conversion:** Decoded video is mapped to dual textures ($Y$ plane as `GL_R8` and $UV$ plane as `GL_RG8`). Color conversion (BT.709 standard) and 1440p-to-tile bilinear texture downsampling are executed **100% inside GPU fragment shaders**:
  ```glsl
  varying vec2 vTexCoord;
  uniform sampler2D texY;
  uniform sampler2D texUV;

  void main() {
      float y = texture2D(texY, vTexCoord).r;
      vec2 uv = texture2D(texUV, vTexCoord).rg;

      float u = uv.r - 0.5;
      float v = uv.g - 0.5;

      float r = y + 1.5748 * v;
      float g = y - 0.1873 * u - 0.4681 * v;
      float b = y + 1.8556 * u;

      gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
  }
  ```
- **Zero CPU Blitting:** The CPU does not rasterize, convert, or copy 14.7 MB RGBA buffers. Memory bandwidth across the system bus is reduced by **63%** ($5.5\text{ MB}$ NV12 vs $14.7\text{ MB}$ RGBA per frame).

### 3. Wait-Free Lock-Free Frame Handoff
- Background decoder worker threads communicate with the UI rendering pipeline via atomic pointer exchanges (`std::atomic<AVFrame*>::exchange`).
- `av_frame_clone()` performs a lightweight reference count bump without memory duplication or lock contention across all 30 streams.

### 4. UI Thread Starvation Prevention & Typography
- Decoupled master rendering timer triggers `update()` on all 30 widgets at 30 FPS without choking the Qt event queue.
- Overlay rendering (`QPainter`) is isolated to `paintEvent()` with explicit text bounding boxes (`Qt::AlignVCenter`) and full OpenGL state restoration (`GL_UNPACK_ALIGNMENT = 4`), guaranteeing crisp, non-clipped typography and zero font cache corruption across Linux and macOS.

---

## Telemetry Specification

### 1. Internal FPS Logging (`fps_metrics.log`)
- **1-Second Tick:** Every second, frames painted per stream are categorized into performance buckets:
  - `acceptable.25_to_30_fps` (FPS ≥ 25)
  - `acceptable.20_to_24_fps` (20 ≤ FPS < 25)
  - `unacceptable.10_to_19_fps` (10 ≤ FPS < 20)
  - `unacceptable.5_to_9_fps` (5 ≤ FPS < 10)
  - `unacceptable.under_5_fps` (FPS < 5)
- **60-Second Flush:** Every 60 seconds (1,800 stream-seconds accumulated), the JSON payload is appended to `/var/log/benchmark/fps_metrics.log` (with graceful fallback to `./logs/fps_metrics.log`):

```json
{
  "timestamp": "2026-09-04T12:05:00Z",
  "machine_id": "c7i-8xlarge-node-1",
  "framework": "cpp_qt6",
  "hardware_mode": "gpu",
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
Polled by `scripts/poll_hardware.sh` every 10 seconds:
```csv
timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent
2026-09-04T12:05:00Z,4432,12.4,450,3200,68
2026-09-04T12:05:10Z,4432,11.8,452,3210,70
```

---

## Quick Start & Execution

### 1. Headed Mode (Desktop Window Inspection)
```bash
# Start shared RTSP server from repo root
../../rtsp-server/start.sh &

# Run headed benchmark
./scripts/run_benchmark_headed.sh
```

### 2. Headless Mode (AWS EC2 Linux with NVIDIA GPU via Xvfb)
```bash
# Configure environment (or use defaults)
export RTSP_URL="rtsp://10.0.1.50:8554/live"
export STREAM_COUNT=30
export HW_ACCEL="cuda"

./scripts/run_benchmark_headless.sh
```

### 3. 6-Hour Systemd Daemon
```bash
sudo ./scripts/setup_autostart.sh

# Check service status
sudo systemctl status rtsp-benchmark-cpp-gpu.service

# View live service logs
journalctl -u rtsp-benchmark-cpp-gpu.service -f
```

---

## Build Instructions

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)
```

The optimized release executable is generated at `build/rtsp-stress-test-cpp-gpu`.
