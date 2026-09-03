**Objective:** Build a Tauri application using Rust and React for a 30-camera RTSP video grid. This is a CPU-only software decode benchmark.

**Architecture Constraints:**

1. **Rust Backend:** Use `gstreamer-rs` to demux 30 RTSP streams into NAL units.
2. **IPC:** Push compressed NAL units to React via a local WebSocket.
3. **React Frontend:** Use `VideoDecoder`. Ensure no hardware-acceleration flags are passed to the Tauri WebView, forcing it into software fallback.
4. **Rendering:** Render to HTML5 Canvas.

**UI Requirements:** Responsive CSS grid in React.
**Telemetry:** 1-second interval FPS tick per stream. 60-second rolling window flush to a JSON payload on disk, categorizing the stream-seconds into performance buckets.
