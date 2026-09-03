use bytes::Bytes;
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct StreamBroadcaster {
    pub sender: broadcast::Sender<Bytes>,
}

pub struct StreamDemuxer {
    pub stream_id: usize,
    pub rtsp_url: String,
    broadcaster: StreamBroadcaster,
    is_running: Arc<AtomicBool>,
}

impl StreamDemuxer {
    pub fn new(stream_id: usize, rtsp_url: String, capacity: usize) -> (Self, broadcast::Receiver<Bytes>) {
        let (sender, receiver) = broadcast::channel(capacity);
        let broadcaster = StreamBroadcaster { sender };
        let is_running = Arc::new(AtomicBool::new(false));

        (
            Self {
                stream_id,
                rtsp_url,
                broadcaster,
                is_running,
            },
            receiver,
        )
    }

    pub fn get_broadcaster(&self) -> StreamBroadcaster {
        self.broadcaster.clone()
    }

    pub fn start(&self) {
        if self.is_running.swap(true, Ordering::SeqCst) {
            return;
        }

        let stream_id = self.stream_id;
        let rtsp_url = self.rtsp_url.clone();
        let is_running = self.is_running.clone();
        let sender = self.broadcaster.sender.clone();

        std::thread::Builder::new()
            .name(format!("rtsp-demuxer-{}", stream_id))
            .spawn(move || {
                run_pipeline_loop(stream_id, &rtsp_url, is_running, sender);
            })
            .expect("Failed to spawn RTSP demuxer thread");
    }

    pub fn stop(&self) {
        self.is_running.store(false, Ordering::SeqCst);
    }
}

fn run_pipeline_loop(
    stream_id: usize,
    rtsp_url: &str,
    is_running: Arc<AtomicBool>,
    sender: broadcast::Sender<Bytes>,
) {
    let mut cached_codec_data: Option<Vec<u8>> = None;
    let start_instant = Instant::now();

    while is_running.load(Ordering::SeqCst) {
        // Output native AVCC format with AU alignment for zero-overhead browser decode
        let pipeline_desc = format!(
            "rtspsrc location=\"{}\" protocols=tcp latency=0 drop-on-latency=true ! \
             rtph264depay ! \
             h264parse config-interval=-1 ! \
             video/x-h264,stream-format=avc,alignment=au ! \
             appsink name=sink sync=false max-buffers=5 drop=true emit-signals=false",
            rtsp_url
        );

        let pipeline = match gst::parse::launch(&pipeline_desc) {
            Ok(element) => match element.dynamic_cast::<gst::Pipeline>() {
                Ok(pipeline) => pipeline,
                Err(_) => {
                    eprintln!("[Demuxer {}] Element is not a gst::Pipeline", stream_id);
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    continue;
                }
            },
            Err(err) => {
                eprintln!("[Demuxer {}] Failed to create pipeline: {}", stream_id, err);
                std::thread::sleep(std::time::Duration::from_secs(2));
                continue;
            }
        };

        let appsink = match pipeline.by_name("sink") {
            Some(element) => match element.dynamic_cast::<gst_app::AppSink>() {
                Ok(sink) => sink,
                Err(_) => {
                    eprintln!("[Demuxer {}] Failed to cast 'sink' to AppSink", stream_id);
                    let _ = pipeline.set_state(gst::State::Null);
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    continue;
                }
            },
            None => {
                eprintln!("[Demuxer {}] 'sink' element not found in pipeline", stream_id);
                let _ = pipeline.set_state(gst::State::Null);
                std::thread::sleep(std::time::Duration::from_secs(2));
                continue;
            }
        };

        if let Err(err) = pipeline.set_state(gst::State::Playing) {
            eprintln!("[Demuxer {}] Failed to set pipeline to Playing: {}", stream_id, err);
            let _ = pipeline.set_state(gst::State::Null);
            std::thread::sleep(std::time::Duration::from_secs(2));
            continue;
        }

        println!("[Demuxer {}] Pipeline playing: {}", stream_id, rtsp_url);

        while is_running.load(Ordering::SeqCst) {
            match appsink.pull_sample() {
                Ok(sample) => {
                    // Extract AVCC codec_data (AVCDecoderConfigurationRecord) from caps if available
                    if cached_codec_data.is_none() {
                        if let Some(caps) = sample.caps() {
                            if let Some(s) = caps.structure(0) {
                                if let Ok(cd_buf) = s.get::<gst::Buffer>("codec_data") {
                                    if let Ok(map) = cd_buf.map_readable() {
                                        cached_codec_data = Some(map.as_slice().to_vec());
                                    }
                                }
                            }
                        }
                    }

                    if let Some(buffer) = sample.buffer() {
                        if let Ok(map) = buffer.map_readable() {
                            let raw_bytes = map.as_slice();
                            let is_delta_flag = buffer.flags().contains(gst::BufferFlags::DELTA_UNIT);
                            let is_key = !is_delta_flag;

                            // Calculate timestamp in microseconds
                            let timestamp_us = buffer
                                .pts()
                                .map(|p| p.nseconds() / 1_000)
                                .unwrap_or_else(|| start_instant.elapsed().as_micros() as u64);

                            // Construct AVCC packet:
                            // Byte 0: is_key (1 or 0)
                            // Bytes 1..8: timestamp_us (Big Endian u64)
                            // Bytes 9..10: desc_len (Big Endian u16)
                            // Bytes 11..11+desc_len: AVCC description (extradata)
                            // Remaining bytes: 4-byte length-delimited NAL AU bytes
                            let desc_slice = cached_codec_data.as_deref().unwrap_or(&[]);
                            let desc_len = desc_slice.len() as u16;

                            let mut payload = Vec::with_capacity(11 + desc_slice.len() + raw_bytes.len());
                            payload.push(if is_key { 1 } else { 0 });
                            payload.extend_from_slice(&timestamp_us.to_be_bytes());
                            payload.extend_from_slice(&desc_len.to_be_bytes());
                            if desc_len > 0 {
                                payload.extend_from_slice(desc_slice);
                            }
                            payload.extend_from_slice(raw_bytes);

                            let bytes_pkg = Bytes::from(payload);
                            let _ = sender.send(bytes_pkg);
                        }
                    }
                }
                Err(err) => {
                    eprintln!("[Demuxer {}] appsink pull_sample error: {:?}. Reconnecting in 2s...", stream_id, err);
                    break;
                }
            }
        }

        let _ = pipeline.set_state(gst::State::Null);
        if is_running.load(Ordering::SeqCst) {
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    }

    println!("[Demuxer {}] Thread terminated.", stream_id);
}

pub struct StreamPool {
    demuxers: Vec<StreamDemuxer>,
}

impl StreamPool {
    pub fn new(count: usize, rtsp_url_fn: impl Fn(usize) -> String) -> (Self, Vec<StreamBroadcaster>) {
        let mut demuxers = Vec::with_capacity(count);
        let mut broadcasters = Vec::with_capacity(count);

        for i in 0..count {
            let url = rtsp_url_fn(i);
            // Low-latency channel capacity (8 frames = approx 320ms buffer)
            let (demuxer, _rx) = StreamDemuxer::new(i, url, 8);
            broadcasters.push(demuxer.get_broadcaster());
            demuxers.push(demuxer);
        }

        (Self { demuxers }, broadcasters)
    }

    pub fn start_all(&self) {
        println!("[StreamPool] Starting {} RTSP demuxers...", self.demuxers.len());
        for demuxer in &self.demuxers {
            demuxer.start();
        }
    }

    pub fn stop_all(&self) {
        println!("[StreamPool] Stopping {} RTSP demuxers...", self.demuxers.len());
        for demuxer in &self.demuxers {
            demuxer.stop();
        }
    }
}
