**Objective:** Build a cross-platform C# .NET application using Avalonia UI to display a 30-camera RTSP video grid. This is a GPU-accelerated zero-copy benchmark.

**Architecture & Zero-Copy Constraints:**

1. **Decoding:** Use `FFmpeg.AutoGen`. Configure the decoder explicitly for hardware acceleration (`hwaccel cuda` or `hwaccel vaapi`).
2. **Zero-Copy Rendering:** Do not pull the frames into a managed `byte[]`. Create a custom control inheriting from Avalonia's `OpenGlControlBase`.
3. **Context Synchronization:** You must strictly handle Avalonia's `OnOpenGlInit`, `OnOpenGlRender`, and `OnOpenGlDeinit` overrides. Inject the raw FFmpeg OpenGL texture ID into the UI tree. Do not attempt to write texture data from an external FFmpeg thread without locking the Avalonia OpenGL context first.

**UI Requirements:** A UniformGrid containing the 30 OpenGL controls.
**Telemetry:** 1-second interval FPS tick per stream. 60-second rolling window flush to a JSON payload on disk, categorizing the stream-seconds into performance buckets.
