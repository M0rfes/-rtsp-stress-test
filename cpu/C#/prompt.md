**Objective:** Build a C# .NET application using Avalonia UI for a 30-camera RTSP video grid. This is a CPU-only software decode benchmark.

**Architecture Constraints:**

1. **Decoding:** Use `FFmpeg.AutoGen` or `LibVLCSharp` for software decoding on background `Task` threads.
2. **Memory Management (GC Caution):** Decode frames into a pre-allocated managed `byte[]` to prevent the .NET Garbage Collector from thrashing.
3. **Rendering:** Use Avalonia's `WriteableBitmap`. Lock the frame buffer using `Lock()` and use `unsafe` pointer arithmetic (`Buffer.MemoryCopy`) to move the pixel bytes into the UI rendering buffer efficiently.

**UI Requirements:** A UniformGrid displaying 30 Image controls bound to the bitmaps.
**Telemetry:** 1-second interval FPS tick per stream. 60-second rolling window flush to a JSON payload on disk, categorizing the stream-seconds into performance buckets.
