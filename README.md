# MASTER SPECIFICATION: 6-Hour RTSP Video Grid Benchmark

## 1. Project Objective

We are building a benchmarking suite to evaluate 5 UI frameworks (**Electron**, **Tauri**, **Qt6**, **Iced**, **Avalonia**) displaying a **30-camera RTSP video grid (1440p / 2560×1440 @ 25 FPS)**.

The benchmark evaluates both architectures under headless Linux (`Xvfb`) on AWS EC2, with the final target deployment being a physical Windows machine. Agents develop on macOS: follow **`BENCHMARK_FINDINGS.md` §9.0** (OS-native decode, `RLIMIT_NOFILE=10240`, 20ms stream stagger, never ship Linux VA-API/EGL flags on Darwin).

1. **GPU-Accelerated (Zero-Copy):** Video is decoded on the GPU ASIC (e.g. NVDEC/VA-API) and shared directly with the UI rendering pipeline (via OpenGL, Direct3D, or WebGPU textures) without touching CPU RAM.
2. **CPU-Only (Software Decoding):** Forcing the CPU to decode and translate planar video memory into UI-compatible pixels to test software fallback resilience under extreme load.

---

## 2. The 6-Hour Execution Strategy

The benchmark runs for exactly **6 hours per implementation**, divided into two distinct phases:

* **Phase 1: Steady State (Hours 0 to 3)**
  * The RTSP server provides 30 uninterrupted streams.
  * **Goal:** Allow the application to settle. JIT compilers optimize (V8, .NET Tiered Compilation), memory pools reach equilibrium, and baseline performance metrics are established.
* **Phase 2: Churn & Recovery (Hours 3 to 6)**
  * The RTSP server will randomly drop and restart streams.
  * **Goal:** Test pipeline cleanup and memory leak resilience. The framework must prove it properly destroys stale GPU textures, cleans up decoder memory, and does not trigger Garbage Collection (GC) pauses or memory bloat when connections drop.
  * **Active Streams Accounting Rule:** During Phase 2 churn, **do not count frames or log bucket seconds for dropped / inactive streams**. Telemetry must strictly record Effective FPS and accumulate stream-seconds for **active (connected) streams only**. Disconnected streams awaiting reconnection backoff must not pollute the unacceptable FPS buckets with false zeroes.

---

## 3. Reconnection Architecture

Because raw multimedia libraries (FFmpeg, GStreamer, WebCodecs) typically emit an EOF or Error event and halt when a socket is violently closed, **every implementation must implement an automatic reconnect loop**.

* When a stream drops, the application must **completely dispose of the old pipeline/decoder object**, wait **3 seconds**, and attempt to reconnect.
* If stale connections, decoder contexts, or texture handles are left hanging in memory during Phase 2, the implementation will fail due to OOM (Out of Memory) or file descriptor starvation (`EMFILE`).

---

## 4. "Effective FPS" Telemetry Standard

Do not use naive UI event loop counters (e.g., Qt `paintEvent`), as they coalesce updates and report falsely low FPS. Do not use raw decode counters, as they hide compositor stutters and report falsely high FPS.

You must measure **Unique Presented FPS** and **Frame Pacing ($\Delta t$)** at the final presentation gate:

1. **Unique Frames:** Only increment the presentation counter if the frame uploaded to the UI has a **new Presentation Timestamp (PTS)**. Duplicate blits of stale frames must not increment FPS counters.
2. **Frame Delta ($\Delta t$):** Measure the exact elapsed time between frame presentations. A perfect 25 FPS stream has a **40ms delta** ($1/25 = 0.040\text{ s}$).
3. **Active Stream Filtering:** Only streams that are currently active and connected contribute to the 1-second FPS calculations and time-in-state bucketing. Dropped streams undergoing reconnection backoff are excluded from the second's bucket accumulation so that connection churn does not artificially distort decode/presentation metrics.
4. **Bucketing & The Frame Pacing Formula:**
   For 25 FPS video, the ideal interval between frames is exactly **$40\text{ms}$** ($1000\text{ms} / 25$).
   Instead of solely checking if 25 frames arrived in a 1-second window, telemetry measures frame arrival pacing ($\Delta t$):
   * **`Paced / Smooth (25-30 FPS, 30ms ≤ Δt ≤ 50ms)`** $\rightarrow$ mapped to `25_to_30_fps` in JSON
   * **`Micro-Stutter / Judder (20-24 FPS, 50ms < Δt ≤ 100ms)`** $\rightarrow$ mapped to `20_to_24_fps` in JSON
   * **`Choppy / Hard Freeze (10-19 FPS, Δt > 80ms)`** $\rightarrow$ mapped to `10_to_19_fps` in JSON
   * **`Unwatchable (<10 FPS, Δt > 100ms lag spikes)`** $\rightarrow$ mapped to `5_to_9_fps` and `under_5_fps` in JSON

5. **Flushing:** Every 60 seconds, flush the aggregated stream-seconds JSON payload to `/var/log/benchmark/fps_metrics.log` (with graceful fallback to `./logs/fps_metrics.log`) and reset internal counters to zero.

### Why UI Event Loops Lie: The Qt & C# Measurement Traps
* **The Qt Under-Reporting Trap (10 FPS when smooth):**
  1. *Event Loop Compression (`QWidget::update()` Coalescing):* Calling `update()` posts `QEvent::UpdateRequest`. Qt compresses multiple paint requests into one, dispatching `paintEvent()` only 10–15 times/sec even though 25 unique frames were decoded and available. A counter inside `paintEvent()` only sees the 10 Qt redraws, not the actual 25 presented frames.
  2. *Direct GPU / EGL Overlay Bypass:* In `QOpenGLWidget` or EGL surfaces, buffer swaps occur independently of Qt's high-level widget refresh.
  3. *Timer Quantization:* `QTimer` events bunch together under high CPU loads on Linux.
* **The C# Over-Reporting Trap (25 FPS when visually choppy):**
  - If frame counts are taken at the dispatcher callback or decode stage, 25 frames may be delivered in erratic bursts (e.g. 5ms, 5ms, 120ms, 5ms). The 1-second sum is 25, but the frame pacing has severe judder.
  - Tracking **Unique Presented PTS** and **Inter-Frame Delta ($\Delta t$)** at the presentation gate eliminates both traps.

### Unified Counter Hooks Across All 5 Frameworks

| Framework | Target Presentation Hook | Implementation Rule |
| :--- | :--- | :--- |
| **C++ / Qt6** | `QOpenGLWidget::paintGL()`, `frameSwapped()`, or atomic frame buffer consumer swap | Measure when unique PTS is handed to the rendering surface. Do **not** count naive `paintEvent()` coalesced events. |
| **C# / Avalonia** | `VideoImageControl.Render()` or `OpenGlControlBase.OnOpenGlRender()` | Check `curPts != lastPts` before incrementing; measure `Stopwatch` delta between presentations. |
| **Rust / Iced** | Shader primitive `render()` pipeline or immediately before `wgpu::Queue.submit()` | Record unique texture submission PTS and timestamp delta. |
| **Electron** | WebCodecs `VideoDecoder({ output: (frame) => ... })` | Measure `performance.now()` delta and verify `frame.timestamp !== lastTimestamp` before canvas upload. |
| **Rust / Tauri** | WebCodecs / WebGPU canvas render callback | Check PTS on incoming GStreamer payload and track presentation delta. |

### Required JSON Output Format (`/var/log/benchmark/fps_metrics.log`)

```json
{
  "timestamp": "2026-09-04T12:05:00Z",
  "machine_id": "c7i-8xlarge-node-1",
  "framework": "csharp_avalonia",
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

### External OS Hardware Polling (`/var/log/benchmark/hardware_metrics.csv`)

To avoid differences in how C#, C++, Rust, and Node.js calculate memory footprints, the application code must **not** poll system RAM or CPU usage.

A standard background shell script (`scripts/poll_hardware.sh`) runs alongside the application, polling the OS every 10 seconds and appending the results to a CSV file.

```csv
timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent
2026-09-04T12:05:00Z,4432,15.2,1420,11250,71
2026-09-04T12:05:10Z,4432,14.8,1420,11255,73
```

*(Note: The GPU columns will log `0` or remain blank during CPU-only test runs).*

---

## 5. Disqualification Criteria (The Headroom Rule)

The final production target is a physical Windows machine. Therefore, any implementation that starves the OS of resources during the 6-hour Linux test is disqualified, regardless of its FPS score.

An implementation fails if it exceeds any of these thresholds for **more than 5 sustained minutes**:

* **CPU Usage:** > 85%
* **GPU 3D Engine:** > 80%
* **GPU VRAM:** > 90%
* **GPU Decoder (NVDEC):** > 90%

*(Note: These hardware metrics are collected by the separate external background polling script, never inside the application process).*

---

## 6. Video Stream Feed & Motion Verification

To ensure benchmarks evaluate genuine frame motion and dynamic screen updates (rather than static frames or frame-push numbers):
* The reference video generator uses `testsrc2` (`testsrc2=size=2560x1440:rate=25`), producing animated moving blocks, scrolling color bars, and high-frequency pixel changes at 1440p @ 25 FPS with keyframe interval $g=25$ (1 keyframe/second).
* Test pattern command:
  ```bash
  ffmpeg -re -f lavfi -i "testsrc2=size=2560x1440:rate=25" \
    -c:v libx264 -preset ultrafast -tune zerolatency -threads 4 \
    -g 25 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/live
  ```

---

## 7. Benchmark Hardware Profiles & EC2 Simulation Sizing

Stress-testing 30 concurrent 1440p streams at 25 FPS involves decoding and blitting **750 frames/second (2.76 Gigapixels/second)**:

| Profile | EC2 Instance Type | vCPUs / Cores | RAM | Target Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Baseline Benchmark (Headroom)** | **`c7i.8xlarge`** | 32 vCPUs (16 Physical Cores) | 64 GiB DDR5 | Reference official 6-hour benchmark to verify the framework operates safely below the **85% CPU headroom limit**. |
| **Bare-Minimum Simulation (CPU Stress)** | **`c7i.4xlarge`** | 16 vCPUs (8 Physical Cores) | 32 GiB DDR5 | **Simulates the bare-minimum production PC.** Pushes CPU software decoders to ~80%–95% load to test stability at the edge of frame dropping. |
| **Fail-Boundary Test** | **`c7i.2xlarge`** | 8 vCPUs (4 Physical Cores) | 16 GiB DDR5 | Guaranteed saturation (>98% CPU). Used to verify graceful degradation, socket backpressure, and reconnect handling. |
| **GPU Zero-Copy Simulation** | **`g6.xlarge`** / **`g4dn.xlarge`** | 4 vCPUs (2 Physical Cores) | 16 GiB | Equipped with NVIDIA L4/T4 GPU. Used for verifying hardware NVDEC and zero-copy texture sharing pipelines. |

---

## 8. Production Deployment Context: Windows vs. Headless Linux

While headless Linux (`xvfb-run` on AWS EC2) is used for scalable, automated, and reproducible stress testing, the target end-state deployment is a **Windows desktop environment**.

### The Windows DWM (Desktop Window Manager) Starvation Risk
On headless Linux under Xvfb, running at 90%–95% CPU causes no user-interface degradation because there is no desktop compositor. On Windows:
* If video decoding consumes > 85% CPU, the Windows Desktop Window Manager (`dwm.exe`) and OS thread dispatcher are starved of CPU slices.
* Symptoms include lagging mouse cursors, frozen window dragging, and unresponsive application controls.
* For this reason, exceeding **85% CPU for > 5 minutes is an automatic failure**.

### Production Hardware Profiles (Windows Desktop)

| Deployment Architecture | Minimum CPU | Minimum GPU | Minimum RAM | Expected CPU Load |
| :--- | :--- | :--- | :--- | :--- |
| **Pure CPU Software Decode (30 × 1440p)** | AMD Ryzen 7 7700X / Intel Core i7-13700 (8+ Cores) | None | 16–32 GB DDR5 | **80% – 95%** (Near DWM threshold) |
| **GPU Hardware-Accelerated (Zero-Copy)** | Intel Core i5-12400 / AMD Ryzen 5 5600 (6 Cores) | NVIDIA GTX 1650 / RTX 3050 or Intel UHD 770 (QuickSync) | 16 GB DDR4/DDR5 | **< 15%** (NVDEC handles decode) |
| **Sub-Stream Multi-View (360p/720p Grid)** | Standard Intel Core i5 / AMD Ryzen 5 (6 Cores) | Integrated Graphics | 16 GB DDR4 | **< 20%** (Production VMS best practice) |

---

## 9. Two-Stage Evaluation Strategy: Cloud Filter to Physical Hardware

Synthetic headless benchmarks filter out non-viable candidates; a physical monitor test decides the winner.

* **Stage 1: AWS Headless Elimination (The 6-Hour Crucible):**
  - Run the 6-hour test on headless Linux (`c7i.8xlarge` / `g6.xlarge` via `xvfb-run`).
  - **Disqualify** implementations that exhibit:
    1. Memory leaks ($dM/dt > 0$).
    2. Sustained CPU/GPU saturation ($> 85\%$ CPU, $> 80\%$ 3D GPU, $> 90\%$ VRAM/NVDEC for $> 5$ minutes).
    3. Catastrophic frame drops in the $< 10\text{ FPS}$ unwatchable bucket.
* **Stage 2: Physical Windows Monitor Test (Human Eye Reality Check):**
  - Take the top 2–3 surviving implementations and deploy them to a physical Windows workstation connected to a 60 Hz monitor.
  - Play the `testsrc2` moving line / transitioning block pattern side-by-side.
  - Evaluate visual frame pacing, tearing, and desktop compositor judder under real VSync conditions.
