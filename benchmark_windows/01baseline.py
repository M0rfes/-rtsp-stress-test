#!/usr/bin/env python3
"""01baseline.py - Measure and save system idle baseline (CPU, Memory, GPU temp, VRAM).

Usage:
    python benchmark_windows/01baseline.py
"""
import json
import time
from pathlib import Path
from bench_utils import (
    BASELINE_FILE,
    LOG_DIR,
    get_cpu_load,
    get_gpu_info,
    get_ram_info,
    get_system_metrics,
    kill_all_benchmark_processes,
)


def main() -> None:
    print("==========================================================")
    print(" 01 BASELINE: Measuring Physical PC Idle Reference State  ")
    print("==========================================================")

    # 1. Clean any lingering benchmark processes first
    kill_all_benchmark_processes()
    print("[*] Waiting 5 seconds for background tasks to settle...")
    time.sleep(5.0)

    # 2. Take 3 samples over 10 seconds to get an accurate idle average
    print("[*] Sampling system metrics across 10 seconds...")
    cpu_samples = []
    gpu_samples = []
    ram_samples = []

    for i in range(3):
        cpu_samples.append(get_cpu_load())
        gpu_samples.append(get_gpu_info())
        ram_samples.append(get_ram_info())
        if i < 2:
            time.sleep(3.0)

    avg_cpu = round(sum(cpu_samples) / len(cpu_samples), 1)
    last_ram = ram_samples[-1]
    last_gpu = gpu_samples[-1]

    baseline_data = {
        "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "idle_cpu_percent": avg_cpu,
        "ram": last_ram,
        "gpu": last_gpu,
        # Tolerances used by 03pausetillidealagain.py:
        "tolerances": {
            "max_idle_cpu_percent": max(avg_cpu + 4.0, 7.0),
            "max_gpu_temp_c": (last_gpu["temp_c"] + 4.0) if last_gpu.get("temp_c") else 50.0,
            "max_vram_used_mb": (last_gpu["vram_used_mb"] + 250.0) if last_gpu.get("vram_used_mb") else 600.0,
        },
    }

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with open(BASELINE_FILE, "w", encoding="utf-8") as f:
        json.dump(baseline_data, f, indent=2)

    print("\n[✓] Baseline Recorded Successfully ->", BASELINE_FILE)
    print("----------------------------------------------------------")
    print(f" • CPU Idle Load:       {avg_cpu}% (Target idle threshold: < {baseline_data['tolerances']['max_idle_cpu_percent']}%)")
    print(f" • RAM Available:       {last_ram['available_mb']} MB / {last_ram['total_mb']} MB ({last_ram['percent']}% used)")
    if last_gpu.get("available"):
        print(f" • GPU Model:           {last_gpu['name']}")
        print(f" • GPU Temp (Idle):     {last_gpu['temp_c']} °C (Cooldown threshold: < {baseline_data['tolerances']['max_gpu_temp_c']} °C)")
        print(f" • GPU VRAM Used:       {last_gpu['vram_used_mb']} MB / {last_gpu['vram_total_mb']} MB")
    else:
        print(" • GPU Hardware SMon:   nvidia-smi not detected (using CPU & timer-based thermal cooldown)")
    print("----------------------------------------------------------\n")


if __name__ == "__main__":
    main()
