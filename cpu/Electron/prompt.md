**Objective:** Build an Electron application using React to display a 30-camera RTSP video grid. This is a CPU-only software decode benchmark running on headless Linux via Xvfb.

**Architecture Constraints:**

1. **Node.js Backend:** Demux 30 RTSP streams to extract compressed NAL units. Do not decode in the backend.
2. **IPC:** Stream compressed NAL units to the React frontend over WebSocket.
3. **React Frontend:** Use the `VideoDecoder` API. Because no VA-API hardware flags are passed to Chromium, it will natively fall back to its internal software decoder (libvpx/ffmpeg).
4. **Rendering:** Render the `VideoFrame` to a Canvas.
5. **Thread Caution:** 30 software decoders inside the Chromium renderer will push the V8 engine to its limits. Ensure React state updates are minimized so the main thread is not blocked.

**UI Requirements:** Responsive CSS grid displaying 30 video players.
**Telemetry:** Track the rendered FPS per stream. Flush a 60-second delta JSON file to disk containing the frame-rate buckets (25-30, 20-24, 10-19, 5-9, <5) across all 30 streams.
