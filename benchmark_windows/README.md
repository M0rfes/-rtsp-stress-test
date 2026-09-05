# Windows RTSP Stress Test Benchmark Suite

This directory contains modular automation scripts to execute the RTSP video grid benchmarks on a physical Windows machine with automated idle stabilization and cooldown between runs.

---

## Script Index

| Script | Purpose | Default Duration |
| :--- | :--- | :--- |
| **`00start_rtsp_server.py`** | Auto-downloads, configures, and launches MediaMTX RTSP server on port 8554 broadcasting 30 test streams. | ~10 seconds |
| **`01baseline.py`** | Samples and logs CPU load, RAM, GPU temperature, and VRAM into `logs/system_baseline.json`. | ~15 seconds |
| **`02CPPCPU.py`** | Runs C++ Qt6 CPU (software decode) benchmark; terminates all child processes upon completion and archives logs. | 20 min (10m steady + 10m churn) |
| **`03pausetillidealagain.py`** | Compares live metrics against `system_baseline.json`, cooling the PC until CPU, GPU temp, and VRAM return to idle. | 5 – 10 min dwell |
| **`04cppgpu.py`** | Runs C++ Qt6 GPU (hardware zero-copy decode) benchmark and archives logs. | 20 min (10m steady + 10m churn) |
| **`05csharpgpu.py`** | Runs C# Avalonia GPU benchmark; monitors GC and handles. | 60 min (30m steady + 30m churn) |
| **`06csharpcpu.py`** | Runs C# Avalonia CPU software decode benchmark. | 60 min (30m steady + 30m churn) |
| **`07electrongpu.py`** | Runs Electron GPU WebCodecs hardware decode benchmark. | 60 min (30m steady + 30m churn) |
| **`08electroncpu.py`** | Runs Electron CPU software decode benchmark. | 60 min (30m steady + 30m churn) |
| **`run_all.py`** | Master script running the entire automated sequence. | ~5.5 hours |

---

## Prerequisites (Windows)

1. **Python 3.10+**
2. Optional (recommended for low-overhead metric sampling):
   ```cmd
   pip install psutil
   ```
   *(Scripts automatically fall back to PowerShell / WMI if `psutil` is not installed)*
3. If using an NVIDIA GPU, ensure `nvidia-smi` is available in your PATH to monitor GPU temperature and VRAM.

---

## How to Run

### Option 1: Run the Full Sequence Automatically
Run the entire suite hands-free:
```cmd
python benchmark_windows\run_all.py --cool-mins 5
```

### Option 2: Run Quick Dry-Run (Verification)
To verify builds and process cleanup in just ~10 minutes (1 min per test):
```cmd
python benchmark_windows\run_all.py --quick-test
```

### Option 3: Run Individual Steps Manually
You can run each step independently in sequence:
```cmd
python benchmark_windows\01baseline.py
python benchmark_windows\02CPPCPU.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5
python benchmark_windows\04cppgpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5
python benchmark_windows\05csharpgpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5
python benchmark_windows\06csharpcpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5
python benchmark_windows\07electrongpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5
python benchmark_windows\08electroncpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5
```

---

## Customizing Durations

All benchmark runner scripts accept custom durations via `--duration` and `--phase1`:
```cmd
# Run C++ GPU for 30 minutes total (15 min steady, 15 min churn):
python benchmark_windows\04cppgpu.py --duration 30 --phase1 15
```

All archived metrics (`fps_metrics.log` and `hardware_metrics.csv`) are saved to:
`logs/archive/<framework>_<hardware_mode>_<timestamp>/`
