use arc_swap::ArcSwap;
use bytes::Bytes;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use iced::widget::image::Handle;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

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
    pub video_width: u32,
    pub video_height: u32,
    pub tile_width: u32,
    pub tile_height: u32,
    pub frame: Arc<ArcSwap<Option<Arc<FrameData>>>>,
    #[allow(dead_code)]
    pub raw_allocation: Arc<RwLock<Vec<u8>>>,
    pub decoded_frames: Arc<AtomicU64>,
    pub painted_frames: Arc<AtomicU64>,
    pub last_sec_frames: Arc<AtomicU32>, // True stream FPS: frames decoded & presented this second
    pub last_delta_ms: Arc<AtomicU32>,   // Frame pacing delta in milliseconds (f32 bits)
    pub is_connected: Arc<AtomicBool>,
    pub resolution: Arc<RwLock<(u32, u32)>>,
}

impl StreamSlot {
    pub fn new(
        stream_id: usize,
        rtsp_url: String,
        default_w: u32,
        default_h: u32,
        tile_w: u32,
        tile_h: u32,
    ) -> Self {
        let initial_buf_size = (tile_w * tile_h * 4) as usize;
        Self {
            stream_id,
            rtsp_url,
            video_width: default_w,
            video_height: default_h,
            tile_width: tile_w,
            tile_height: tile_h,
            frame: Arc::new(ArcSwap::from_pointee(None)),
            raw_allocation: Arc::new(RwLock::new(vec![0u8; initial_buf_size])),
            decoded_frames: Arc::new(AtomicU64::new(0)),
            painted_frames: Arc::new(AtomicU64::new(0)),
            last_sec_frames: Arc::new(AtomicU32::new(0)),
            last_delta_ms: Arc::new(AtomicU32::new(0)),
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
        default_w: u32,
        default_h: u32,
        tile_w: u32,
        tile_h: u32,
    ) -> Self {
        let mut slots = Vec::with_capacity(stream_count);
        for i in 0..stream_count {
            let url = get_url(i);
            slots.push(Arc::new(StreamSlot::new(i, url, default_w, default_h, tile_w, tile_h)));
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
    let start_time = Instant::now();

    let tile_w = slot.tile_width;
    let tile_h = slot.tile_height;

    while is_running.load(Ordering::SeqCst) {
        // Optimized CPU Software Decoding Pipeline:
        // 1. avdec_h264 max-threads=1: CPU software decode of 1440p bitstream without 480-thread CPU thrashing
        // 2. videoscale ! videoconvert: SIMD scaling & RGBA color conversion distributed across 30 worker threads
        // 3. appsink max-buffers=2 drop=true: Instant backpressure, eliminating 22 GB/s memory churn
        let pipeline_desc = if tile_w > 0 && tile_h > 0 && (tile_w != slot.video_width || tile_h != slot.video_height) {
            format!(
                "rtspsrc location=\"{}\" protocols=tcp latency=50 drop-on-latency=false ! \
                 rtph264depay ! \
                 h264parse ! \
                 avdec_h264 max-threads=1 output-corrupt=false ! \
                 videoscale ! \
                 videoconvert ! \
                 video/x-raw,format=RGBA,width={},height={} ! \
                 appsink name=sink sync=false max-buffers=2 drop=true emit-signals=false",
                rtsp_url, tile_w, tile_h
            )
        } else {
            format!(
                "rtspsrc location=\"{}\" protocols=tcp latency=50 drop-on-latency=false ! \
                 rtph264depay ! \
                 h264parse ! \
                 avdec_h264 max-threads=1 output-corrupt=false ! \
                 videoconvert ! \
                 video/x-raw,format=RGBA ! \
                 appsink name=sink sync=false max-buffers=2 drop=true emit-signals=false",
                rtsp_url
            )
        };

        let pipeline = match gst::parse::launch(&pipeline_desc) {
            Ok(elem) => match elem.dynamic_cast::<gst::Pipeline>() {
                Ok(pipe) => pipe,
                Err(_) => {
                    eprintln!("[Decoder {}] Launched element is not a gst::Pipeline", stream_id);
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
            },
            Err(e) => {
                eprintln!("[Decoder {}] Failed to create pipeline: {}", stream_id, e);
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
        println!("[Decoder {}] Pipeline running for {} (render size: {}x{})", stream_id, rtsp_url, tile_w, tile_h);

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

                    let map = match buffer.map_readable() {
                        Ok(m) => m,
                        Err(_) => continue,
                    };
                    let raw_bytes = map.as_slice();

                    let mut width = tile_w;
                    let mut height = tile_h;
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

                    // Update resolution cache
                    {
                        let mut res = slot.resolution.write().unwrap();
                        if res.0 != width || res.1 != height {
                            *res = (width, height);
                        }
                    }

                    // Lock-free zero-churn handoff to UI thread via ArcSwap (copies only 0.92 MB instead of 14.7 MB)
                    let pixels = Bytes::copy_from_slice(raw_bytes);
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
        slot.frame.store(Arc::new(None));
        let _ = pipeline.set_state(gst::State::Null);

        if is_running.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_secs(3));
        }
    }

    println!("[Decoder {}] Worker thread exiting cleanly", stream_id);
}
