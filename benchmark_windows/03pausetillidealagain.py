#!/usr/bin/env python3
"""03pausetillidealagain.py - Wait until the system cools down and returns to idle baseline.

Usage:
    python benchmark_windows/03pausetillidealagain.py [--min-cool-mins 5] [--max-wait-mins 12]
"""
import argparse
import json
import sys
import time
from bench_utils import (
    BASELINE_FILE,
    get_cpu_load,
    get_gpu_info,
    get_ram_info,
    kill_all_benchmark_processes,
)


def load_baseline() -> dict:
    if not BASELINE_FILE.exists():
        print(f"[!] Baseline file not found at {BASELINE_FILE}. Creating temporary baseline...")
        return {
            "idle_cpu_percent": 3.0,
            "tolerances": {
                "max_idle_cpu_percent": 8.0,
                "max_gpu_temp_c": 52.0,
                "max_vram_used_mb": 650.0,
            },
        }
    with open(BASELINE_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    parser = argparse.ArgumentParser(description="Pause until physical PC returns to idle baseline.")
    parser.add_argument("--min-cool-mins", type=float, default=5.0, help="Minimum enforced cooldown minutes (default: 5.0)")
    parser.add_argument("--max-wait-mins", type=float, default=12.0, help="Maximum timeout minutes to wait (default: 12.0)")
    args = parser.parse_args()

    min_cool_seconds = int(args.min_cool_mins * 60)
    max_wait_seconds = int(args.max_wait_mins * 60)

    print("\n==========================================================")
    print(" 03 PAUSE TILL IDLE: Cooling System & Awaiting Baseline   ")
    print("==========================================================")

    # 1. Ensure any lingering processes are terminated
    kill_all_benchmark_processes()

    # 2. Load baseline target tolerances
    baseline = load_baseline()
    tols = baseline.get("tolerances", {})
    max_cpu = tols.get("max_idle_cpu_percent", 8.0)
    max_temp = tols.get("max_gpu_temp_c", 50.0)
    max_vram = tols.get("max_vram_used_mb", 650.0)

    print(f"[*] Enforcing minimum {args.min_cool_mins} mins cooldown for heatsinks & fans...")
    print(f"[*] Target thresholds: CPU < {max_cpu}%, GPU Temp < {max_temp}°C, VRAM < {max_vram}MB")

    start_time = time.time()
    while True:
        elapsed = time.time() - start_time
        cpu = get_cpu_load()
        gpu = get_gpu_info()
        ram = get_ram_info()

        # Check conditions
        dwell_done = elapsed >= min_cool_seconds
        cpu_ok = cpu <= max_cpu

        gpu_temp_ok = True
        vram_ok = True
        gpu_status_str = "GPU N/A"

        if gpu.get("available") and gpu.get("temp_c") is not None:
            gpu_temp_ok = gpu["temp_c"] <= max_temp
            vram_ok = gpu["vram_used_mb"] <= max_vram
            gpu_status_str = f"GPU: {gpu['temp_c']}°C (VRAM: {gpu['vram_used_mb']}MB)"

        dwell_remaining = max(0, int(min_cool_seconds - elapsed))
        status_line = (
            f"\r[Cooling {int(elapsed)}s/{min_cool_seconds}s] "
            f"CPU: {cpu:4.1f}% (ok: {str(cpu_ok)[0]}) | "
            f"{gpu_status_str} | "
            f"RAM: {ram['percent']:4.1f}% | Dwell Left: {dwell_remaining}s   "
        )
        sys.stdout.write(status_line)
        sys.stdout.flush()

        if dwell_done and cpu_ok and gpu_temp_ok and vram_ok:
            print("\n\n[✓] System returned to idle baseline!")
            print(f"    Total settling time: {int(elapsed)} seconds")
            print(f"    Final state: CPU {cpu}%, {gpu_status_str}, RAM {ram['available_mb']}MB free")
            print("==========================================================\n")
            sys.exit(0)

        if elapsed >= max_wait_seconds:
            print(f"\n\n[!] Timeout reached ({args.max_wait_mins} mins). Proceeding with next run.")
            sys.exit(0)

        time.sleep(5.0)


if __name__ == "__main__":
    main()
