# RTSP Video Grid Benchmark: Practical Findings & Architecture Notes

> **Purpose of this document:**  
> This file contains critical technical lessons, format requirements, and operational quirks discovered during implementation and real-world testing that were **not explicitly covered in the prompt markdown files or root README**. Any fresh agent or developer implementing the remaining benchmark frameworks (C++ Qt, Tauri, Iced, Avalonia, and GPU zero-copy variants) should review these findings before writing code.

---

## 1. Video Demuxing & H.264 Access Unit Framing (Universal)

### The Multi-Slice Issue at 1440p
* **Prompt Assumption:** "Demux RTSP streams to extract compressed NAL units."
* **Reality:** At 1440p (2560×1440 2K), video encoders (x264, IP cameras, FFmpeg) split each frame into **multiple slices** (e.g. 8–10 NAL slices of type 1 or 5 per frame) for multi-threaded encoding.
* **Impact:** If your demuxer treats every NAL unit as a separate packet/frame, the decoder receives fragmented slices and fails or produces corrupted artifacts.
* **Solution:** Demuxers must assemble a complete **Access Unit (AU)** containing all slices of a picture:
  - Detect frame boundary:
    1. An AUD (NAL type 9).
    2. Any non-VCL NAL (SPS 7, PPS 8, SEI 6) arriving after VCL slices have already been accumulated.
    3. A VCL slice (NAL 1 or 5) where `first_mb_in_slice == 0` (the MSB of the byte immediately following the NAL header is 1: `(headerByte & 0x80) !== 0`).
  - Bundle all slices of the frame together into a single continuous buffer.

### In-Band SPS/PPS Guarantees
* RTSP servers often emit SPS (type 7) and PPS (type 8) only once during connection setup or via SDP. Mid-stream joins or reconnected decoders will hang without parameter sets.
* When spawning FFmpeg in copy mode, always include:
  ```bash
  -bsf:v "h264_mp4toannexb,dump_extra=freq=keyframe"
  ```
* In addition, the demuxer should cache the latest SPS and PPS and ensure every keyframe payload begins with `[SPS] [PPS] [IDR Slice 1..N]`.

---

## 2. Decoders & Codec Levels

### H.264 Levels for 1440p
* Baseline Level 3.0 (`avc1.42001e`) only supports up to 720p. If passed to WebCodecs (`VideoDecoder`) or hardware decoders, decoding 1440p frames will fail or be rejected.
* 1440p (2560×1440 at 25 FPS) requires **H.264 Level 5.0 or higher** (`avc1.42c032` or `avc1.640032`).
* **Best Practice:** Extract `profile_idc`, `constraint_flags`, and `level_idc` directly from bytes 1..3 of the SPS NAL unit:
  ```typescript
  const codec = `avc1.${sps[1].toString(16).padStart(2,'0')}${sps[2].toString(16).padStart(2,'0')}${sps[3].toString(16).padStart(2,'0')}`;
  ```

---

## 3. Telemetry & Log Path Fallbacks

### Dual Telemetry Rules
1. **Internal Time-in-State (`fps_metrics.log`):**
   - Exact schema defined in `README.md`.
   - 1-second tick: categorize each stream's painted frame count into buckets (`25_to_30_fps`, `20_to_24_fps`, `10_to_19_fps`, `5_to_9_fps`, `under_5_fps`).
   - 60-second flush: accumulates 1,800 stream-seconds (30 streams × 60s), appends the JSON object to disk, and immediately resets counters to zero.
2. **External Hardware Polling (`hardware_metrics.csv`):**
   - Polled by background script (`scripts/poll_hardware.sh`) every 10 seconds.
   - Format: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`.
   - In CPU benchmarks, GPU fields must be `0` or empty.

### Permissions & Path Fallback
* The specified default path is `/var/log/benchmark/`.
* On developer machines (macOS) or non-root runners, `/var/log/` is not writable by standard users.
* All framework implementations should attempt `/var/log/benchmark/` first, but gracefully fallback to `./logs/` if write access is denied.

---

## 4. UI Thread Starvation & Event Flooding

* 30 streams × 25 FPS = **750 video frames per second**.
* If frame rendering triggers UI framework reactive updates (e.g. React `setState`, Avalonia `INotifyPropertyChanged`, Qt signals across threads), the main UI thread will lock up and fail the 85% CPU limit rule.
* **Rules for all implementations:**
  - Decouple video rendering from UI state.
  - Frame counts must be tracked in mutable atomic counters or refs.
  - UI HUD / overlays should only update at low frequency (e.g. once per second during the benchmark tick).
  - Always immediately release/close decoded frame surfaces (`videoFrame.close()`, `av_frame_free()`, bitmap unmap) to prevent memory ballooning.

---

## 5. Headless Linux (AWS EC2 / Ubuntu) Execution via Xvfb

* Target deployment is headless Linux (e.g. AWS `c7i.8xlarge` / `g6.8xlarge`).
* GUI frameworks require an active X display server or will exit with display errors.
* Run inside Xvfb with matching resolution:
  ```bash
  xvfb-run -a -s "-screen 0 2560x1440x24" <command>
  ```
  *(The `-a` flag prevents display number collisions).*
* **Do NOT hide the window (`show: false`) in headless mode:**
  - Inside Xvfb, the virtual screen is completely in memory.
  - Hiding the window causes browsers and UI toolkits to throttle background frame painting. Keep the window visible to the Xvfb server.
* On Linux, add `--no-sandbox` and `--disable-dev-shm-usage` to prevent container/EC2 shared memory starvation.

---

## 6. RTSP Test Feed Generation (MediaMTX + FFmpeg)

* Public internet RTSP streams (`rtsp://...`) are flaky, rate-limited, and ISPs often block inbound port 554.
* For reproducible local and CI testing, use **MediaMTX** with FFmpeg:
  - In MediaMTX v1.20+, unconfigured paths will return `400 Bad Request` unless `mediamtx.yml` contains:
    ```yaml
    paths:
      all:
    ```
  - Generate a 1440p 25 FPS test stream with FFmpeg:
    ```bash
    ffmpeg -re -f lavfi -i "testsrc2=size=2560x1440:rate=25" \
      -c:v libx264 -preset ultrafast -tune zerolatency \
      -g 25 -pix_fmt yuv420p \
      -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
    ```
  - *(Avoid `-vf "drawtext=..."` as standard FFmpeg packages on macOS/Linux may lack `libfreetype`).*

---

## 7. Framework Matrix Status

| Framework | Architecture Mode | Directory | Status | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Electron** | CPU (Software) | `cpu/Electron` | **Completed & Tested** | WebCodecs `VideoDecoder` fallback, Canvas 2D blit, local WebSocket IPC |
| **Electron** | GPU (Zero-Copy) | `gpu/Electron` | **Completed & Tested** | WebCodecs `prefer-hardware`, `OffscreenCanvas` `BitmapRenderer` zero-copy, VA-API & EGL flags |
| **C++ (Qt6)** | CPU (Software) | `cpu/CPP` | Pending | `libavcodec` software decode, `libswscale` to RGB32, `QPainter` |
| **C++ (Qt6)** | GPU (Zero-Copy) | `gpu/CPP` | Pending | `AV_HWDEVICE_TYPE_VAAPI` / `CUDA`, `QOpenGLWidget` / RHI |
| **Rust (Tauri)**| CPU (Software) | `cpu/Rust-Tauri` | Pending | `gstreamer-rs` demux, WebSocket IPC, React WebCodecs Canvas |
| **Rust (Tauri)**| GPU (Zero-Copy) | `gpu/Rust-Tauri` | Pending | `gstreamer-rs` demux, WebSocket IPC, `BitmapRenderer` / WebGPU |
| **Rust (Iced)** | CPU (Software) | `cpu/Rust-Iced` | Pending | `gstreamer-rs` / `ffmpeg-next`, `tiny-skia` backend, `Arc<RwLock<[u8]>>` |
| **Rust (Iced)** | GPU (Zero-Copy) | `gpu/Rust-Iced` | Pending | `gstreamer-rs` nvdec, `iced_wgpu` backend, WGPU texture mapping |
| **C# (.NET)** | CPU (Software) | `cpu/C#` | Pending | Avalonia UI, `FFmpeg.AutoGen`, `WriteableBitmap.Lock()` memory copy |
| **C# (.NET)** | GPU (Zero-Copy) | `gpu/C#` | Pending | Avalonia UI, `OpenGlControlBase`, raw texture ID injection |

---

## 8. Hardware Sizing, EC2 Box Selection, & Production Realities

### EC2 Instance Sizing Guide
When stress-testing the benchmark in AWS EC2 headless Linux (Xvfb) before deploying to Windows, choose your instance based on the evaluation goal:

| Test Goal | EC2 Instance Type | Specs | Role & Simulation Target |
| :--- | :--- | :--- | :--- |
| **Full Headroom Benchmark** | **`c7i.8xlarge`** | 32 vCPUs (16 physical cores), 64 GiB DDR5 | Reference instance. Verifies that the implementation maintains 25 FPS across all 30 streams while staying strictly below the **85% CPU headroom limit**. |
| **Bare-Minimum Simulation** | **`c7i.4xlarge`** | 16 vCPUs (8 physical cores), 32 GiB DDR5 | **Simulates the bare-minimum production PC** (equivalent to an 8-core consumer CPU like the Ryzen 7 7700X or Intel Core i7-13700 with 32 GB RAM). Expect **80%–95% CPU load**; directly tests decoder survival under heavy pressure. |
| **Saturation / Overload Test** | **`c7i.2xlarge`** | 8 vCPUs (4 physical cores), 16 GiB DDR5 | Simulates an under-specced quad-core desktop. Guaranteed to pin CPU at 100% and test frame-dropping, packet discard, and reconnection stability. |
| **GPU Zero-Copy Test** | **`g6.xlarge`** / **`g4dn.xlarge`** | 4 vCPUs, 16 GiB RAM, NVIDIA L4/T4 GPU | Validates GPU hardware decoding (NVDEC) and zero-copy rendering under headless Xvfb with NVIDIA drivers. |

### Computational Demands of 30 × 1440p Pure CPU Decoding
* **Aggregate Frame Rate:** 30 streams × 25 FPS = **750 FPS**.
* **Pixel Throughput:** 750 × 2560 × 1440 = **2.76 Gigapixels/second**.
* **Memory Bandwidth Bottleneck:** Each uncompressed 1440p YUV420p frame is ~5.53 MB. Transferring, converting (YUV to RGB), and software-blitting 750 frames/second requires continuously moving **~12–18 GB/s** of memory buffers across RAM and CPU L3 cache. Instances with DDR5 memory (like `c7i` / `c7a`) are necessary to prevent memory bus saturation.

### Windows Desktop Production Realities (DWM Starvation & Sub-Streams)
1. **DWM Thread Starvation:**  
   Headless Linux under Xvfb lacks a desktop compositor, tolerating 90%+ CPU load. On Windows, if total CPU utilization exceeds 85% for sustained periods, the Windows Desktop Window Manager (`dwm.exe`) starves, leading to mouse lag and application freezing.
2. **Sub-Stream Multi-View Architecture:**  
   In commercial Video Management Systems (Milestone, Genetec, Nx Witness), a 30-tile grid on a 1080p/4K monitor only renders ~500×300 pixels per tile. Production deployments feed low-resolution **sub-streams** (e.g., 640×360 @ 15 FPS) to the grid, switching to the 1440p/4K **main stream** only when a tile is maximized. This drops CPU utilization on standard 6-core office PCs to **< 20%**.
3. **GPU Hardware Offload:**  
   When hardware acceleration is enabled on Windows (via Intel QuickSync iGPU or NVIDIA NVDEC), CPU consumption for 30 streams drops from ~85% to **< 15%**.

### Software-Only Decode Enforcement in WebCodecs
To strictly prevent Chromium from silently invoking hardware acceleration when testing on machines with GPUs, WebCodecs `VideoDecoder` configurations must specify:
```typescript
decoder.configure({
  codec: detectedCodec,
  avc: { format: 'annexb' },
  optimizeForLatency: true,
  hardwareAcceleration: 'prefer-software', // Guaranteed CPU software fallback
});
```
In combination with `app.commandLine.appendSwitch('disable-accelerated-video-decode')`, this guarantees purely CPU-driven software decoding across all platforms.

### GPU Zero-Copy Architecture & Linux VA-API Implementation (Electron GPU)
1. **Zero-Copy Rendering via `OffscreenCanvas` & `ImageBitmapRenderingContext`:**
   - Standard Canvas 2D `drawImage(videoFrame, ...)` forces an expensive CPU readback / conversion before re-uploading to the compositor.
   - Zero-copy GPU rendering transfers the GPU texture directly:
     ```typescript
     const offscreen = canvas.transferControlToOffscreen();
     const bitmapCtx = offscreen.getContext('bitmaprenderer');
     
     // Hardware decode via WebCodecs
     createImageBitmap(videoFrame).then((bitmap) => {
       videoFrame.close();
       bitmapCtx.transferFromImageBitmap(bitmap); // GPU texture transferred with zero CPU copy
     });
     ```
   - Hardware-decoded frames stay in VRAM throughout decode, color-conversion, and display presentation.
2. **Headless Linux Flags on Nvidia (AWS EC2 `g4dn`/`g5`/`g6`):**
   - Chromium requires explicit switches to use VA-API translation on Nvidia GPUs:
     ```bash
     --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiOnNvidiaGPUs \
     --use-gl=egl \
     --disable-software-rasterizer \
     --no-sandbox \
     --disable-dev-shm-usage
     ```
   - WebCodecs `VideoDecoder` configuration must specify:
     ```typescript
     decoder.configure({
       codec: detectedCodec, // e.g. avc1.42c032 (Level 5.0+ for 1440p)
       avc: { format: 'annexb' },
       optimizeForLatency: true,
       hardwareAcceleration: 'prefer-hardware', // Request GPU hardware decode
     });
     ```

---

## 9. Framework-Specific Implementation Guide & Gotchas (For Remaining Agents)

### 9.1 Cross-Platform Development Guide: macOS Dev -> AWS EC2 Ubuntu Production
* **The Reality:** Agents develop on macOS (Apple Silicon / Intel), but benchmarks execute on headless AWS EC2 Linux Ubuntu (`c7i.8xlarge`, `g6.8xlarge`) via `Xvfb`.
* **Platform Conditional Handling:**
  - Never hardcode Linux-only binary paths or flags without checking `process.platform` / OS detection.
  - On macOS, Nvidia VA-API does not exist (macOS uses VideoToolbox / Metal). Always ensure macOS builds gracefully initialize with software fallback or platform-native decoders while ensuring launch scripts pass the required Linux flags (`xvfb-run`, `--use-gl=egl`, `--enable-features=VaapiVideoDecoder`).
* **Telemetry Path Fallback (Mandatory across all frameworks):**
  - Attempt `/var/log/benchmark/fps_metrics.log` and `/var/log/benchmark/hardware_metrics.csv`.
  - On macOS and non-root Linux, automatically fall back to `./logs/fps_metrics.log` and `./logs/hardware_metrics.csv`.
* **Hardware Polling Script (`scripts/poll_hardware.sh`):**
  - Use `date -u +"%Y-%m-%dT%H:%M:%SZ"`.
  - On macOS, use `ps -p <pid> -o %cpu,rss`. On Linux, use `ps -p <pid> -o %cpu,rss --no-headers`.
  - For GPU metrics, query `nvidia-smi --query-gpu=memory.used,utilization.decoder --format=csv,noheader,nounits`.
  - If `nvidia-smi` is not installed or the test is CPU-only, output `0,0` for GPU metrics.

---

### 9.2 C++ (Qt6) Implementation Guide (`cpu/CPP` and `gpu/CPP`)
* **CPU Mode (`cpu/CPP`):**
  - **FFmpeg Decoding:** Spawn 30 `QThread` workers, each running `avcodec_receive_frame`.
  - **Memory Pre-Allocation:** Pre-allocate one continuous `uint8_t*` buffer for RGB32 output per stream. Call `sws_scale()` into this buffer. Construct `QImage` using the pre-allocated buffer constructor:
    ```cpp
    QImage img(rgbBuffer, 2560, 1440, 2560 * 4, QImage::Format_RGB32);
    ```
  - **Event Loop Starvation Warning:** Do **NOT** emit `emit frameReady(QImage)` across Qt threads 750 times/sec. The Qt event queue will choke, causing > 95% CPU consumption and mouse freeze.
  - **Solution:** Use an atomic double-buffer (`std::atomic<uint8_t*>`) between the worker thread and the UI widget. Trigger repaint via a 25 Hz / 30 Hz timer on the main UI thread (`QTimer`), or call `widget->update()` conditionally.
* **GPU Zero-Copy Mode (`gpu/CPP`):**
  - Configure `libavcodec` with `AV_HWDEVICE_TYPE_VAAPI` or `AV_HWDEVICE_TYPE_CUDA`.
  - **Zero-Copy Rule:** Never call `av_hwframe_transfer_data()` — that copies GPU textures back to CPU system RAM.
  - Render with `QOpenGLWidget` or Qt RHI:
    - On Linux / VA-API: Export the `VASurfaceID` as a DMA-BUF file descriptor (`vaExportSurfaceHandle`), and import it into OpenGL via `eglCreateImageKHR` with `EGL_LINUX_DMA_BUF_EXT`.
    - On CUDA: Use `cudaGraphicsGLRegisterImage` / `cudaGraphicsMapResources` to map the decoded frame directly into an OpenGL texture.
  - Render a textured quad in `QOpenGLWidget::paintGL()`.

---

### 9.3 Rust (Tauri) Implementation Guide (`cpu/Rust-Tauri` and `gpu/Rust-Tauri`)
* **IPC Bottleneck Avoidance:**
  - Never use Tauri's `invoke()` or `window.emit()` to pass video frames. IPC serialization in WebKitGTK chokes at ~50 FPS aggregate.
  - Run a lightweight Tokio WebSocket server (`tokio-tungstenite`) in the Rust backend on `127.0.0.1:9999`.
  - Stream compressed NAL units in binary packets directly to the React frontend (identical protocol to the Electron benchmark).
* **Demuxing with `gstreamer-rs`:**
  - Build a GStreamer pipeline:
    ```text
    rtspsrc location=rtsp://127.0.0.1:8554/live protocols=tcp ! rtph264depay ! h264parse ! appsink name=sink
    ```
  - In `appsink`, accumulate slices into Access Units before pushing to the WebSocket.
* **Tauri Frontend (React + WebCodecs):**
  - Reuse the high-performance React renderer architecture:
    - For `cpu/Rust-Tauri`: WebCodecs `prefer-software` with HTML5 Canvas.
    - For `gpu/Rust-Tauri`: WebCodecs `prefer-hardware` with `OffscreenCanvas` and `ImageBitmapRenderingContext` (`transferFromImageBitmap`).
  - WebKitGTK Launch Flags on Linux: Set `WEBKIT_HARDWARE_ACCELERATION_POLICY=always` and ensure Mesa / VA-API drivers are accessible to the WebView.

---

### 9.4 Rust (Iced) Implementation Guide (`cpu/Rust-Iced` and `gpu/Rust-Iced`)
* **CPU Mode (`cpu/Rust-Iced`):**
  - **Software Backend:** Force Iced to use the `tiny-skia` software rendering backend (`iced --features tiny-skia`).
  - **Lock-Free Handoff:** 30 software decoders writing 750 uncompressed frames/s into RAM will cause massive lock contention if wrapped in a `std::sync::Mutex`.
  - Use `arc_swap::ArcSwap` or an atomic triple-buffer for frame handoff between decoding threads and the Iced view cycle.
  - Construct `iced::widget::image::Handle::from_pixels(width, height, bytes)`.
* **GPU Zero-Copy Mode (`gpu/Rust-Iced`):**
  - **Backend:** Force Iced to use `iced_wgpu`.
  - **Hardware Decoding:** Use `gstreamer-rs` with the `nvdec` plugin.
  - **Texture Sharing:** Import the decoded GStreamer hardware buffer into `wgpu::Texture` using Vulkan external memory (`VK_KHR_external_memory`) or DMA-BUF.
  - Implement a custom `iced::widget::shader::Program` or WGPU primitive to render the 30 texture handles in a single GPU pass.

---

### 9.5 C# (.NET / Avalonia UI) Implementation Guide (`cpu/C#` and `gpu/C#`)
* **CPU Mode (`cpu/C#`):**
  - **Garbage Collection (GC) Hazard:** 30 streams × 25 FPS = 750 frames/sec. Allocating a 5.5 MB `byte[]` for each frame generates **4.1 GB/second of allocations**, forcing continuous Gen2 GC halts.
  - **Zero-Allocation Rule:** Pre-allocate fixed unmanaged memory blocks using `NativeMemory.Alloc()` or reuse byte arrays via `ArrayPool<byte>.Shared`.
  - **Rendering:**
    ```csharp
    using (var fb = writeableBitmap.Lock()) {
        Buffer.MemoryCopy(pSourceRgb, (void*)fb.Address, fb.RowBytes * height, fb.RowBytes * height);
    }
    ```
    Call `Dispatcher.UIThread.Post(..., DispatcherPriority.Render)` with dirty flags to trigger visual invalidate without spamming the dispatcher.
* **GPU Zero-Copy Mode (`gpu/C#`):**
  - Configure `FFmpeg.AutoGen` with `AV_HWDEVICE_TYPE_CUDA` or `AV_HWDEVICE_TYPE_VAAPI`.
  - Subclass Avalonia's `OpenGlControlBase`.
  - **Context Synchronization Rule:** Never attempt to call OpenGL or update textures from background FFmpeg decoding threads. Only update textures during `OnOpenGlRender(GlInterface gl, int fb)` when Avalonia's OpenGL context is active and bound.
  - Map CUDA decoded frames to OpenGL texture IDs using CUDA-GL Interop (`cudaGraphicsGLRegisterImage`).
