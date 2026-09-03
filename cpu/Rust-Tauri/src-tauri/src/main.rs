// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    rtsp_stress_test_tauri_cpu_lib::run();
}
