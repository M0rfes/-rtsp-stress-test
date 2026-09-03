**Objective:** Build a pure Rust native GUI application using the `iced` framework to display a 30-camera RTSP video grid. This is a GPU-accelerated zero-copy benchmark.

**Architecture & Zero-Copy Constraints:**

1. **Decoding:** Use `gstreamer-rs` configured with the `nvdec` (Nvidia hardware decode) plugin.
2. **Zero-Copy Rendering:** Initialize Iced with the `iced_wgpu` backend. Extract the decoded OpenGL/Vulkan texture ID directly from GStreamer's VRAM pool. Map this texture ID to a `wgpu::Texture` handle.
3. **Integration:** Use the `iced::widget::shader` module or a custom WGPU primitive to inject these 30 hardware textures directly into the Iced widget tree without ever pulling the pixel data into CPU RAM.

**UI Requirements:** A responsive grid layout in Iced containing the 30 texture widgets.
**Telemetry:** 1-second interval FPS tick per stream. 60-second rolling window flush to a JSON payload on disk, categorizing the stream-seconds into performance buckets.
