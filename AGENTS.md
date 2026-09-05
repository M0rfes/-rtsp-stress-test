# AGENTS.md: AI Agent Guide for Physical Windows Benchmark Execution

This document provides definitive instructions for AI agents (Antigravity, Claude, Cursor, etc.) tasked with building, validating, running, and collecting logs for the RTSP Video Grid Benchmark on a **physical Windows machine**.

---

## 1. Operating Rules & Target Environment

* **Target OS:** Physical Windows 10/11 Desktop (not headless VM, not AWS EC2).
* **Display Mode:** **HEADED UI ONLY** (visible desktop window with display compositor active). Never run with `-platform offscreen`, `--headless`, or Xvfb wrappers.
* **Target Workload:** 30-stream 1440p @ 25 FPS video grid across 6 implementations:
  1. C++ Qt6 (GPU Hardware Zero-Copy)
  2. C++ Qt6 (CPU Software Decode)
  3. C# Avalonia (GPU Hardware Zero-Copy)
  4. C# Avalonia (CPU Software Decode)
  5. Electron (GPU WebCodecs Hardware Decode)
  6. Electron (CPU Software Decode)

---

## 2. Phase 1: Build & Dependency Resolution

Always start by running the pre-flight dependency audit and build automator:

```powershell
python benchmark_windows\build_all.py
```

### How the Agent Must Respond to Missing Dependencies:
`build_all.py` outputs explicit `[AGENT ACTION REQUIRED]` blocks.

1. **Attempt Direct Installation:** If your execution environment has permission, run the suggested command directly.
2. **Escalate to Human Operator:** If installation requires **Administrator (UAC) elevation**, encounters interactive prompts, or your tool permissions restrict installing system packages, **immediately ask the human operator** to execute the command in an elevated Administrator PowerShell prompt:
   > *"I detected that `<Dependency>` is missing. Could you please run the following in an Administrator PowerShell window: `<Install Command>`? Let me know once done so I can re-run `build_all.py`."*
3. Refresh the shell environment and re-run `python benchmark_windows\build_all.py`.

* **Missing Node.js / npm:**
  ```powershell
  winget install OpenJS.NodeJS.LTS --silent --accept-package-agreements
  ```
* **Missing .NET SDK:**
  ```powershell
  winget install Microsoft.DotNet.SDK.9 --silent --accept-package-agreements
  ```
* **Missing CMake:**
  ```powershell
  winget install Kitware.CMake --silent --accept-package-agreements
  ```
* **Missing C++ MSVC Compiler / Build Tools:**
  ```powershell
  winget install Microsoft.VisualStudio.2022.BuildTools --silent
  ```
* **Missing Python psutil (Recommended for lightweight hardware polling):**
  ```powershell
  pip install psutil
  ```

**Success Gate:** Do NOT proceed to running benchmarks until `python benchmark_windows\build_all.py` exits with code `0` and reports:
```text
[✓] All implementations compiled successfully and are ready for benchmarking!
```

---

## 3. Phase 2: Running Benchmarks with Idle Cooldown

Physical hardware retains heat, and Windows WDDM keeps GPU memory mapped until explicitly purged. **You must allow the machine to return to its cold baseline between every single test.**

### The Benchmark Scripts:

| Script | Framework | Hardware | Total Time | Phase 1 (No Churn) | Phase 2 (Churn) |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **`00start_rtsp_server.py`** | *RTSP server* | — | 10 sec | Auto-downloads & launches MediaMTX on port 8554 |
| **`01baseline.py`** | *Hardware profiler* | — | 15 sec | Record idle CPU %, GPU temp, VRAM baseline |
| **`02CPPCPU.py`** | C++ Qt6 | CPU | 20 min | 10 min steady | 10 min churn |
| **`03pausetillidealagain.py`** | *Hardware cooldown* | — | 5–10 min | Polls live metrics; blocks until idle tolerances match baseline |
| **`04cppgpu.py`** | C++ Qt6 | GPU | 20 min | 10 min steady | 10 min churn |
| **`05csharpgpu.py`** | C# Avalonia | GPU | 60 min | 30 min steady | 30 min churn |
| **`06csharpcpu.py`** | C# Avalonia | CPU | 60 min | 30 min steady | 30 min churn |
| **`07electrongpu.py`** | Electron | GPU | 60 min | 30 min steady | 30 min churn |
| **`08electroncpu.py`** | Electron | CPU | 60 min | 30 min steady | 30 min churn |

---

## 4. How the Agent Must Execute the Runs

### Strategy A: Sequential Step-by-Step (Recommended for Agent Control)
The agent executes each script sequentially. **Crucial:** When invoking `03pausetillidealagain.py`, the agent must simply wait for the command to finish with exit code `0`. `03pausetillidealagain.py` will actively monitor CPU load, GPU temperature, and VRAM and only exit when the system is cold and idle.

```powershell
# 0. Start the Local RTSP Stream Server (MediaMTX)
python benchmark_windows\00start_rtsp_server.py

# 1. Establish Idle Baseline
python benchmark_windows\01baseline.py

# 2. C++ CPU
python benchmark_windows\02CPPCPU.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5

# 3. C++ GPU
python benchmark_windows\04cppgpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5

# 4. C# GPU
python benchmark_windows\05csharpgpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5

# 5. C# CPU
python benchmark_windows\06csharpcpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5

# 6. Electron GPU
python benchmark_windows\07electrongpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5

# 7. Electron CPU
python benchmark_windows\08electroncpu.py
python benchmark_windows\03pausetillidealagain.py --min-cool-mins 5
```

### Strategy B: Fully Automated Master Script
The agent can also launch [`run_all.py`](benchmark_windows/run_all.py), which executes the exact sequence above and manages cooldown pauses automatically:
```powershell
python benchmark_windows\run_all.py --cool-mins 5 --url rtsp://127.0.0.1:8554/live --streams 30
```

### Verification Dry-Run (Fast 1-Minute Tests):
Before committing to the full ~5.5-hour run, the agent can verify that all 6 executables launch, present windows, kill cleanly, and archive logs properly by running:
```powershell
python benchmark_windows\run_all.py --quick-test
```

---

## 5. Phase 3: Committing & Pushing Logs

Logs are tracked in Git (removed from `.gitignore`):
* Real-time metrics write to `./logs/fps_metrics.log` and `./logs/hardware_metrics.csv`.
* At the end of each test, `bench_utils.py` archives them into `./logs/archive/<framework>_<hardware_mode>_<timestamp>/`.

Once all benchmarks are complete, the agent must commit and push the results from the test machine:
```powershell
git status
git add logs/
git commit -m "bench: physical windows benchmark metrics"
git push
```
