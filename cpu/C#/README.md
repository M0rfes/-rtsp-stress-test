# 30-Camera RTSP Video Grid Benchmark (C# Avalonia CPU Software Decode)

This implementation fulfills the **CPU-Only (Software Decoding)** benchmark specification for C# Avalonia (.NET 10) from the root [README.md](../../README.md), [BENCHMARK_FINDINGS.md](../../BENCHMARK_FINDINGS.md), and [cpu/C#/prompt.md](prompt.md).

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
│ C# .NET Background Workers (30 × Dedicated LongRunning Task Threads)        │
│                                                                             │
│  30 × Dedicated RTSP Decoders (`FFmpeg.AutoGen` / libavcodec):              │
│   avformat_open_input -> av_read_frame -> avcodec_receive_frame             │
│   ├── Pure CPU software decoding via `avcodec_find_decoder(AV_CODEC_ID_H264)`│
│   ├── Jitterbuffer & TCP socket buffer (4MB) with 500ms max latency         │
│   ├── Single-thread decoder (`thread_count = 1`) per stream                 │
│   └── Auto-reconnection on network drops with exponential backoff           │
│                                                                             │
│  Zero-Allocation Memory Management (GC Protection):                         │
│   ├── Pre-allocated managed `byte[]` buffer per stream                      │
│   ├── Pre-allocated reusable pointer arrays for `sws_scale`                 │
│   └── Planar YUV420p converted to RGBA8888 via SIMD `sws_scale`             │
│                                                                             │
│  WriteableBitmap Rendering Handoff:                                         │
│   ├── Lock bitmap buffer via `writeableBitmap.Lock()`                       │
│   ├── Direct `unsafe` copy using `Buffer.MemoryCopy()`                      │
│   └── Coalesced UI notification via `DispatcherPriority.Render`             │
│                                                                             │
│  Telemetry Manager:                                                         │
│   ├── 1-Second performance bucket aggregation across 30 streams             │
│   └── 60-Second rolling window flush to `/var/log/benchmark/fps_metrics.log`│
└─────────────────────────────────────┬───────────────────────────────────────┘
                                      │ Coalesced Dirty Signal (Zero dispatcher spam)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Avalonia UI Native GUI Frontend                                             │
│                                                                             │
│  Rendering:                                                                 │
│   ├── `UniformGrid` hosting 30 `VideoTileControl` elements                  │
│   ├── Each tile hosts an Avalonia `Image` control bound to `WriteableBitmap`│
│   └── Real-time per-tile HUD: Camera label, resolution, color-coded FPS    │
│                                                                             │
│  Master Top Dashboard:                                                      │
│   ├── Active streams indicator (e.g. 30/30)                                 │
│   ├── Aggregate FPS metric pill (e.g. 750.0 FPS)                            │
│   ├── 60-Second rolling window progress & countdown                         │
│   ├── Acceptable & Unacceptable performance bucket summary pills            │
│   └── Real-time telemetry log destination pill                              │
│                                                                             │
│  Decoupled UI Loop:                                                         │
│   ├── Dispatcher render callbacks update only dirty tiles                   │
│   └── 1-Second `DispatcherTimer` aggregates metrics and updates HUD         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architectural Principles & Constraints

### 1. Pure CPU Software Decoding (`StreamWorker.cs`)
- **Software Decoder Selection:** Pure CPU software decoding is enforced by invoking `ffmpeg.avcodec_find_decoder(AVCodecID.AV_CODEC_ID_H264)` to bind to FFmpeg's optimized software decoder (`ff_h264_decoder`), strictly bypassing GPU accelerators (CUDA, NVDEC, VA-API, VideoToolbox).
- **Thread Tuning:** Decoder context specifies `codecCtx->thread_count = 1`. This maps 30 stream decoders cleanly onto host CPU cores (e.g., 32 vCPUs on AWS EC2 `c7i.8xlarge`) without scheduler thread contention.
- **Low Latency & TCP Backpressure:** Configured with `rtsp_transport=tcp`, `max_delay=500000` (500ms max latency), and a 4MB socket buffer (`buffer_size=4194304`).
- **Access Unit & Keyframe Tolerance:** Recovers gracefully from mid-stream joins using in-band SPS/PPS parameter sets and low-delay flags (`AV_CODEC_FLAG_LOW_DELAY`, `AV_CODEC_FLAG2_FAST`).

### 2. Zero-Allocation Garbage Collection (GC) Protection
- **The GC Hazard:** 30 streams × 25 FPS = 750 frames/sec. Allocating a 14.7 MB uncompressed RGBA frame buffer on each frame creates **11.0 GB/second of heap allocations**, forcing continuous .NET Gen2 Garbage Collection pauses and pinning CPU at 100%.
- **The Zero-Allocation Solution:**
  - Each `StreamWorker` pre-allocates a managed `byte[] _managedRgbBuffer = new byte[width * height * 4]` once when the stream initializes or changes resolution.
  - Reusable unmanaged pointer arrays (`_srcData`, `_srcStride`, `_dstData`, `_dstStride`) are instantiated once in the constructor.
  - `ffmpeg.sws_scale` writes directly into the pinned managed buffer with zero per-frame managed allocations.

### 3. High-Performance Bitmap Blitting (`WriteableBitmap.Lock`)
- Frames are transferred to Avalonia's rendering pipeline using `WriteableBitmap`:
  ```csharp
  fixed (byte* pDst = _managedRgbBuffer)
  {
      using (var fb = _writeableBitmap.Lock())
      {
          Buffer.MemoryCopy(
              pDst,
              (void*)fb.Address,
              (long)fb.RowBytes * height,
              (long)width * 4 * height
          );
      }
  }
  ```
- Uses native SIMD-accelerated 64-bit `Buffer.MemoryCopy` pointer transfers directly into Skia's locked framebuffer memory.

### 4. UI Thread Starvation Prevention & Coalesced Invalidation
- Posting 750 individual render events per second directly to Avalonia's `Dispatcher` saturates the UI message pump, causing mouse cursor lag and violating the Windows DWM 85% CPU headroom rule.
- **Coalesced Invalidation:**
  ```csharp
  if (Interlocked.CompareExchange(ref _renderPending, 1, 0) == 0)
  {
      Dispatcher.UIThread.Post(() =>
      {
          _renderPending = 0;
          if (_hasNewFrame)
          {
              _hasNewFrame = false;
              _videoImage?.InvalidateVisual();
              Interlocked.Increment(ref _paintedFrames);
          }
      }, DispatcherPriority.Render);
  }
  ```
  If a render request is already queued, subsequent frames update the bitmap directly and set `_hasNewFrame = true` without enqueuing redundant UI dispatcher tasks.

### 5. Open File Limit (`RLIMIT_NOFILE`)
- Opening 30 concurrent RTSP TCP sockets, event pipes, and worker threads exceeds the default per-process limit (256 on macOS, 1024 on Linux), resulting in `EMFILE: Too many open files`.
- `FFmpegHelper.RaiseFileDescriptorLimit(10240)` programmatically raises `RLIMIT_NOFILE` to 10,240 at application startup via `libc` P/Invoke.

---

## Telemetry & Master Specification Standards

### 1. The 6-Hour Execution Strategy
* **Phase 1: Steady State (Hours 0 to 3):** 30 uninterrupted streams. JIT optimization, memory pool equilibrium, baseline metrics.
* **Phase 2: Churn & Recovery (Hours 3 to 6):** MediaMTX drops and restarts streams. Tests memory leak resilience, pipeline cleanup, and GC stability.
* **Phase 2 Active Streams Accounting Rule:**
  - **Do NOT count frames or log bucket seconds for dropped / inactive streams.**
  - Telemetry strictly records Effective FPS and accumulates stream-seconds for **active (connected) streams only**.
  - Disconnected streams awaiting reconnection backoff do not pollute the unacceptable FPS buckets with false zeroes.

### 2. Reconnection Architecture
* When a stream drops or encounters a read error, `StreamWorker` completely frees and disposes the `AVCodecContext`, `AVFormatContext`, and `SwsContext`.
* Waits **3 seconds** (`Thread.Sleep(3000)`) before attempting to reconnect to prevent OOM or thread thrashing.

### 3. "Effective FPS" Telemetry Standard (`fps_metrics.log`)
* **Unique Frames by PTS:** `VideoImageControl.Render()` checks `worker.CurrentPts != _lastPresentedPts`. Only new Presentation Timestamps increment presented frame counts, preventing UI event loop over-reporting.
* **Frame Delta ($\Delta t$):** Measures exact elapsed time between frame presentations (~40ms for 25 FPS).
* **1-Second Tick:** Active streams are evaluated every 1 second and categorized into buckets:
  - `acceptable.25_to_30_fps`: Paced (25-30 FPS, ~40ms delta)
  - `acceptable.20_to_24_fps`: Micro-Stutter (20-24 FPS, >50ms delta)
  - `unacceptable.10_to_19_fps`: Choppy (10-19 FPS, >80ms delta)
  - `unacceptable.5_to_9_fps` & `under_5_fps`: Unwatchable (<10 FPS, >100ms delta)
* **60-Second Flush:** Every 60 seconds, appends the aggregated JSON payload to `/var/log/benchmark/fps_metrics.log` (fallback to `./logs/fps_metrics.log`) and resets internal counters.

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

### 2. External OS Hardware Polling (`hardware_metrics.csv`)
- Polled every 10 seconds via `scripts/poll_hardware.sh`.
- Format: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`.
- GPU columns log `0` during pure CPU tests.

---

## Quick Start & Local Execution

### Prerequisites
- **.NET SDK 10.0+** (or 8.0+)
- **FFmpeg 6.x / 7.x / 9.x** shared libraries (`libavcodec`, `libavformat`, `libavutil`, `libswscale`)
- **MediaMTX** (for local test stream generation)

### 1. Build Application
```bash
dotnet publish -c Release -o bin/publish
```

### 2. Start Test Stream (1440p @ 25 FPS)
```bash
./scripts/start_rtsp_feed.sh
```

### 3. Run Benchmark Application
```bash
# Run with default 30 streams
dotnet bin/publish/rtsp-stress-test-csharp-cpu.dll --url rtsp://127.0.0.1:8554/live --streams 30
```

### 4. Run Headless 6-Hour Benchmark
```bash
./scripts/run_benchmark_headless.sh
```
