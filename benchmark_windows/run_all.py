#!/usr/bin/env python3
"""run_all.py - Master Orchestrator for Physical Windows RTSP Benchmark Suite.

Executes the complete test sequence with automated idle settling between every run:
  1. 01baseline.py
  2. 02CPPCPU.py
  3. 03pausetillidealagain.py
  4. 04cppgpu.py
  5. 03pausetillidealagain.py
  6. 05csharpgpu.py
  7. 03pausetillidealagain.py
  8. 06csharpcpu.py
  9. 03pausetillidealagain.py
 10. 07electrongpu.py
 11. 03pausetillidealagain.py
 12. 08electroncpu.py
 13. 03pausetillidealagain.py

Usage:
    python benchmark_windows/run_all.py [--cool-mins 5] [--quick-test]
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
LOG_DIR = ROOT_DIR / "logs"


def run_step(script_name: str, extra_args: list[str] = None) -> bool:
    cmd = [sys.executable, str(SCRIPT_DIR / script_name)]
    if extra_args:
        cmd.extend(extra_args)
    print(f"\n>>> EXECUTING: {' '.join(cmd)}")
    res = subprocess.run(cmd, cwd=str(ROOT_DIR))
    return res.returncode == 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Master RTSP Benchmark Runner with Idle Stabilization (Headed UI)")
    parser.add_argument("--cool-mins", type=float, default=5.0, help="Cool-down minutes between runs (default: 5.0)")
    parser.add_argument("--quick-test", action="store_true", help="Dry run: runs each test for 1 minute to verify setup")
    parser.add_argument("--url", type=str, default="rtsp://127.0.0.1:8554/live", help="RTSP target stream URL")
    parser.add_argument("--streams", type=int, default=30, help="Number of concurrent video tiles (default: 30)")
    args = parser.parse_args()

    common_ui_args = ["--url", args.url, "--streams", str(args.streams)]

    # Configure duration overrides if quick-test flag is active
    c_args = (["--duration", "1.0", "--phase1", "0.5"] if args.quick_test else []) + common_ui_args
    net_args = (["--duration", "1.0", "--phase1", "0.5"] if args.quick_test else []) + common_ui_args
    pause_args = ["--min-cool-mins", "0.2" if args.quick_test else str(args.cool_mins)]

    print("\n" + "#" * 60)
    print(" STARTING COMPLETE WINDOWS BENCHMARK WORKLOAD SUITE")
    print(f" Mode: {'DRY RUN QUICK TEST (1 min/run)' if args.quick_test else 'FULL PRODUCTION RUN (HEADED UI)'}")
    print(f" RTSP Target: {args.url} ({args.streams} streams)")
    print(f" Inter-run cooldown: {args.cool_mins} minutes")
    print("#" * 60 + "\n")

    steps = [
        # (script, args, is_pause)
        ("01baseline.py", [], False),
        ("02CPPCPU.py", c_args, False),
        ("03pausetillidealagain.py", pause_args, True),
        ("04cppgpu.py", c_args, False),
        ("03pausetillidealagain.py", pause_args, True),
        ("05csharpgpu.py", net_args, False),
        ("03pausetillidealagain.py", pause_args, True),
        ("06csharpcpu.py", net_args, False),
        ("03pausetillidealagain.py", pause_args, True),
        ("07electrongpu.py", net_args, False),
        ("03pausetillidealagain.py", pause_args, True),
        ("08electroncpu.py", net_args, False),
        ("03pausetillidealagain.py", pause_args, True),
    ]

    total_steps = len(steps)
    start_all = time.time()

    for idx, (script, s_args, is_pause) in enumerate(steps, 1):
        print(f"\n[STEP {idx}/{total_steps}] ------------------------------------------")
        success = run_step(script, s_args)
        if not success:
            print(f"[!] Warning: Step {script} returned non-zero code.")

    total_time = round((time.time() - start_all) / 60.0, 1)
    print("\n" + "=" * 60)
    print(f" ALL BENCHMARK RUNS COMPLETED IN {total_time} MINUTES!")
    print(f" Archived logs stored at: {LOG_DIR / 'archive'}")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    main()
