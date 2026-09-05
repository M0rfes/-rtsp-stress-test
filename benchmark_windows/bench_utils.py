#!/usr/bin/env python3
"""Shared utilities for Windows RTSP Benchmark runner scripts."""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

IS_WINDOWS = platform.system().lower() == "windows"

# Project root is parent of benchmark_windows/
ROOT_DIR = Path(__file__).resolve().parent.parent
LOG_DIR = ROOT_DIR / "logs"
BASELINE_FILE = LOG_DIR / "system_baseline.json"


def run_cmd(cmd: list[str], timeout: float = 10.0) -> str:
    """Run a shell command safely and return stripped stdout."""
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
        return res.stdout.strip()
    except Exception:
        return ""


def get_cpu_load() -> float:
    """Return current CPU utilization percentage."""
    try:
        import psutil
        return float(psutil.cpu_percent(interval=0.8))
    except ImportError:
        pass

    if IS_WINDOWS:
        out = run_cmd(["powershell", "-NoProfile", "-Command", "(Get-CimInstance Win32_Processor).LoadPercentage"])
        try:
            return float(out.split()[0])
        except (IndexError, ValueError):
            pass
    else:
        # POSIX / macOS fallback
        out = run_cmd(["ps", "-A", "-o", "%cpu"])
        lines = out.splitlines()[1:]
        try:
            total = sum(float(x.strip()) for x in lines if x.strip())
            # Normalize by logical CPU count
            ncpu_str = run_cmd(["sysctl", "-n", "hw.ncpu"]) or "1"
            ncpu = max(1, int(ncpu_str))
            return round(min(100.0, total / ncpu), 1)
        except Exception:
            pass
    return 0.0


def get_ram_info() -> Dict[str, float]:
    """Return RAM info in MB: total, available, used, percent."""
    try:
        import psutil
        mem = psutil.virtual_memory()
        return {
            "total_mb": round(mem.total / (1024 * 1024), 1),
            "available_mb": round(mem.available / (1024 * 1024), 1),
            "used_mb": round(mem.used / (1024 * 1024), 1),
            "percent": float(mem.percent),
        }
    except ImportError:
        pass

    if IS_WINDOWS:
        ps_cmd = (
            "Get-CimInstance Win32_OperatingSystem | "
            "Select-Object TotalVisibleMemorySize, FreePhysicalMemory | ConvertTo-Json"
        )
        out = run_cmd(["powershell", "-NoProfile", "-Command", ps_cmd])
        try:
            data = json.loads(out)
            total_kb = float(data.get("TotalVisibleMemorySize", 0))
            free_kb = float(data.get("FreePhysicalMemory", 0))
            total_mb = total_kb / 1024.0
            avail_mb = free_kb / 1024.0
            used_mb = total_mb - avail_mb
            pct = round((used_mb / total_mb) * 100, 1) if total_mb > 0 else 0.0
            return {
                "total_mb": round(total_mb, 1),
                "available_mb": round(avail_mb, 1),
                "used_mb": round(used_mb, 1),
                "percent": pct,
            }
        except Exception:
            pass
    else:
        # POSIX / macOS fallback
        mem_str = run_cmd(["sysctl", "-n", "hw.memsize"])
        if mem_str.isdigit():
            total_mb = int(mem_str) / (1024 * 1024)
            return {
                "total_mb": round(total_mb, 1),
                "available_mb": round(total_mb * 0.5, 1),
                "used_mb": round(total_mb * 0.5, 1),
                "percent": 50.0,
            }


    return {"total_mb": 0.0, "available_mb": 0.0, "used_mb": 0.0, "percent": 0.0}


def get_gpu_info() -> Dict[str, Any]:
    """Return GPU temperature (°C), VRAM usage (MB), and decoder utilization via nvidia-smi if available."""
    info = {
        "available": False,
        "name": "N/A",
        "temp_c": None,
        "vram_used_mb": None,
        "vram_free_mb": None,
        "vram_total_mb": None,
        "decoder_percent": None,
    }

    smi_out = run_cmd([
        "nvidia-smi",
        "--query-gpu=name,temperature.gpu,memory.used,memory.free,memory.total,utilization.decoder",
        "--format=csv,noheader,nounits",
    ])
    if smi_out:
        try:
            line = smi_out.splitlines()[0]
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 5:
                info["available"] = True
                info["name"] = parts[0]
                info["temp_c"] = float(parts[1])
                info["vram_used_mb"] = float(parts[2])
                info["vram_free_mb"] = float(parts[3])
                info["vram_total_mb"] = float(parts[4])
                if len(parts) >= 6 and parts[5] != "":
                    try:
                        info["decoder_percent"] = float(parts[5])
                    except ValueError:
                        pass
                return info
        except Exception:
            pass

    return info


def get_gpu_hardware_metrics() -> tuple[float, float]:
    """Return (gpu_vram_mb, gpu_decoder_percent) via nvidia-smi."""
    smi_out = run_cmd([
        "nvidia-smi",
        "--query-gpu=memory.used,utilization.decoder",
        "--format=csv,noheader,nounits",
    ])
    if smi_out:
        try:
            line = smi_out.splitlines()[0]
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 2:
                vram = float(parts[0]) if parts[0] else 0.0
                dec = float(parts[1]) if parts[1] else 0.0
                return round(vram, 1), round(dec, 1)
        except Exception:
            pass
    return 0.0, 0.0


def get_process_stats(pid: int) -> tuple[float, float]:
    """Return (cpu_percent, ram_rss_mb) for process and its tree."""
    try:
        import psutil
        if psutil.pid_exists(pid):
            p = psutil.Process(pid)
            tree = [p] + p.children(recursive=True)
            total_cpu = 0.0
            total_rss = 0
            for proc in tree:
                try:
                    total_cpu += proc.cpu_percent(interval=None)
                    total_rss += proc.memory_info().rss
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            return round(total_cpu, 1), round(total_rss / (1024 * 1024), 1)
    except Exception:
        pass

    if IS_WINDOWS:
        ps_cmd = (
            f"$p = Get-Process -Id {pid} -ErrorAction SilentlyContinue; "
            f"if ($p) {{ [math]::Round($p.WorkingSet64 / 1MB, 1) }} else {{ 0 }}"
        )
        out = run_cmd(["powershell", "-NoProfile", "-Command", ps_cmd])
        try:
            rss_mb = float(out)
            return get_cpu_load(), rss_mb
        except (ValueError, TypeError):
            pass
    else:
        out = run_cmd(["ps", "-p", str(pid), "-o", "%cpu,rss"])
        lines = out.splitlines()
        if len(lines) > 1:
            parts = lines[1].strip().split()
            if len(parts) >= 2:
                try:
                    cpu_val = float(parts[0])
                    rss_val = round(float(parts[1]) / 1024.0, 1)
                    return cpu_val, rss_val
                except (ValueError, IndexError):
                    pass

    return get_cpu_load(), get_ram_info().get("used_mb", 0.0)


class HardwarePoller:
    """External background monitor that samples OS hardware & process metrics every N seconds to CSV."""

    def __init__(
        self,
        target_pid: int,
        hardware_mode: str,
        output_csv: Path,
        interval: float = 10.0,
    ) -> None:
        self.target_pid = target_pid
        self.hardware_mode = hardware_mode.lower()
        self.output_csv = output_csv
        self.interval = interval
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self.output_csv.parent.mkdir(parents=True, exist_ok=True)
        # Initialize CSV header if file does not exist or is empty
        if not self.output_csv.exists() or self.output_csv.stat().st_size == 0:
            with open(self.output_csv, "w", encoding="utf-8") as f:
                f.write("timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent\n")

        self._thread = threading.Thread(target=self._run, name="HardwarePoller", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        # Prime psutil counters if available
        try:
            import psutil
            if psutil.pid_exists(self.target_pid):
                p = psutil.Process(self.target_pid)
                p.cpu_percent(interval=None)
                for c in p.children(recursive=True):
                    c.cpu_percent(interval=None)
        except Exception:
            pass

        while not self._stop_event.is_set():
            if not self._is_target_alive():
                break

            now_str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            cpu_pct, ram_mb = get_process_stats(self.target_pid)
            gpu_vram_mb, gpu_dec_pct = get_gpu_hardware_metrics()

            # For CPU-only test modes, GPU decoder remains 0 per benchmark specification
            if self.hardware_mode == "cpu":
                gpu_dec_pct = 0.0

            line = f"{now_str},{self.target_pid},{cpu_pct},{ram_mb},{gpu_vram_mb},{gpu_dec_pct}\n"
            try:
                with open(self.output_csv, "a", encoding="utf-8") as f:
                    f.write(line)
                    f.flush()
            except Exception as e:
                print(f"[!] Hardware poller write error: {e}", flush=True)

            if self._stop_event.wait(self.interval):
                break

    def _is_target_alive(self) -> bool:
        try:
            import psutil
            return psutil.pid_exists(self.target_pid)
        except Exception:
            pass

        if IS_WINDOWS:
            out = run_cmd(["tasklist", "/FI", f"PID eq {self.target_pid}", "/FO", "CSV"])
            return str(self.target_pid) in out
        else:
            try:
                os.kill(self.target_pid, 0)
                return True
            except OSError:
                return False

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=3.0)


def get_system_metrics() -> Dict[str, Any]:
    """Capture a snapshot of all relevant machine metrics."""
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "cpu_percent": get_cpu_load(),
        "ram": get_ram_info(),
        "gpu": get_gpu_info(),
    }


def kill_all_benchmark_processes() -> None:
    """Force-terminate all benchmark processes and child trees."""
    print("[*] Force-killing benchmark processes...", flush=True)
    target_names = [
        "rtsp-stress-test-cpp-cpu",
        "rtsp-stress-test-cpp-gpu",
        "rtsp-stress-test-csharp-cpu",
        "rtsp-stress-test-csharp-gpu",
        "electron",
        "node",
        "ffmpeg",
        "dotnet",
    ]

    if IS_WINDOWS:
        for name in target_names:
            # taskkill with /T (tree) and /F (force)
            run_cmd(["taskkill", "/F", "/T", "/IM", f"{name}.exe"])
            run_cmd(["taskkill", "/F", "/T", "/IM", name])
    else:
        # Do not pkill generic node/ffmpeg/dotnet — that kills Cursor and MediaMTX's publisher.
        for name in (
            "rtsp-stress-test-cpp-cpu",
            "rtsp-stress-test-cpp-gpu",
            "rtsp-stress-test-csharp-cpu",
            "rtsp-stress-test-csharp-gpu",
        ):
            run_cmd(["pkill", "-9", "-f", name])
        run_cmd(["pkill", "-9", "-f", "cpu/Electron"])
        run_cmd(["pkill", "-9", "-f", "gpu/Electron"])
        run_cmd(["pkill", "-9", "-f", "Electron.app"])

    # Allow OS 2 seconds to release socket handles & page files
    time.sleep(2.0)


def archive_logs(framework: str, hardware_mode: str) -> Path:
    """Move current benchmark log files to an archived subfolder."""
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    archive_dir = LOG_DIR / "archive" / f"{framework}_{hardware_mode}_{ts}"
    archive_dir.mkdir(parents=True, exist_ok=True)

    for log_name in ["fps_metrics.log", "hardware_metrics.csv"]:
        src = LOG_DIR / log_name
        if src.exists():
            dst = archive_dir / log_name
            try:
                shutil.move(str(src), str(dst))
                print(f"[✓] Archived {log_name} -> {dst.relative_to(ROOT_DIR)}")
            except Exception as exc:
                print(f"[!] Warning archiving {log_name}: {exc}")

    # Re-create empty fps_metrics.log for clean start
    (LOG_DIR / "fps_metrics.log").touch()
    return archive_dir


def check_rtsp_stream_reachability(url: str, timeout: float = 2.5) -> bool:
    """Probe if RTSP server host and port are reachable before benchmark starts."""
    import socket
    try:
        clean = url.replace("rtsp://", "").split("/")[0]
        if ":" in clean:
            host, port_str = clean.split(":")
            port = int(port_str)
        else:
            host = clean
            port = 8554
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


def restore_all_rtsp_cameras() -> None:
    """Ensure all camera streams in MediaMTX are restored to origin."""
    import urllib.request
    try:
        for i in range(30):
            req = urllib.request.Request(
                f"http://127.0.0.1:9997/v3/config/paths/patch/cam{i}",
                data=json.dumps({"source": "rtsp://127.0.0.1:8554/origin"}).encode(),
                headers={"Content-Type": "application/json"},
                method="PATCH",
            )
            try:
                with urllib.request.urlopen(req, timeout=0.3):
                    pass
            except Exception:
                pass
    except Exception:
        pass


def execute_benchmark_session(
    framework: str,
    hardware_mode: str,
    cmd: list[str],
    cwd: Path,
    total_minutes: float,
    phase1_minutes: float,
    extra_env: Optional[Dict[str, str]] = None,
) -> bool:
    """Run a single benchmark phase session, monitor it, kill on timeout, and archive logs."""
    total_seconds = int(total_minutes * 60)
    phase1_seconds = int(phase1_minutes * 60)
    phase2_seconds = total_seconds - phase1_seconds

    print("==========================================================")
    print(f" BENCHMARK RUN: {framework.upper()} ({hardware_mode.upper()})")
    print("==========================================================")
    print(f" • Working directory: {cwd}")
    print(f" • Command:           {' '.join(cmd)}")
    print(f" • Total Duration:    {total_minutes} min ({phase1_minutes}m steady + {round(phase2_seconds/60, 1)}m churn)")
    print("----------------------------------------------------------")

    # Probe RTSP stream endpoint
    rtsp_url = "rtsp://127.0.0.1:8554/live"
    if "--url" in cmd:
        try:
            rtsp_url = cmd[cmd.index("--url") + 1]
        except (IndexError, ValueError):
            pass
    elif extra_env and "RTSP_URL" in extra_env:
        rtsp_url = extra_env["RTSP_URL"]

    if not check_rtsp_stream_reachability(rtsp_url):
        print(f"[!] NOTICE: RTSP endpoint {rtsp_url} is not responding to TCP ping.")
        print("    If using a local RTSP server, make sure it is running (e.g. MediaMTX).")

    # Ensure all camera streams are restored to origin for Phase 1
    restore_all_rtsp_cameras()

    # Clean pre-run state
    kill_all_benchmark_processes()

    env = os.environ.copy()
    env["BENCHMARK_FRAMEWORK"] = framework
    env["HARDWARE_MODE"] = hardware_mode
    env["BENCHMARK_LOG_DIR"] = str(LOG_DIR)
    if extra_env:
        env.update(extra_env)
    # phase2.py drops camN, not /live. Clients must read cam0..cam29 or churn is a no-op.
    if "RTSP_URL_PATTERN" not in env:
        if "%d" in rtsp_url:
            env["RTSP_URL_PATTERN"] = rtsp_url
        elif rtsp_url.rstrip("/").endswith("/live"):
            env["RTSP_URL_PATTERN"] = rtsp_url.rstrip("/").rsplit("/", 1)[0] + "/cam%d"
        else:
            env["RTSP_URL_PATTERN"] = rtsp_url.rstrip("/") + "/cam%d"

    # Touch log file
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    (LOG_DIR / "fps_metrics.log").touch()

    print("[*] Launching application process...")
    proc = None
    churn_proc = None
    poller = None
    churn_started = False
    start_time = time.time()

    try:
        kwargs = {}
        if IS_WINDOWS:
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP

        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            env=env,
            shell=False,
            **kwargs,
        )
        print(f"[✓] Process started with PID: {proc.pid}")

        # Start external OS hardware telemetry monitor
        hw_csv_path = LOG_DIR / "hardware_metrics.csv"
        poller = HardwarePoller(
            target_pid=proc.pid,
            hardware_mode=hardware_mode,
            output_csv=hw_csv_path,
            interval=10.0,
        )
        poller.start()
        print(f"[*] Started hardware telemetry monitor -> {hw_csv_path.relative_to(ROOT_DIR)}")

        while True:
            elapsed = time.time() - start_time
            if elapsed >= total_seconds:
                print(f"\n[✓] Test duration reached ({total_minutes} mins). Stopping benchmark...")
                break

            # Check if process exited early / crashed
            ret = proc.poll()
            if ret is not None:
                print(f"\n[!] Warning: Benchmark process exited prematurely with code {ret} at {int(elapsed)}s")
                break

            # Trigger Phase 2 Churn if applicable and not already started
            if phase2_seconds > 0 and elapsed >= phase1_seconds and not churn_started:
                churn_started = True
                print("\n" + "="*50)
                print(" [*] PHASE 2 STARTED: Activating stream churn & recovery testing")
                print("="*50)
                # If local rtsp-server/phase2.py exists, trigger churn generator in background
                phase2_script = ROOT_DIR / "rtsp-server" / "phase2.py"
                if phase2_script.exists():
                    try:
                        churn_env = env.copy()
                        churn_env["PHASE1_SECONDS"] = "0"
                        churn_env["PHASE2_SECONDS"] = str(phase2_seconds)
                        churn_proc = subprocess.Popen(
                            [sys.executable, str(phase2_script)],
                            cwd=str(ROOT_DIR / "rtsp-server"),
                            env=churn_env,
                        )
                        print(f"[*] Started churn controller (PID: {churn_proc.pid})")
                    except Exception as e:
                        print(f"[!] Could not start phase2.py churn: {e}")

            # Print heartbeat every 30 seconds
            current_phase = "Phase 2 (Churn)" if churn_started else "Phase 1 (Steady)"
            rem = int(total_seconds - elapsed)
            sys.stdout.write(f"\r[{current_phase}] Elapsed: {int(elapsed//60):02d}m{int(elapsed%60):02d}s / {int(total_minutes)}m | Left: {int(rem//60):02d}m{int(rem%60):02d}s   ")
            sys.stdout.flush()
            time.sleep(10.0)

    except KeyboardInterrupt:
        print("\n[!] User interrupted benchmark (Ctrl+C). Cleaning up...")
    finally:
        # Stop hardware monitoring poller
        if poller:
            poller.stop()

        # Terminate application & churn generator
        if churn_proc and churn_proc.poll() is None:
            churn_proc.terminate()
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                pass

        # Restore all cameras back to origin
        restore_all_rtsp_cameras()
        kill_all_benchmark_processes()
        archived = archive_logs(framework, hardware_mode)
        print(f"[✓] Completed and archived to: {archived.relative_to(ROOT_DIR)}")
        print("==========================================================\n")

    return True

