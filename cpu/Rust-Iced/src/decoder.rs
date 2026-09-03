use arc_swap::ArcSwap;
use bytes::Bytes;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use iced::widget::image::Handle;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use yuv::{yuv420_to_rgba, YuvPlanarImage, YuvRange, YuvStandardMatrix};

#[derive(Clone)]
#[allow(dead_code)]
pub struct FrameData {
    pub width: u32,
    pub height: u32,
    pub pixels: Bytes,
    pub handle: Handle,
    pub timestamp_us: u64,
}

pub struct StreamSlot {
    pub stream_id: usize,
    pub rtsp_url: String,
    pub frame: Arc<ArcSwap<Option<Arc<FrameData>>>>,
    pub raw_allocation: Arc<RwLock<Vec<u8>>>,
    pub decoded_frames: Arc<AtomicU64>,
    pub painted_frames: Arc<AtomicU64>,
    pub last_sec_frames: Arc<AtomicU32>, // True stream FPS: frames decoded & presented this second
    pub is_connected: Arc<AtomicBool>,
    pub resolution: Arc<RwLock<(u32, u32)>>,
}

impl StreamSlot {
    pub fn new(stream_id: usize, rtsp_url: String, default_w: u32, default_h: u32) -> Self {
        let initial_buf_size = (default_w * default_h * 4) as usize;
        Self {
            stream_id,
            rtsp_url,
            frame: Arc::new(ArcSwap::from_pointee(None)),
            raw_allocation: Arc::new(RwLock::new(vec![0u8; initial_buf_size])),
            decoded_frames: Arc::new(AtomicU64::new(0)),
            painted_frames: Arc::new(AtomicU64::new(0)),
            last_sec_frames: Arc::new(AtomicU32::new(0)),
            is_connected: Arc::new(AtomicBool::new(false)),
            resolution: Arc::new(RwLock::new((default_w, default_h))),
        }
    }

    pub fn get_current_frame(&self) -> Option<Arc<FrameData>> {
        (**self.frame.load()).clone()
    }

    pub fn mark_painted(&self) {
        self.painted_frames.fetch_add(1, Ordering::Relaxed);
    }

    pub fn take_last_sec_frames(&self) -> u32 {
        self.last_sec_frames.swap(0, Ordering::Relaxed)
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
        default_w: u32,
        default_h: u32,
    ) -> Self {
        let mut slots = Vec::with_capacity(stream_count);
        for i in 0..stream_count {
            let url = get_url(i);
            slots.push(Arc::new(StreamSlot::new(i, url, default_w, default_h)));
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
                    // Stagger startup slightly (30ms per stream) to prevent thundering-herd on MediaMTX/RTSP server
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

    pub fn collect_fps_tick(&self) -> Vec<u32> {
        self.slots
            .iter()
            .map(|slot| slot.take_last_sec_frames())
            .collect()
    }
}

fn run_decoder_loop(slot: Arc<StreamSlot>, is_running: Arc<AtomicBool>) {
    let stream_id = slot.stream_id;
    let rtsp_url = &slot.rtsp_url;
    let start_time = Instant::now();

    while is_running.load(Ordering::SeqCst) {
        // Robust CPU Software Decoding Pipeline:
        // rtspsrc (TCP, 100ms latency, drop-on-latency) -> rtph264depay -> h264parse -> avdec_h264 -> I420 -> appsink
        let pipeline_desc = format!(
            "rtspsrc location=\"{}\" protocols=tcp latency=100 drop-on-latency=true ! \
             rtph264depay ! \
             h264parse ! \
             avdec_h264 ! \
             video/x-raw,format=I420 ! \
             appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false",
            rtsp_url
        );

        let pipeline = match gst::parse::launch(&pipeline_desc) {
            Ok(elem) => match elem.dynamic_cast::<gst::Pipeline>() {
                Ok(pipe) => pipe,
                Err(_) => {
                    eprintln!("[Decoder {}] Launched element is not a gst::Pipeline", stream_id);
                    std::thread::sleep(Duration::from_secs(2));
                    continue;
                }
            },
            Err(e) => {
                eprintln!("[Decoder {}] Failed to create pipeline: {}", stream_id, e);
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };

        let appsink = match pipeline.by_name("sink") {
            Some(elem) => match elem.dynamic_cast::<gst_app::AppSink>() {
                Ok(sink) => sink,
                Err(_) => {
                    eprintln!("[Decoder {}] 'sink' element is not an AppSink", stream_id);
                    std::thread::sleep(Duration::from_secs(2));
                    continue;
                }
            },
            None => {
                eprintln!("[Decoder {}] Could not find 'sink' element", stream_id);
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };

        if let Err(e) = pipeline.set_state(gst::State::Playing) {
            eprintln!("[Decoder {}] Failed to set Playing state: {}", stream_id, e);
            std::thread::sleep(Duration::from_secs(2));
            continue;
        }

        slot.is_connected.store(true, Ordering::Relaxed);
        println!("[Decoder {}] Pipeline running for {}", stream_id, rtsp_url);

        let mut width = 2560u32;
        let mut height = 1440u32;
        let mut rgba_scratch = vec![0u8; (width * height * 4) as usize];

        while is_running.load(Ordering::Relaxed) {
            match appsink.pull_sample() {
                Ok(sample) => {
                    let buffer = match sample.buffer() {
                        Some(b) => b,
                        None => continue,
                    };

                    let map = match buffer.map_readable() {
                        Ok(m) => m,
                        Err(_) => continue,
                    };
                    let raw_bytes = map.as_slice();

                    if let Some(caps) = sample.caps() {
                        if let Some(structure) = caps.structure(0) {
                            if let Ok(w) = structure.get::<i32>("width") {
                                width = w as u32;
                            }
                            if let Ok(h) = structure.get::<i32>("height") {
                                height = h as u32;
                            }
                        }
                    }

                    let y_size = (width * height) as usize;
                    let uv_size = ((width / 2) * (height / 2)) as usize;
                    let total_i420_size = y_size + 2 * uv_size;

                    if raw_bytes.len() < total_i420_size {
                        continue;
                    }

                    // Update resolution cache
                    {
                        let mut res = slot.resolution.write().unwrap();
                        if res.0 != width || res.1 != height {
                            *res = (width, height);
                        }
                    }

                    let required_rgba_len = (width * height * 4) as usize;
                    if rgba_scratch.len() != required_rgba_len {
                        rgba_scratch.resize(required_rgba_len, 0);
                    }

                    // Perform SIMD YUV420 to RGBA color conversion on background thread
                    let planar = YuvPlanarImage {
                        y_plane: &raw_bytes[..y_size],
                        y_stride: width,
                        u_plane: &raw_bytes[y_size..y_size + uv_size],
                        u_stride: width / 2,
                        v_plane: &raw_bytes[y_size + uv_size..total_i420_size],
                        v_stride: width / 2,
                        width,
                        height,
                    };

                    if let Err(e) = yuv420_to_rgba(
                        &planar,
                        &mut rgba_scratch,
                        width * 4,
                        YuvRange::Limited,
                        YuvStandardMatrix::Bt709,
                    ) {
                        eprintln!("[Decoder {}] SIMD YUV->RGBA conversion error: {:?}", stream_id, e);
                        continue;
                    }

                    // Write to pre-allocated Arc<RwLock<Vec<u8>>> buffer per specification
                    if let Ok(mut raw_lock) = slot.raw_allocation.write() {
                        if raw_lock.len() != rgba_scratch.len() {
                            raw_lock.resize(rgba_scratch.len(), 0);
                        }
                        raw_lock.copy_from_slice(&rgba_scratch);
                    }

                    // Lock-free handoff to UI thread via ArcSwap
                    let pixels = Bytes::copy_from_slice(&rgba_scratch);
                    let handle = Handle::from_rgba(width, height, pixels.clone());
                    let timestamp_us = start_time.elapsed().as_micros() as u64;

                    let frame_data = Arc::new(FrameData {
                        width,
                        height,
                        pixels,
                        handle,
                        timestamp_us,
                    });

                    slot.frame.store(Arc::new(Some(frame_data)));
                    slot.decoded_frames.fetch_add(1, Ordering::Relaxed);
                    // Accurately record decoded & presented video frame for 1-second FPS metric
                    slot.last_sec_frames.fetch_add(1, Ordering::Relaxed);
                }
                Err(_) => {
                    eprintln!("[Decoder {}] Stream disconnected or EOS received. Reconnecting...", stream_id);
                    break;
                }
            }
        }

        slot.is_connected.store(false, Ordering::Relaxed);
        let _ = pipeline.set_state(gst::State::Null);

        if is_running.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(1000));
        }
    }

    println!("[Decoder {}] Worker thread exiting cleanly", stream_id);
}
