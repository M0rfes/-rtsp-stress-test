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
| **Electron** | GPU (Zero-Copy) | `gpu/Electron` | Pending | OffscreenCanvas `BitmapRenderer` / WebGPU, VA-API flags |
| **C++ (Qt6)** | CPU (Software) | `cpu/CPP` | Pending | `libavcodec` software decode, `libswscale` to RGB32, `QPainter` |
| **C++ (Qt6)** | GPU (Zero-Copy) | `gpu/CPP` | Pending | `AV_HWDEVICE_TYPE_VAAPI` / `CUDA`, `QOpenGLWidget` / RHI |
| **Rust (Tauri)**| CPU (Software) | `cpu/Rust-Tauri` | Pending | `gstreamer-rs` demux, WebSocket IPC, React WebCodecs Canvas |
| **Rust (Tauri)**| GPU (Zero-Copy) | `gpu/Rust-Tauri` | Pending | `gstreamer-rs` demux, WebSocket IPC, `BitmapRenderer` / WebGPU |
| **Rust (Iced)** | CPU (Software) | `cpu/Rust-Iced` | Pending | `gstreamer-rs` / `ffmpeg-next`, `tiny-skia` backend, `Arc<RwLock<[u8]>>` |
| **Rust (Iced)** | GPU (Zero-Copy) | `gpu/Rust-Iced` | Pending | `gstreamer-rs` nvdec, `iced_wgpu` backend, WGPU texture mapping |
| **C# (.NET)** | CPU (Software) | `cpu/C#` | Pending | Avalonia UI, `FFmpeg.AutoGen`, `WriteableBitmap.Lock()` memory copy |
| **C# (.NET)** | GPU (Zero-Copy) | `gpu/C#` | Pending | Avalonia UI, `OpenGlControlBase`, raw texture ID injection |
