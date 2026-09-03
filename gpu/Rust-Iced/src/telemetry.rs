use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use crate::config::BenchmarkConfig;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AcceptableBuckets {
    #[serde(rename = "25_to_30_fps")]
    pub fps_25_to_30: u32,
    #[serde(rename = "20_to_24_fps")]
    pub fps_20_to_24: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UnacceptableBuckets {
    #[serde(rename = "10_to_19_fps")]
    pub fps_10_to_19: u32,
    #[serde(rename = "5_to_9_fps")]
    pub fps_5_to_9: u32,
    #[serde(rename = "under_5_fps")]
    pub under_5_fps: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FpsStreamSeconds {
    pub acceptable: AcceptableBuckets,
    pub unacceptable: UnacceptableBuckets,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FpsMetricsPayload {
    pub timestamp: String,
    pub machine_id: String,
    pub framework: String,
    pub hardware_mode: String,
    pub window_duration_seconds: u32,
    pub active_streams: usize,
    pub fps_stream_seconds: FpsStreamSeconds,
}

pub struct TelemetryManager {
    config: BenchmarkConfig,
    log_path: PathBuf,
    current_buckets: FpsStreamSeconds,
    tick_count_in_window: u32,
    total_flushes: u64,
    active_streams: usize,
    latest_stream_fps: Vec<u32>,
}

impl TelemetryManager {
    pub fn new(config: BenchmarkConfig) -> Self {
        let log_path = config.resolve_log_path();
        let active_streams = config.stream_count;

        Self {
            config,
            log_path,
            current_buckets: FpsStreamSeconds::default(),
            tick_count_in_window: 0,
            total_flushes: 0,
            active_streams,
            latest_stream_fps: vec![0; active_streams],
        }
    }

    pub fn get_log_path(&self) -> String {
        self.log_path.to_string_lossy().to_string()
    }

    #[allow(dead_code)]
    pub fn get_tick_in_window(&self) -> u32 {
        self.tick_count_in_window
    }

    pub fn get_total_flushes(&self) -> u64 {
        self.total_flushes
    }

    #[allow(dead_code)]
    pub fn get_current_buckets(&self) -> &FpsStreamSeconds {
        &self.current_buckets
    }

    #[allow(dead_code)]
    pub fn get_latest_stream_fps(&self) -> &[u32] {
        &self.latest_stream_fps
    }

    pub fn record_tick(&mut self, stream_fps_list: &[u32]) -> (FpsMetricsPayload, u32) {
        self.tick_count_in_window += 1;
        self.active_streams = stream_fps_list.len();
        self.latest_stream_fps = stream_fps_list.to_vec();

        for &fps in stream_fps_list {
            if fps >= 25 {
                self.current_buckets.acceptable.fps_25_to_30 += 1;
            } else if fps >= 20 {
                self.current_buckets.acceptable.fps_20_to_24 += 1;
            } else if fps >= 10 {
                self.current_buckets.unacceptable.fps_10_to_19 += 1;
            } else if fps >= 5 {
                self.current_buckets.unacceptable.fps_5_to_9 += 1;
            } else {
                self.current_buckets.unacceptable.under_5_fps += 1;
            }
        }

        let payload = self.build_payload();
        let current_sec = self.tick_count_in_window;

        if self.tick_count_in_window >= self.config.window_duration_seconds {
            self.flush_to_disk(&payload);
            self.current_buckets = FpsStreamSeconds::default();
            self.tick_count_in_window = 0;
        }

        (payload, current_sec)
    }

    pub fn build_payload(&self) -> FpsMetricsPayload {
        FpsMetricsPayload {
            timestamp: Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            machine_id: self.config.machine_id.clone(),
            framework: self.config.framework.clone(),
            hardware_mode: self.config.hardware_mode.clone(),
            window_duration_seconds: self.config.window_duration_seconds,
            active_streams: self.active_streams,
            fps_stream_seconds: self.current_buckets.clone(),
        }
    }

    pub fn flush_to_disk(&mut self, payload: &FpsMetricsPayload) {
        let json_str = match serde_json::to_string_pretty(payload) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[Telemetry] Failed to serialize metrics: {}", e);
                return;
            }
        };

        match OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)
        {
            Ok(mut file) => {
                if let Err(e) = writeln!(file, "{}\n", json_str) {
                    eprintln!("[Telemetry] Failed to write to {}: {}", self.log_path.display(), e);
                } else {
                    self.total_flushes += 1;
                    println!(
                        "[Telemetry] Flushed 60s window #{} to {}",
                        self.total_flushes,
                        self.log_path.display()
                    );
                    println!(
                        "[Telemetry] Acceptable (25-30: {}, 20-24: {}), Unacceptable (10-19: {}, 5-9: {}, <5: {})",
                        payload.fps_stream_seconds.acceptable.fps_25_to_30,
                        payload.fps_stream_seconds.acceptable.fps_20_to_24,
                        payload.fps_stream_seconds.unacceptable.fps_10_to_19,
                        payload.fps_stream_seconds.unacceptable.fps_5_to_9,
                        payload.fps_stream_seconds.unacceptable.under_5_fps
                    );
                }
            }
            Err(e) => {
                eprintln!("[Telemetry] Failed to open {}: {}", self.log_path.display(), e);
            }
        }
    }
}
