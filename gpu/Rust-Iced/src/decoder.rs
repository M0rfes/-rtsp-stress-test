use arc_swap::ArcSwap;
use bytes::Bytes;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use gstreamer_gl as gst_gl;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

#[allow(dead_code)]
#[derive(Clone, Debug)]
pub struct GpuFrameData {
    pub width: u32,
    pub height: u32,
    pub texture_id: Option<u32>,
    pub rgba_pixels: Option<Bytes>,
    pub nv12_planes: Option<(Bytes, Bytes)>,
    pub gst_buffer: Option<gst::Buffer>,
    pub timestamp_us: u64,
}

pub struct StreamSlot {
    pub stream_id: usize,
    pub rtsp_url: String,
    pub decoder_plugin: String,
    pub frame: Arc<ArcSwap<Option<Arc<GpuFrameData>>>>,
    pub decoded_frames: Arc<AtomicU64>,
    pub painted_frames: Arc<AtomicU64>,
    pub last_sec_frames: Arc<AtomicU32>,
    pub last_delta_ms: Arc<AtomicU32>,
    pub is_connected: Arc<AtomicBool>,
    pub resolution: Arc<RwLock<(u32, u32)>>,
}

impl StreamSlot {
    pub fn new(stream_id: usize, rtsp_url: String, decoder_plugin: String, default_w: u32, default_h: u32) -> Self {
        Self {
            stream_id,
            rtsp_url,
            decoder_plugin,
            frame: Arc::new(ArcSwap::from_pointee(None)),
            decoded_frames: Arc::new(AtomicU64::new(0)),
            painted_frames: Arc::new(AtomicU64::new(0)),
            last_sec_frames: Arc::new(AtomicU32::new(0)),
            last_delta_ms: Arc::new(AtomicU32::new(0)),
            is_connected: Arc::new(AtomicBool::new(false)),
            resolution: Arc::new(RwLock::new((default_w, default_h))),
        }
    }

    pub fn get_current_frame(&self) -> Option<Arc<GpuFrameData>> {
        (**self.frame.load()).clone()
    }

    pub fn mark_painted(&self) {
        self.painted_frames.fetch_add(1, Ordering::Relaxed);
    }

    pub fn take_last_sec_frames(&self) -> u32 {
        self.last_sec_frames.swap(0, Ordering::Relaxed)
    }

    #[allow(dead_code)]
    pub fn get_last_delta_ms(&self) -> f32 {
        f32::from_bits(self.last_delta_ms.load(Ordering::Relaxed))
    }
}

pub struct StreamManager {
    pub slots: Vec<Arc<StreamSlot>>,
    is_running: Arc<AtomicBool>,
}

impl StreamManager {
    pub fn new(
        stream_count: usize,
        get_url: impl Fn(usize) -> String,
        decoder_plugin: String,
        default_w: u32,
        default_h: u32,
    ) -> Self {
        let mut slots = Vec::with_capacity(stream_count);
        for i in 0..stream_count {
            let url = get_url(i);
            slots.push(Arc::new(StreamSlot::new(
                i,
                url,
                decoder_plugin.clone(),
                default_w,
                default_h,
            )));
        }

        Self {
            slots,
            is_running: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn start_all(&self) {
        if self.is_running.swap(true, Ordering::SeqCst) {
            return;
        }

        for (i, slot) in self.slots.iter().enumerate() {
            let slot_clone = slot.clone();
            let is_running_clone = self.is_running.clone();

            std::thread::Builder::new()
                .name(format!("rtsp-dec-{}", slot.stream_id))
                .spawn(move || {
                    // Stagger startup (30ms per stream) to prevent thundering-herd on RTSP server
                    std::thread::sleep(Duration::from_millis((i * 30) as u64));
                    run_decoder_loop(slot_clone, is_running_clone);
                })
                .expect("Failed to spawn RTSP decoder worker thread");
        }
    }

    #[allow(dead_code)]
    pub fn stop_all(&self) {
        self.is_running.store(false, Ordering::SeqCst);
    }

    #[allow(dead_code)]
    pub fn collect_fps_tick(&self) -> Vec<u32> {
        self.slots
            .iter()
            .map(|slot| slot.take_last_sec_frames())
            .collect()
    }

    pub fn collect_metrics_tick(&self) -> Vec<(u32, bool)> {
        self.slots
            .iter()
            .map(|slot| (slot.take_last_sec_frames(), slot.is_connected.load(Ordering::Relaxed)))
            .collect()
    }
}

fn run_decoder_loop(slot: Arc<StreamSlot>, is_running: Arc<AtomicBool>) {
    let stream_id = slot.stream_id;
    let rtsp_url = &slot.rtsp_url;
    let decoder = &slot.decoder_plugin;
    let start_time = Instant::now();

    while is_running.load(Ordering::SeqCst) {
        // Construct hardware decode pipeline:
        // Construct hardware decode pipeline:
        // On Linux / Nvidia: nvdec -> glupload -> glcolorconvert -> appsink (GLMemory)
        // On Windows: d3d11h264dec -> video/x-raw,format=NV12 -> appsink
        // On macOS: vtdec -> video/x-raw,format=NV12 -> appsink (zero-copy hardware decode to NV12)
        // Fallback: avdec_h264 -> video/x-raw,format=NV12 -> appsink
        let pipeline_desc = if decoder == "nvdec" {
            format!(
                "rtspsrc location=\"{}\" protocols=tcp latency=100 drop-on-latency=true ! \
                 rtph264depay ! \
                 h264parse ! \
                 nvdec ! \
                 glupload ! \
                 glcolorconvert ! \
                 video/x-raw(memory:GLMemory),format=RGBA ! \
                 appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false",
                rtsp_url
            )
        } else if decoder == "d3d11h264dec" {
            format!(
                "rtspsrc location=\"{}\" protocols=tcp latency=100 drop-on-latency=true ! \
                 rtph264depay ! \
                 h264parse ! \
                 d3d11h264dec ! \
                 video/x-raw,format=NV12 ! \
                 appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false",
                rtsp_url
            )
        } else if decoder == "vtdec" {
            format!(
                "rtspsrc location=\"{}\" protocols=tcp latency=100 drop-on-latency=true ! \
                 rtph264depay ! \
                 h264parse ! \
                 vtdec ! \
                 video/x-raw,format=NV12 ! \
                 appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false",
                rtsp_url
            )
        } else {
            // Software decode fallback
            format!(
                "rtspsrc location=\"{}\" protocols=tcp latency=100 drop-on-latency=true ! \
                 rtph264depay ! \
                 h264parse ! \
                 avdec_h264 ! \
                 video/x-raw,format=NV12 ! \
                 appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false",
                rtsp_url
            )
        };

        let pipeline = match gst::parse::launch(&pipeline_desc) {
            Ok(elem) => match elem.dynamic_cast::<gst::Pipeline>() {
                Ok(pipe) => pipe,
                Err(_) => {
                    eprintln!("[Decoder {}] Element is not a gst::Pipeline", stream_id);
                    std::thread::sleep(Duration::from_secs(2));
                    continue;
                }
            },
            Err(e) => {
                eprintln!("[Decoder {}] Pipeline launch failed: {}. Retrying in 3s...", stream_id, e);
                std::thread::sleep(Duration::from_secs(3));
                continue;
            }
        };

        let appsink = match pipeline.by_name("sink") {
            Some(elem) => match elem.dynamic_cast::<gst_app::AppSink>() {
                Ok(sink) => sink,
                Err(_) => {
                    eprintln!("[Decoder {}] 'sink' element is not an AppSink", stream_id);
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
            },
            None => {
                eprintln!("[Decoder {}] Could not find 'sink' element", stream_id);
                std::thread::sleep(Duration::from_secs(3));
                continue;
            }
        };

        if let Err(e) = pipeline.set_state(gst::State::Playing) {
            eprintln!("[Decoder {}] Failed to set Playing state: {}", stream_id, e);
            std::thread::sleep(Duration::from_secs(3));
            continue;
        }

        slot.is_connected.store(true, Ordering::Relaxed);
        println!("[Decoder {}] Pipeline running for {} (Decoder: {})", stream_id, rtsp_url, decoder);

        let mut width = 2560u32;
        let mut height = 1440u32;
        let mut last_pts: Option<gst::ClockTime> = None;
        let mut last_frame_instant: Option<Instant> = None;

        while is_running.load(Ordering::Relaxed) {
            match appsink.pull_sample() {
                Ok(sample) => {
                    let buffer = match sample.buffer() {
                        Some(b) => b,
                        None => continue,
                    };

                    // Effective FPS: Presentation Timestamp (PTS) uniqueness check
                    let pts = buffer.pts();
                    if let (Some(cur), Some(last)) = (pts, last_pts) {
                        if cur == last {
                            continue;
                        }
                    }
                    last_pts = pts;

                    // Frame pacing delta timing (tn - tn-1)
                    let now = Instant::now();
                    if let Some(prev) = last_frame_instant {
                        let delta_ms = now.duration_since(prev).as_secs_f32() * 1000.0;
                        slot.last_delta_ms.store(delta_ms.to_bits(), Ordering::Relaxed);
                    }
                    last_frame_instant = Some(now);

                    let mut is_nv12 = false;
                    if let Some(caps) = sample.caps() {
                        if let Some(structure) = caps.structure(0) {
                            if let Ok(w) = structure.get::<i32>("width") {
                                width = w as u32;
                            }
                            if let Ok(h) = structure.get::<i32>("height") {
                                height = h as u32;
                            }
                            if let Ok(fmt) = structure.get::<&str>("format") {
                                is_nv12 = fmt == "NV12";
                            }
                        }
                    }

                    // Update resolution cache
                    {
                        let mut res = slot.resolution.write().unwrap();
                        if res.0 != width || res.1 != height {
                            *res = (width, height);
                        }
                    }

                    let mut tex_id = None;
                    let mut rgba_pixels = None;
                    let mut nv12_planes = None;

                    // 1. Try zero-copy OpenGL/Vulkan texture extraction from GStreamer VRAM pool
                    if buffer.n_memory() > 0 {
                        let mem = buffer.peek_memory(0);
                        if let Some(gl_mem) = mem.downcast_memory_ref::<gst_gl::GLMemory>() {
                            tex_id = Some(gl_mem.texture_id());
                        }
                    }

                    // 2. Map buffer memory:
                    if let Ok(map) = buffer.map_readable() {
                        if is_nv12 {
                            let y_len = (width * height) as usize;
                            let uv_len = (width * height / 2) as usize;
                            if map.len() >= y_len + uv_len {
                                let y_plane = Bytes::copy_from_slice(&map[..y_len]);
                                let uv_plane = Bytes::copy_from_slice(&map[y_len..y_len + uv_len]);
                                nv12_planes = Some((y_plane, uv_plane));
                            }
                        } else {
                            let expected_len = (width * height * 4) as usize;
                            if map.len() >= expected_len {
                                rgba_pixels = Some(Bytes::copy_from_slice(&map[..expected_len]));
                            }
                        }
                    }

                    let timestamp_us = start_time.elapsed().as_micros() as u64;

                    let gpu_frame = Arc::new(GpuFrameData {
                        width,
                        height,
                        texture_id: tex_id,
                        rgba_pixels,
                        nv12_planes,
                        gst_buffer: Some(buffer.to_owned()),
                        timestamp_us,
                    });

                    // Lock-free atomic handoff to WGPU renderer
                    slot.frame.store(Arc::new(Some(gpu_frame)));
                    slot.decoded_frames.fetch_add(1, Ordering::Relaxed);
                    slot.last_sec_frames.fetch_add(1, Ordering::Relaxed);
                }
                Err(_) => {
                    eprintln!("[Decoder {}] Stream disconnected or EOS received. Reconnecting...", stream_id);
                    break;
                }
            }
        }

        slot.is_connected.store(false, Ordering::Relaxed);
        slot.frame.store(Arc::new(None));
        let _ = pipeline.set_state(gst::State::Null);

        if is_running.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_secs(3));
        }
    }

    println!("[Decoder {}] Worker thread exiting cleanly", stream_id);
}
