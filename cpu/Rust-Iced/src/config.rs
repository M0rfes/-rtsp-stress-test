use std::env;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct BenchmarkConfig {
    pub stream_count: usize,
    pub rtsp_url: String,
    pub rtsp_url_pattern: Option<String>,
    #[allow(dead_code)]
    pub log_dir: PathBuf,
    pub fps_log_path: PathBuf,
    pub machine_id: String,
    pub framework: String,
    pub hardware_mode: String,
    pub window_duration_seconds: u32,
    pub video_width: u32,
    pub video_height: u32,
    pub tile_width: u32,
    pub tile_height: u32,
    pub target_fps: u32,
    pub ui_render_fps: u32,
}

impl BenchmarkConfig {
    pub fn from_env() -> Self {
        let _ = dotenvy::dotenv();

        let stream_count = env::var("STREAM_COUNT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(30);

        let rtsp_url = env::var("RTSP_URL")
            .unwrap_or_else(|_| "rtsp://127.0.0.1:8554/live".to_string());

        let rtsp_url_pattern = env::var("RTSP_URL_PATTERN").ok();

        let default_log_dir = if cfg!(target_os = "linux") {
            PathBuf::from("/var/log/benchmark")
        } else {
            PathBuf::from("./logs")
        };

        let log_dir = env::var("BENCHMARK_LOG_DIR")
            .map(PathBuf::from)
            .unwrap_or(default_log_dir);

        let fps_log_path = env::var("FPS_METRICS_LOG_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|_| log_dir.join("fps_metrics.log"));

        let machine_id = env::var("MACHINE_ID")
            .or_else(|_| env::var("HOSTNAME"))
            .unwrap_or_else(|_| "c7i-8xlarge-node-1".to_string());

        let video_width = env::var("VIDEO_WIDTH")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(2560);

        let video_height = env::var("VIDEO_HEIGHT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1440);

        let is_full_res = env::var("FULL_RES").map(|v| v == "1" || v == "true").unwrap_or(false);

        let default_tile_w = if is_full_res { video_width } else { 640 };
        let default_tile_h = if is_full_res { video_height } else { 360 };

        let tile_width = env::var("TILE_WIDTH")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_tile_w);

        let tile_height = env::var("TILE_HEIGHT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(default_tile_h);

        let target_fps = env::var("TARGET_FPS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(25);

        let ui_render_fps = env::var("UI_RENDER_FPS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(30);

        Self {
            stream_count,
            rtsp_url,
            rtsp_url_pattern,
            log_dir,
            fps_log_path,
            machine_id,
            framework: "rust_iced".to_string(),
            hardware_mode: "cpu".to_string(),
            window_duration_seconds: 60,
            video_width,
            video_height,
            tile_width,
            tile_height,
            target_fps,
            ui_render_fps,
        }
    }

    pub fn get_rtsp_url_for_stream(&self, index: usize) -> String {
        if let Some(ref pattern) = self.rtsp_url_pattern {
            pattern.replace("%d", &index.to_string())
        } else {
            self.rtsp_url.clone()
        }
    }

    pub fn resolve_log_path(&self) -> PathBuf {
        let target = &self.fps_log_path;
        if let Some(parent) = target.parent() {
            if std::fs::create_dir_all(parent).is_ok() && is_dir_writable(parent) {
                return target.clone();
            }
        }

        // Fallback to local logs directory
        let fallback_dir = PathBuf::from("./logs");
        let _ = std::fs::create_dir_all(&fallback_dir);
        fallback_dir.join("fps_metrics.log")
    }
}

fn is_dir_writable(path: &Path) -> bool {
    let test_file = path.join(".perm_test");
    if std::fs::write(&test_file, b"test").is_ok() {
        let _ = std::fs::remove_file(test_file);
        true
    } else {
        false
    }
}
