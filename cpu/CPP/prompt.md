**Objective:** Build a native C++ Qt6 application to display a 30-camera RTSP video grid. This is a CPU-only software decoding benchmark.

**Architecture Constraints:**

1. **Decoding:** Use `libavcodec` software decoding on dedicated background QThreads.
2. **Color Conversion:** The CPU will decode into YUV planar memory. Use `libswscale` to convert this to RGB32 format.
3. **Memory Management:** Instantiate the `QImage` directly on top of the pre-allocated RGB32 buffer to avoid a deep copy within the CPU RAM.
4. **Rendering:** Blit the `QImage` via `QPainter` onto a `QWidget` or `QGraphicsView` inside the main UI thread.

**UI Requirements:** A QGridLayout containing 30 widgets.
**Telemetry:** 1-second interval FPS tick per stream. 60-second rolling window flush to a JSON payload on disk, categorizing the stream-seconds into performance buckets.
