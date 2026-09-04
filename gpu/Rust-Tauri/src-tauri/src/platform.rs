//! Shared OS platform hooks for the RTSP benchmark.
//! macOS: VideoToolbox / Metal (no VA-API). Linux: VA-API / NVDEC. Windows: D3D11.

pub const NOFILE_TARGET: u64 = 10240;
pub const STREAM_STAGGER_MS: u64 = 20;

pub fn name() -> &'static str {
    if cfg!(target_os = "macos") {
        "macOS"
    } else if cfg!(target_os = "linux") {
        "Linux"
    } else if cfg!(target_os = "windows") {
        "Windows"
    } else {
        "Unknown"
    }
}

pub fn raise_file_descriptor_limit() {
    #[cfg(unix)]
    unsafe {
        let mut rl = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) != 0 {
            return;
        }
        let old = rl.rlim_cur;
        if rl.rlim_max < NOFILE_TARGET {
            rl.rlim_max = NOFILE_TARGET;
        }
        rl.rlim_cur = std::cmp::min(NOFILE_TARGET, rl.rlim_max);
        if libc::setrlimit(libc::RLIMIT_NOFILE, &rl) == 0 {
            println!("[Platform] Raised RLIMIT_NOFILE from {} to {}", old, rl.rlim_cur);
        } else {
            eprintln!("[Platform] Could not raise RLIMIT_NOFILE (current={})", old);
        }
    }
}

pub fn apply_cpu_webview_env() {
    #[cfg(target_os = "linux")]
    {
        std::env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
        std::env::set_var("LIBGL_ALWAYS_SOFTWARE", "1");
        println!("[Platform] Linux: software decode, no VA-API");
    }
    #[cfg(target_os = "macos")]
    {
        println!("[Platform] macOS: software H.264 decode, Metal compositor");
    }
    #[cfg(target_os = "windows")]
    {
        println!("[Platform] Windows: software H.264 decode");
    }
}

pub fn apply_gpu_webview_env() {
    #[cfg(target_os = "linux")]
    {
        std::env::set_var("WEBKIT_FORCE_COMPOSITING_MODE", "1");
        std::env::set_var("GST_VAAPI_ALL_DRIVERS", "1");
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "0");
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
        println!("[Platform] Linux: VA-API / NVDEC WebKitGTK flags");
    }
    #[cfg(target_os = "macos")]
    {
        println!("[Platform] macOS: WKWebView VideoToolbox + Metal (no VA-API/EGL)");
    }
    #[cfg(target_os = "windows")]
    {
        println!("[Platform] Windows: WebView2 D3D11 hardware decode");
    }
}
