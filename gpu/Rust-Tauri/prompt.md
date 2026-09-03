**Objective:** Build a Tauri application using Rust for the backend and React for the frontend to display a 30-camera RTSP video grid. This is a GPU-accelerated benchmark for headless Linux.

**Architecture & Zero-Copy Constraints:**

1. **Rust Backend:** Use `gstreamer-rs` (specifically `gstreamer-rtsp-server` and `gstreamer-app`) to demux 30 RTSP streams. Extract the compressed NAL units.
2. **IPC:** Do NOT use Tauri's native `invoke` commands to pass video data. Spin up a local WebSocket server in Rust and push the NAL units to the React frontend.
3. **React Frontend:** Use the native `VideoDecoder` API to decode the frames.
4. **Zero-Copy Rendering:** Render the frames to an `OffscreenCanvas` using `BitmapRenderer` (`transferFromImageBitmap`) or WebGPU to prevent CPU-to-GPU memory copies.
5. **Launch Flags:** Configure the WebKitGTK/Chromium WebView initialization in Tauri to accept VA-API hardware acceleration flags.

**UI Requirements:** Responsive CSS grid with 30 video players in React.
**Telemetry:** 1-second interval FPS tick per stream. 60-second rolling window flush to a JSON payload on disk, categorizing the stream-seconds into performance buckets.
