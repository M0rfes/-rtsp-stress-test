# Operations, Debugging & Troubleshooting Runbook (C++ Qt6 CPU Benchmark)

This runbook provides complete operational procedures for deploying, verifying, debugging, and diagnosing the 6-hour RTSP CPU benchmark on AWS EC2 Ubuntu Linux using native C++ and Qt6 (`libavcodec` software decoding).

---

## 1. Quick Health Check (30-Second Verification)

Execute these checks on the benchmark box to verify that all 30 streams are decoding and blitting:

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-cpp-cpu.service --no-pager
```
*Expected Output:* `Active: active (running)`.

### B. Verify Process Hierarchy
```bash
# Verify C++ Qt6 binary, Xvfb virtual display, and hardware poller are active
pgrep -a rtsp-stress-test-cpp-cpu
pgrep -a Xvfb
pgrep -a poll_hardware.sh
```
*Expected Output:*
- `rtsp-stress-test-cpp-cpu` running with 30+ threads.
- `Xvfb :0 -screen 0 2560x1440x24` active.
- `poll_hardware.sh` executing.

### C. Verify Log Generation
```bash
ls -lh /var/log/benchmark/
```
*Expected Output:* Both `fps_metrics.log` and `hardware_metrics.csv` should exist, non-empty, and updating.

---

## 2. Live Telemetry & Metric Monitoring

### A. Monitor 60-Second FPS Time-in-State Windows
```bash
tail -f /var/log/benchmark/fps_metrics.log
```
*Success Criterion:* In every 60-second window, the vast majority of the 1,800 stream-seconds (30 streams × 60s) should reside in `acceptable.25_to_30_fps`.

#### Analyze Telemetry with `jq`:
```bash
# Compute total acceptable vs unacceptable stream-seconds across all windows
cat /var/log/benchmark/fps_metrics.log | jq -s '
  map({
    timestamp: .timestamp,
    acc_25_30: .fps_stream_seconds.acceptable["25_to_30_fps"],
    acc_20_24: .fps_stream_seconds.acceptable["20_to_24_fps"],
    unacc_10_19: .fps_stream_seconds.unacceptable["10_to_19_fps"],
    unacc_under_5: .fps_stream_seconds.unacceptable["under_5_fps"]
  })'
```

### B. Monitor 10-Second Hardware Utilization
```bash
tail -f /var/log/benchmark/hardware_metrics.csv
```
Columns: `timestamp,pid,cpu_percent,ram_rss_mb,gpu_vram_mb,gpu_decoder_percent`

### C. Monitor Live Application Output
```bash
journalctl -u rtsp-benchmark-cpp-cpu.service -f --output=cat
```

---

## 3. Deep AWS Diagnostic & Debugging Procedures

### A. Inspect Thread-Level CPU Distribution
To ensure all 30 decoder `QThread` workers are balanced across CPU cores without thread contention:
```bash
PID=$(pgrep -f rtsp-stress-test-cpp-cpu | head -n 1)

# View per-thread CPU utilization
top -H -p "$PID"

# Or using pidstat:
pidstat -t -p "$PID" 2 5
```
*Expected:* ~30 worker threads, each consuming ~15%–25% of a core on a 32-core `c7i.8xlarge` instance. Total CPU should remain strictly below **85%**.

### B. Inspect Network Sockets & TCP Backpressure
Check that all 30 TCP RTSP sockets are connected and have empty receive queues:
```bash
# Check all established TCP sockets to port 8554
ss -tnp '( dport = :8554 or sport = :8554 )'

# Inspect TCP socket buffer overflows / drops
netstat -s | grep -iE 'buffer|listen|drop|retransmit'
```
*Diagnosis:* If `Recv-Q` is consistently non-zero, the network throughput is saturating or socket buffers are overflowing. Ensure `buffer_size=4194304` is active.

### C. Verify Headless Xvfb Display Surface & Visual Output
Because the application runs headless in Xvfb, verify that the 30-tile grid is visually rendering without display errors:
```bash
# Check Xvfb display properties
xdpyinfo -display :0

# Take a full-resolution visual snapshot of the virtual desktop:
DISPLAY=:0 import -window root /tmp/grid_screenshot.png 2>/dev/null || DISPLAY=:0 xwd -root -silent -out /tmp/grid.xwd

# Convert XWD to PNG (if ImageMagick is installed):
convert /tmp/grid.xwd /tmp/grid_screenshot.png 2>/dev/null || true
ls -lh /tmp/grid_screenshot.png
```
You can SCP `/tmp/grid_screenshot.png` to your workstation to verify that all 30 video tiles are actively painting.

### D. Core Dump & Crash Analysis (GDB)
If a segmentation fault or crash occurs under 6-hour continuous load:
```bash
# Enable core dumps
ulimit -c unlimited
sudo sysctl -w kernel.core_pattern=/tmp/core-%e-%p-%t

# If a core dump is generated:
gdb /opt/rtsp-stress-test/cpu/CPP/build/rtsp-stress-test-cpp-cpu /tmp/core-* -ex "thread apply all bt" -ex "quit"
```

---

## 4. Headroom Pass/Fail Evaluation Rules

Per the benchmark specification in [README.md](../../README.md):
- **Pass:** Sustained 25 FPS across all 30 streams while maintaining **Total CPU Usage < 85%**.
- **Fail Criteria:**
  - Sustained CPU > 85% for more than 5 consecutive minutes (risks Windows DWM starvation).
  - Unacceptable FPS buckets accumulating > 5% of stream-seconds during steady state.
  - Process crashes, memory leaks (RSS continuously climbing above 4 GB), or thread deadlocks.

---

## 5. Common Troubleshooting Scenarios & Remediation

### Scenario 1: `Connection refused` or RTSP Socket Timeout
- **Symptom:** Worker threads log reconnect attempts or tiles display `CONNECTING...`.
- **Root Cause:** RTSP server (MediaMTX) is offline, AWS security group blocks port 8554, or connection stampede occurred.
- **Remediation:**
  1. Test socket connectivity: `nc -z -v -w 3 <RTSP_HOST> 8554`
  2. Verify MediaMTX process on RTSP box: `pgrep -a mediamtx`
  3. Verify AWS Security Group allows Inbound TCP 8554 from Box B's private IP.

### Scenario 2: `qt.qpa.xcb: could not connect to display`
- **Symptom:** The binary exits immediately with display connection error.
- **Root Cause:** Missing active X11 display server or Xvfb crashed.
- **Remediation:**
  1. Verify Xvfb: `ps aux | grep Xvfb`
  2. Ensure `DISPLAY=:0` is exported.
  3. Launch via `xvfb-run -a -s "-screen 0 2560x1440x24" ...`

### Scenario 3: `Too many open files` (`EMFILE`)
- **Symptom:** `avformat_open_input` fails with OS error 24 (`Too many open files`).
- **Root Cause:** Default system file descriptor limit (1024) reached.
- **Remediation:**
  The binary automatically calls `setrlimit(RLIMIT_NOFILE, 10240)`. In systemd, ensure `LimitNOFILE=65536` is present in `rtsp-benchmark-cpp-cpu.service`.

### Scenario 4: CPU Usage Exceeds 85% Headroom Threshold
- **Symptom:** `hardware_metrics.csv` reports CPU usage > 85%.
- **Root Cause:** Insufficient CPU cores (e.g. running on an 8-core `c7i.2xlarge` or `c7i.4xlarge` instead of 16-core `c7i.8xlarge`).
- **Remediation:** Resize instance to `c7i.8xlarge` (32 vCPUs, 64 GiB DDR5). Ensure binary is compiled in `Release` mode with `-O3`.
