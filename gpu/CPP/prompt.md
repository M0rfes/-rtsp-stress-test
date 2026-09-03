**Objective:** Build a native C++ Qt6 application to display a 30-camera RTSP video grid. This is a GPU-accelerated zero-copy benchmark.

**Architecture & Zero-Copy Constraints:**

1. **Decoding:** Use `libavcodec` (FFmpeg) to connect to and decode 30 RTSP streams.
2. **Hardware Acceleration:** You MUST configure `libavcodec` to use `AV_HWDEVICE_TYPE_VAAPI` or `CUDA` to decode the video directly into GPU VRAM.
3. **Zero-Copy Rendering:** Do NOT copy the decoded YUV frames back to system RAM. Map the hardware-decoded surface handle directly to a Qt Rendering Hardware Interface (RHI) node or a custom `QOpenGLWidget`.
4. **Threading:** Run the FFmpeg demux/decode loops on dedicated background QThreads.

**UI Requirements:** A QGridLayout containing 30 hardware-accelerated rendering widgets.
**Telemetry:** Track the exact frames painted per second for each of the 30 streams independently. Every 60 seconds, flush a JSON file to disk showing the stream-second performance buckets, then reset the counters.
