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
