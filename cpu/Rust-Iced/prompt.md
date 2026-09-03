**Objective:** Build a pure Rust native GUI application using `iced` for a 30-camera RTSP video grid. This is a CPU-only software decode benchmark.

**Architecture Constraints:**

1. **Decoding:** Use `gstreamer-rs` or `ffmpeg-next` to software-decode the 30 streams on a dedicated thread pool.
2. **Color Conversion:** Perform YUV-to-RGB byte conversion using efficient SIMD instructions on the background threads.
3. **Lock-Free Handoff:** Wrap the massive uncompressed RGB frame allocations in `Arc<RwLock<[u8]>>` (or a lock-free ring buffer). Do NOT use standard Mutexes, as 30 concurrent decoders will create massive lock contention and stall the Iced UI thread.
4. **Rendering:** Force Iced to use the `tiny-skia` software rendering backend to blit the pixel arrays to the OS window manager.

**UI Requirements:** A responsive grid layout in Iced.
**Telemetry:** 1-second interval FPS tick per stream. 60-second rolling window flush to a JSON payload on disk, categorizing the stream-seconds into performance buckets.
