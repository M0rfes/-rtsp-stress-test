# 30-Camera RTSP Video Grid Benchmark (C# Avalonia GPU Zero-Copy)

This implementation fulfills the **GPU-Accelerated (Zero-Copy)** benchmark specification for C# Avalonia (.NET 10) from the root [README.md](../../README.md), [BENCHMARK_FINDINGS.md](../../BENCHMARK_FINDINGS.md) §9.0 / §9.5, and [gpu/C#/prompt.md](prompt.md).

`src/Platform.cs` holds `NofileTarget=10240` and `StreamStaggerMs=20`. `HwAccelManager` selects OS-native decode: VideoToolbox on macOS, CUDA then VA-API on Linux, CUDA then D3D11VA on Windows. Do not pass Linux VA-API/EGL flags on Darwin.

---

## Architecture

```
MediaMTX 1440p @ 25 FPS
        │ TCP × 30 (20ms stagger)
        ▼
30 × FFmpeg.AutoGen StreamWorker (LongRunning tasks)
  avformat_open_input → h264_mp4toannexb → avcodec_receive_frame
  hw_device_ctx: CUDA / VAAPI / VideoToolbox / D3D11VA
  lock-free av_frame_clone pointer swap (no managed byte[])
        │
        ▼  OnOpenGlRender only (Avalonia GL context bound)
OpenGlControlBase tiles in UniformGrid
  NV12 / YUV420P GL_R8 + GL_RG8 textures
  BT.709 fragment shaders
  CUDA-GL: cuGraphicsGLRegisterImage GPU→GPU
  VideoToolbox: CVPixelBuffer plane lock (unified memory)
```

Presentation is measured in `VideoGlControl.OnOpenGlRender` when a new PTS is acquired. HUD updates once per second. Telemetry flushes every 60s to `/var/log/benchmark/fps_metrics.log` (fallback `./logs/`).

---

## Quick start

```bash
dotnet publish -c Release -o bin/publish
../../rtsp-server/start.sh &
./scripts/run_benchmark_headed.sh
```

Headless Linux (AWS `g6` / `g4dn`, Xvfb, no `LIBGL_ALWAYS_SOFTWARE`):

```bash
export RTSP_URL="rtsp://10.0.1.50:8554/live"
export STREAM_COUNT=30
export HW_ACCEL=cuda
./scripts/run_benchmark_headless.sh
```

```bash
sudo ./scripts/setup_autostart.sh
tail -f /var/log/benchmark/fps_metrics.log
tail -f /var/log/benchmark/hardware_metrics.csv
```

Sources: [src/HwAccelManager.cs](src/HwAccelManager.cs), [src/StreamWorker.cs](src/StreamWorker.cs), [src/VideoGlControl.cs](src/VideoGlControl.cs).
