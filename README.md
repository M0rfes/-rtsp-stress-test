# 24-Hour RTSP Video Grid Benchmark: Goals & Telemetry Specification

## 1. Project Goal

The objective of this benchmark is to stress-test five UI framework architectures (Electron, Tauri, Qt, Iced, and Avalonia) to determine the most performant and stable solution for rendering a grid of **thirty 1440p (2K) RTSP video streams at 25 FPS**.

Each framework is tested under two strict conditions over a continuous 24-hour period on headless Linux (Xvfb):

1. **GPU-Accelerated (Zero-Copy):** Decoding the video on the GPU and sharing the VRAM texture directly with the UI rendering pipeline without touching CPU RAM.
2. **CPU-Only (Software Decoding):** Forcing the CPU to decode and translate planar video memory into UI-compatible pixels to test software fallback resilience.

### The "Headroom" Pass/Fail Rule

Maintaining 25 FPS is not the only success metric. Because the target deployment is a Windows desktop environment, any application that starves the Windows Desktop Window Manager (DWM) of resources is disqualified. **An implementation fails if it exceeds any of these thresholds for more than 5 minutes:**

- **Total CPU Usage:** > 85%
- **GPU 3D Engine Usage:** > 80%
- **GPU VRAM Allocation:** > 90% (Spilling into system RAM)
- **GPU Decoder (NVDEC):** > 90%

---

## 2. Telemetry Architecture

Logging 30 concurrent video streams at 25 FPS generates millions of events per hour. To prevent disk I/O bottlenecks from artificially causing frame drops, **no implementation is permitted to log individual frame drops to disk**.

The telemetry relies on a dual-logging architecture: **Internal FPS Time-in-State Logging** (handled by the framework) and **External OS Hardware Polling** (handled by a background script).

### A. Internal FPS Logging (Time-in-State)

Every framework must track the frames rendered by each of the 30 video players independently.

1. **The 1-Second Tick:** Every 1 second, the application checks exactly how many frames each player painted to the screen, categorizing the stream into an FPS bucket (e.g., 25-30, 20-24, under 5).
2. **The 60-Second Flush:** After 60 seconds, the application has accumulated 1,800 "stream-seconds" of data (30 streams × 60 seconds). It flushes this exact JSON payload to disk and immediately resets its internal counters to zero.

**Required JSON Output Format (`/var/log/benchmark/fps_metrics.log`):**

```json
{
  "timestamp": "2026-09-04T12:05:00Z",
  "machine_id": "c7i-8xlarge-node-1",
  "framework": "rust_iced",
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

### B. External OS Hardware Polling

To avoid differences in how C#, C++, Rust, and Node.js calculate memory footprints, the application code must **not** attempt to log system RAM or CPU usage.

A standard background shell script will run alongside the application, polling the Linux OS every 10 seconds and appending the results to a CSV file.

**Required CSV Output Format (`/var/log/benchmark/hardware_metrics.csv`):**

```csv
timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent
2026-09-04T12:05:00Z,4432,15.2,1420,11250,71
2026-09-04T12:05:10Z,4432,14.8,1420,11255,73

```

_Note: The GPU columns will remain empty or log `0` during the CPU-only test runs._

---

## 3. Benchmark Hardware Profiles & EC2 Simulation Sizing

Because stress-testing 30 concurrent 1440p streams at 25 FPS involves decoding and blitting **750 frames/second (2.76 Gigapixels/second)**, selecting the appropriate AWS EC2 instance type depends on whether you are verifying full headroom or stress-testing the absolute lower hardware boundary:

| Profile | EC2 Instance Type | vCPUs / Cores | RAM | Target Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Baseline Benchmark (Headroom)** | **`c7i.8xlarge`** | 32 vCPUs (16 Physical Cores) | 64 GiB DDR5 | Used for official 24-hour benchmarking to ensure the framework operates comfortably below the **85% CPU limit**. |
| **Bare-Minimum Simulation (CPU Stress)** | **`c7i.4xlarge`** | 16 vCPUs (8 Physical Cores) | 32 GiB DDR5 | **Recommended to simulate the bare-minimum production PC.** Pushes CPU software decoders to ~80%–95% load to test stability at the edge of frame dropping. |
| **Fail-Boundary Test** | **`c7i.2xlarge`** | 8 vCPUs (4 Physical Cores) | 16 GiB DDR5 | Guaranteed saturation (>98% CPU). Used to verify graceful degradation, socket backpressure, and reconnect handling. |
| **GPU Zero-Copy Simulation** | **`g6.xlarge`** / **`g4dn.xlarge`** | 4 vCPUs (2 Physical Cores) | 16 GiB | Equipped with NVIDIA L4/T4 GPU. Used for verifying hardware NVDEC and zero-copy texture sharing pipelines. |

---

## 4. Production Deployment Context: Windows vs. Headless Linux

While headless Linux (`xvfb-run` on AWS EC2) is used for scalable, automated, and reproducible stress testing, the target end-state deployment is a **Windows desktop environment**.

### The Windows DWM (Desktop Window Manager) Starvation Risk
On headless Linux under Xvfb, running at 90%–95% CPU causes no user-interface degradation because there is no desktop compositor. On Windows:
* If video decoding consumes > 85% CPU, the Windows Desktop Window Manager (`dwm.exe`) and OS thread dispatcher are starved of CPU slices.
* Symptoms include lagging mouse cursors, frozen window dragging, and unresponsive application controls.
* For this reason, exceeding **85% CPU for > 5 minutes is an automatic failure**.

### Production Hardware Recommendations (Windows Desktop)

| Deployment Architecture | Minimum CPU | Minimum GPU | Minimum RAM | Expected CPU Load |
| :--- | :--- | :--- | :--- | :--- |
| **Pure CPU Software Decode (30 × 1440p)** | AMD Ryzen 7 7700X / Intel Core i7-13700 (8+ Cores) | None | 16–32 GB DDR5 | **80% – 95%** (Near DWM threshold) |
| **GPU Hardware-Accelerated (Zero-Copy)** | Intel Core i5-12400 / AMD Ryzen 5 5600 (6 Cores) | NVIDIA GTX 1650 / RTX 3050 or Intel UHD 770 (QuickSync) | 16 GB DDR4/DDR5 | **< 15%** (NVDEC handles decode) |
| **Sub-Stream Multi-View (360p/720p Grid)** | Standard Intel Core i5 / AMD Ryzen 5 (6 Cores) | Integrated Graphics | 16 GB DDR4 | **< 20%** (Production VMS best practice) |

