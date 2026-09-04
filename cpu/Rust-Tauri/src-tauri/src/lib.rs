pub mod config;
pub mod demuxer;
pub mod platform;
pub mod telemetry;
pub mod ws_server;

use std::sync::{Arc, RwLock};
use tauri::Manager;
use config::BenchmarkConfig;
use demuxer::StreamPool;
use telemetry::TelemetryManager;
use ws_server::VideoWebSocketServer;

pub fn run() {
    env_logger::init();
    platform::raise_file_descriptor_limit();
    platform::apply_cpu_webview_env();

    // 3. Initialize GStreamer
    gstreamer::init().expect("Failed to initialize GStreamer");

    // 4. Load configuration
    let config = BenchmarkConfig::from_env();
    let stream_count = config.stream_count;
    let pid = std::process::id();

    println!("=== RTSP 30-Stream Stress Test (Rust Tauri CPU Benchmark) ===");
    println!("Platform:          {}", platform::name());
    println!("Process PID:       {}", pid);
    println!("Stream Count:      {}", stream_count);
    println!("RTSP Target URL:   {}", config.rtsp_url);
    println!("WebSocket Port:    {}", config.ws_port);
    println!("Log Directory:     {}", config.log_dir.display());
    println!("Resolved Log Path: {}", config.resolve_log_path().display());

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

    // 8. Build and run Tauri application
    let window_title = format!(
        "RTSP 30-Stream Stress Test (Rust Tauri CPU Benchmark) [PID: {}]",
        pid
    );

    let stream_pool_exit = stream_pool_arc.clone();
    let telemetry_exit = telemetry.clone();

    tauri::Builder::default()
        .setup(move |app| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_title(&window_title);
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
