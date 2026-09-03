# 30-Camera RTSP Video Grid Benchmark (Electron CPU Software Decode)

This implementation fulfills the **CPU-Only (Software Decoding)** benchmark specification for Electron from the project `README.md` and `cpu/Electron/prompt.md`.

## Architecture Overview

1. **Node.js Backend (Main Process):**
   - Spawns FFmpeg in stream-copy mode (`-rtsp_transport tcp -i <url> -c:v copy -bsf:v h264_mp4toannexb,dump_extra=freq=keyframe -f h264 pipe:1`).
   - Demuxes 30 RTSP streams into raw Annex B H.264 Access Units (NAL units).
   - **Zero Decoding in Backend:** CPU utilization in the Node.js backend remains negligible (~0.1%).
   - Auto-reconnects seamlessly if any RTSP stream disconnects.

2. **Inter-Process Communication (IPC):**
   - High-throughput WebSocket server listening on `127.0.0.1:9999`.
   - Endpoint `/stream/:id` streams binary Access Units with a compact 9-byte header:
     - Byte 0: `isKey` (1 = IDR / SPS / PPS keyframe, 0 = delta)
     - Bytes 1..8: `timestampUs` (BigInt64BE microsecond timestamp)
     - Bytes 9..end: Raw Annex B NAL payload
   - Endpoint `/control` streams configuration, live telemetry HUD ticks, and receives 1-second ticks from the frontend.

3. **React Frontend (Renderer Process):**
   - Uses Chromium's native `VideoDecoder` API (WebCodecs) configured with `codec: 'avc1.42001e', avc: { format: 'annexb' }`.
   - Software Fallback: Hardware acceleration flags are disabled (`disable-accelerated-video-decode`, no VA-API flags), forcing Chromium to use its internal software decoder (`ffmpeg`/`libvpx`).
   - **V8 Main-Thread Protection:** 30 software decoders in Chromium can easily saturate the V8 engine if React state updates occur per frame. To eliminate main-thread blocking:
     - Zero React state updates occur on video frame events.
     - Frame counts are maintained in mutable references.
     - Video player FPS badges use direct DOM text mutations.
     - React only re-renders the dashboard status bar once per second on the telemetry tick.

4. **Rendering:**
   - Rendered directly to Canvas 2D (`ctx.drawImage(videoFrame, 0, 0, width, height)`).
   - `videoFrame.close()` is invoked immediately after each blit to eliminate memory leaks and buffer buildup.

5. **Telemetry Specification Adherence:**
   - **1-Second Tick:** Gathers painted frame counts for each of the 30 streams, categorizing them into:
     - Acceptable: `25_to_30_fps`, `20_to_24_fps`
     - Unacceptable: `10_to_19_fps`, `5_to_9_fps`, `under_5_fps`
   - **60-Second Flush:** Accumulates 1,800 stream-seconds (30 streams × 60s) and appends the exact JSON payload to `/var/log/benchmark/fps_metrics.log` (or `./logs/fps_metrics.log` fallback if running non-root), then resets counters immediately.
   - **External OS Polling Script:** `scripts/poll_hardware.sh` polls every 10 seconds and appends to `/var/log/benchmark/hardware_metrics.csv`.

---

## Quickstart (Local Development / Testing on macOS)

### 1. Prerequisites
- Node.js >= 18 (Tested on Node.js 25)
- FFmpeg (`brew install ffmpeg`)
- MediaMTX (`brew install mediamtx`) for local RTSP test feed

### 2. Start the RTSP Test Feed (1440p 25 FPS)
In a separate terminal:
```bash
npm run rtsp:feed
```
This starts MediaMTX and publishes a 2560x1440 25 FPS H.264 video feed to `rtsp://127.0.0.1:8554/live`.

### 3. Build & Run the Electron Benchmark
```bash
npm run build
npm start
```
To run in dev mode with hot reloading:
```bash
npm run dev
```

### 4. Custom Stream Count or RTSP URL
You can adjust the stream count (e.g. 4 for low-RAM machines, up to 30 for the full stress test) and stream URLs using environment variables:
```bash
STREAM_COUNT=4 npm start
# or custom remote RTSP URL:
RTSP_URL=rtsp://your-camera-ip:554/stream npm start
```

---

## Running on AWS Linux (Ubuntu Headless via Xvfb)

### 1. Install System Dependencies
```bash
sudo apt update
sudo apt install -y nodejs npm ffmpeg xvfb
```

### 2. Configure Benchmark Directory
```bash
sudo mkdir -p /var/log/benchmark
sudo chmod 777 /var/log/benchmark
```

### 3. Execute 24-Hour Benchmark
```bash
# Run the complete headless benchmark under Xvfb (with automatic hardware polling)
./scripts/run_benchmark_headless.sh
```

### 4. Monitor Metrics
```bash
# Monitor FPS performance buckets
tail -f /var/log/benchmark/fps_metrics.log

# Monitor hardware utilization (CPU %, RAM RSS MB, etc.)
tail -f /var/log/benchmark/hardware_metrics.csv
```
