**Objective:** Build an Electron application using React for the frontend to display a 30-camera RTSP video grid. This is a GPU-accelerated hardware decode benchmark running on headless Linux via Xvfb.

**Architecture & Zero-Copy Constraints:**

1. **Node.js Backend:** Connect to 30 RTSP streams. Do NOT decode the video in Node.js. Demux the streams to extract raw, compressed H.264/H.265 NAL units.
2. **IPC:** Stream the compressed NAL units to the React frontend over a local WebSocket. Do not use Electron IPC for high-frequency video data.
3. **React Frontend:** Use the browser's native `VideoDecoder` API to hardware-decode the NAL units.
4. **Zero-Copy Rendering:** Render the `VideoFrame` objects to an `OffscreenCanvas`. You MUST use the `BitmapRenderer` context (`transferFromImageBitmap`) or WebGPU (`importExternalTexture`) to ensure zero-copy GPU-to-GPU transfer. Do not use Canvas 2D `drawImage`.
5. **Launch Flags:** The Electron launch script must include Chromium flags to force VA-API translation on Nvidia: `--enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiOnNvidiaGPUs`, `--use-gl=egl`, and `--disable-software-rasterizer`.

**UI Requirements:** A responsive CSS grid displaying 30 video players.
**Telemetry:** Track the exact frames rendered per second for each of the 30 streams independently. Every 60 seconds, flush a JSON file to disk showing the "time in state" (e.g., how many stream-seconds were at 25-30 FPS vs under 5 FPS) and reset the counters.
