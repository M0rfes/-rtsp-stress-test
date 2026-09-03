use std::env;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct BenchmarkConfig {
    pub stream_count: usize,
    pub rtsp_url: String,
    pub rtsp_url_pattern: Option<String>,
    pub ws_port: u16,
    pub log_dir: PathBuf,
    pub fps_log_path: PathBuf,
    pub machine_id: String,
    pub framework: String,
    pub hardware_mode: String,
    pub window_duration_seconds: u32,
    pub video_width: u32,
    pub video_height: u32,
    pub target_fps: u32,
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

        let ws_port = env::var("WS_PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(9999);

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

        Self {
            stream_count,
            rtsp_url,
            rtsp_url_pattern,
            ws_port,
            log_dir,
            fps_log_path,
            machine_id,
            framework: "rust_tauri".to_string(),
            hardware_mode: "gpu".to_string(),
            window_duration_seconds: 60,
            video_width: 2560,
            video_height: 1440,
            target_fps: 25,
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

        // Fallback to local logs directory if system directory is not writable
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
