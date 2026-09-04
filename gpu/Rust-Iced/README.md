# 30-Camera RTSP Video Grid Benchmark (Rust Iced GPU Zero-Copy Hardware Decode)

This implementation fulfills the **GPU-Accelerated (Zero-Copy)** benchmark specification for Rust Iced from the root `README.md`, `BENCHMARK_FINDINGS.md` §9.0, and `gpu/Rust-Iced/prompt.md`.

`src/platform.rs` + OS-first `detect_hardware_decoder()` (`vtdec` / `nvdec` / `d3d11h264dec`). wgpu features: `gles, vulkan, metal, dx12`.

## Architecture Overview

```
                          ┌────────────────────────┐
                          │  MediaMTX RTSP Server  │
                          │   (1440p @ 25 FPS)     │
                          └───────────┬────────────┘
                                      │ TCP (30 streams)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Rust Backend (gpu/Rust-Iced)                                                │
│                                                                             │
│  30 × GStreamer Hardware Decoders (`gstreamer-rs` + `gstreamer-gl`):        │
│   rtspsrc ! rtph264depay ! h264parse ! {nvdec|vtdec|d3d11h264dec} ! …        │
│   ├── OS-first HW decode (NVDEC / VideoToolbox / D3D11)                     │
│   ├── GPU color conversion (YUV -> RGBA) in VRAM via OpenGL shaders         │
│   └── Microsecond timestamp generation                                      │
│                                                                             │
│  VRAM Texture Extraction:                                                   │
│   ├── appsink.pull_sample() extracts GLMemory texture ID directly           │
│   └── Texture ID mapped to `wgpu::Texture` handle via GLES HAL              │
│                                                                             │
│  Zero-Contention Pointer Swaps:                                             │
│   └── ArcSwap<Option<Arc<GpuFrameData>>> (keeps VRAM buffer valid)          │
│                                                                             │
│  Iced UI + iced_wgpu Custom Shader:                                         │
│   ├── `iced::widget::shader::Shader::new(VideoTileProgram)`                 │
│   ├── Custom WGSL textured quad render pipeline                             │
│   └── Direct quad blit inside Iced render pass                              │
│                                                                             │
│  Telemetry Engine:                                                          │
│   ├── 1-Second performance bucket aggregation (25-30, 20-24, 10-19, 5-9, <5)│
│   └── 60-Second rolling window flush to `/var/log/benchmark/fps_metrics.log` │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Technical Constraints & Architecture Implementation

### 1. Hardware Video Decoding (`src/decoder.rs` & `src/config.rs`)
* **Multi-Platform Hardware Decoders:**
  - **Linux (Target AWS EC2 with NVIDIA GPU):** NVIDIA `nvdec` plugin from GStreamer bad plugins. Offloads 100% of H.264 bitstream parsing and macroblock decoding to the dedicated NVDEC silicon chip on the GPU.
  - **Windows:** Direct3D 11 `d3d11h264dec` and `d3d12h264dec` hardware decoding across Intel QuickSync, AMD Radeon, and NVIDIA GPUs.
  - **macOS:** Apple VideoToolbox `vtdec` direct NV12 hardware decoding.
* **Direct NV12 Video Ingestion & Zero-Copy Pipeline:**
  - Eliminates intermediate OpenGL context download cycles (`glupload ! glcolorconvert ! gldownload` removed).
  - Decoded NV12 frames are ingested as dual planes ($Y$ plane in `R8Unorm` and $UV$ plane in `Rg8Unorm`), cutting frame memory transfer from 14.7 MB down to 5.5 MB per frame (a 63% reduction).
* **VRAM Texture Sharing & Platform Bridges (`src/zero_copy.rs`):**
  - Uses `wgpu-hal` to interface with native OS GPU APIs: Apple Metal (`wgpu-hal Metal`), Direct3D 12 (`wgpu-hal Dx12`), and OpenGL/GLES (`wgpu-hal GLES`).
* **Wait-Free Lockless Frame Handoff:**
  - Background decoder worker threads communicate with the Iced UI thread via `arc_swap::ArcSwap<Option<Arc<GpuFrameData>>>`.
  - Atomic pointer updates eliminate lock contention across all 30 streams.

### 2. Dual WGSL Render Pipelines (`src/shader.rs`)
* **WGPU Backend:** Forced to `iced_wgpu` using WGSL shader modules.
* **Dual-Format Rendering:**
  - **NV12 Pipeline:** Performs hardware-accelerated BT.709 color conversion directly inside the fragment shader:
    ```wgsl
    @fragment
    fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
        let y = textureSample(t_y, s_video, in.tex_coords).r;
        let uv = textureSample(t_uv, s_video, in.tex_coords).rg;
        let u = uv.r - 0.5;
        let v = uv.g - 0.5;
        let r = y + 1.5748 * v;
        let g = y - 0.1873 * u - 0.4681 * v;
        let b = y + 1.8556 * u;
        return vec4<f32>(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
    }
    ```
  - **RGBA Pipeline:** Direct blit for pre-converted RGBA and GLMemory textures.

### 3. Dual Telemetry Engine (`src/telemetry.rs`)
* **Internal FPS Time-in-State:**
  - 1-Second tick: Collects painted frames from atomic counters and sorts streams into buckets (`25_to_30_fps`, `20_to_24_fps`, `10_to_19_fps`, `5_to_9_fps`, `under_5_fps`).
  - 60-Second flush: Serializes 1,800 stream-seconds of metrics into JSON matching the root `README.md` specification and appends to `/var/log/benchmark/fps_metrics.log`.
  - Automatic fallback to `./logs/fps_metrics.log` if `/var/log/benchmark/` is not writable.
* **External OS Hardware Polling (`scripts/poll_hardware.sh`):**
  - Polls PID every 10 seconds: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`.
  - Queries `nvidia-smi` on Linux with NVIDIA GPU.

---

## Quick Start & Execution

### 1. Headed Mode (Desktop Window Inspection)
```bash
# Start MediaMTX RTSP stream
./scripts/start_rtsp_feed.sh &

# Run headed benchmark
./scripts/run_benchmark_headed.sh
# Or directly:
cargo run --release
```

### 2. Headless Mode (AWS EC2 Linux with NVIDIA GPU via Xvfb)
```bash
./scripts/run_benchmark_headless.sh
```

### 3. 6-Hour Systemd Daemon
```bash
sudo ./scripts/setup_autostart.sh
```
