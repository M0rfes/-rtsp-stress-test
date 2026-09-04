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

pub fn log_cpu() {
    #[cfg(target_os = "macos")]
    println!("[Platform] macOS: software H.264 decode, tiny-skia blit");
    #[cfg(target_os = "linux")]
    println!("[Platform] Linux: software H.264 decode, tiny-skia blit");
    #[cfg(target_os = "windows")]
    println!("[Platform] Windows: software H.264 decode, tiny-skia blit");
}

pub fn log_gpu() {
    #[cfg(target_os = "macos")]
    println!("[Platform] macOS: VideoToolbox (vtdec) + Metal / IOSurface");
    #[cfg(target_os = "linux")]
    println!("[Platform] Linux: NVDEC / VA-API + wgpu GLES/Vulkan");
    #[cfg(target_os = "windows")]
    println!("[Platform] Windows: d3d11h264dec + DXGI / wgpu Dx12");
}
