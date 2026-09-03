pub mod config;
pub mod demuxer;
pub mod telemetry;
pub mod ws_server;

use std::sync::{Arc, RwLock};
use tauri::Manager;
use config::BenchmarkConfig;
use demuxer::StreamPool;
use telemetry::TelemetryManager;
use ws_server::VideoWebSocketServer;

pub fn run() {
    // 1. Initialize logging
    env_logger::init();

    // 2. Configure GPU hardware acceleration and VA-API environment flags
    // Constraint: "Configure the WebKitGTK/Chromium WebView initialization in Tauri to accept VA-API hardware acceleration flags."
    if cfg!(target_os = "linux") {
        // Enforce WebKitGTK hardware acceleration and compositing
        std::env::set_var("WEBKIT_FORCE_COMPOSITING_MODE", "1");
        std::env::set_var("GST_VAAPI_ALL_DRIVERS", "1");
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "0");

        // If Nvidia VA-API driver is present or Nvidia GPU is installed, set driver hints
        if std::path::Path::new("/usr/lib/x86_64-linux-gnu/dri/nvidia_drv_video.so").exists()
            || std::path::Path::new("/usr/lib64/dri/nvidia_drv_video.so").exists()
        {
            if std::env::var("LIBVA_DRIVER_NAME").is_err() {
                std::env::set_var("LIBVA_DRIVER_NAME", "nvidia");
            }
            if std::env::var("__GLX_VENDOR_LIBRARY_NAME").is_err() {
                std::env::set_var("__GLX_VENDOR_LIBRARY_NAME", "nvidia");
            }
        }
    }

    // 3. Initialize GStreamer and ensure RTSP server library linkage
    gstreamer::init().expect("Failed to initialize GStreamer");
    demuxer::ensure_rtsp_server_support();

    // 4. Load configuration
    let config = BenchmarkConfig::from_env();
    let stream_count = config.stream_count;
    let pid = std::process::id();

    println!("=== RTSP 30-Stream Stress Test (Rust Tauri GPU Benchmark) ===");
    println!("Process PID:            {}", pid);
    println!("Stream Count:           {}", stream_count);
    println!("RTSP Target URL:        {}", config.rtsp_url);
    println!("WebSocket Port:         {}", config.ws_port);
    println!("Hardware Mode:          GPU Zero-Copy Hardware Acceleration");
    println!("Log Directory:          {}", config.log_dir.display());
    println!("Resolved Log Path:      {}", config.resolve_log_path().display());

    // 5. Initialize StreamPool and demuxers
    let config_clone = config.clone();
    let (stream_pool, broadcasters) = StreamPool::new(stream_count, move |idx| {
        config_clone.get_rtsp_url_for_stream(idx)
    });
    let stream_pool_arc = Arc::new(stream_pool);

    // 6. Initialize Telemetry Manager
    let telemetry = Arc::new(RwLock::new(TelemetryManager::new(config.clone())));

    // 7. Start Tokio runtime for WebSocket server and stream forwarder
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to build Tokio runtime");

    let ws_server = Arc::new(VideoWebSocketServer::new(
        config.clone(),
        broadcasters,
        telemetry.clone(),
    ));

    // Spawn WebSocket server in Tokio
    rt.spawn(async move {
        if let Err(e) = ws_server.run().await {
            eprintln!("[WSS] Server error: {}", e);
        }
    });

    // Start all RTSP stream demuxers
    stream_pool_arc.start_all();

    // 8. Build and run Tauri application with GPU acceleration configuration
    let window_title = format!(
        "RTSP 30-Stream Stress Test (Rust Tauri GPU Zero-Copy Benchmark) [PID: {}]",
        pid
    );

    let stream_pool_exit = stream_pool_arc.clone();
    let telemetry_exit = telemetry.clone();

    tauri::Builder::default()
        .setup(move |app| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_title(&window_title);

                // Configure Linux WebKitGTK settings for GPU acceleration and VA-API
                #[cfg(target_os = "linux")]
                {
                    use webkit2gtk::traits::{SettingsExt, WebViewExt};
                    let _ = window.with_webview(|webview| {
                        let webview_gtk = webview.inner();
                        if let Some(settings) = webview_gtk.settings() {
                            settings.set_enable_webgl(true);
                            settings.set_enable_accelerated_2d_canvas(true);
                            settings.set_hardware_acceleration_policy(webkit2gtk::HardwareAccelerationPolicy::Always);
                            settings.set_enable_media(true);
                            settings.set_enable_media_stream(true);
                            settings.set_enable_mediasource(true);
                        }
                    });
                }
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(move |_app_handle, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                println!("[Main] Application exiting. Cleaning up resources...");
                stream_pool_exit.stop_all();
                let mut telem = telemetry_exit.write().unwrap();
                let payload = telem.build_payload();
                telem.flush_to_disk(&payload);
            }
        });
}
