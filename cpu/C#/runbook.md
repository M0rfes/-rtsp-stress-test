# Operations, Debugging & Troubleshooting Runbook (C# Avalonia CPU Benchmark)

This runbook provides complete operational procedures for deploying, verifying, debugging, and diagnosing the 6-hour RTSP CPU benchmark on AWS EC2 Ubuntu Linux using C# Avalonia (.NET 10) and `FFmpeg.AutoGen` software decoding.

---

## 1. Quick Health Check (30-Second Verification)

Execute these checks on the benchmark box to verify that all 30 streams are decoding and blitting:

### A. Check Systemd Service Status
```bash
sudo systemctl status rtsp-benchmark-csharp-cpu.service --no-pager
```
*Expected Output:* `Active: active (running)`.

### B. Verify Process Hierarchy
```bash
# Verify .NET process, Xvfb virtual display, and hardware poller are active
pgrep -a -f "rtsp-stress-test-csharp-cpu"
pgrep -a Xvfb
pgrep -a poll_hardware.sh
```
*Expected Output:*
- `dotnet ... rtsp-stress-test-csharp-cpu.dll` running with 30+ threads.
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
journalctl -u rtsp-benchmark-csharp-cpu.service -f --output=cat
```

---

## 3. Deep AWS Diagnostic & Debugging Procedures

### A. Inspect Thread-Level CPU Distribution
To ensure all 30 decoder tasks are balanced across CPU cores without thread contention:
```bash
PID=$(pgrep -f "rtsp-stress-test-csharp-cpu" | head -n 1)

# View per-thread CPU utilization
top -H -p "$PID"

# Or using pidstat:
pidstat -t -p "$PID" 2 5
```
*Expected:* ~30 worker threads, each consuming ~15%–25% of a core on a 32-vCPU `c7i.8xlarge` instance. Total CPU should remain strictly below **85%**.

### B. Inspect .NET Garbage Collection Activity
Verify that zero-allocation rendering prevents Gen 1/2 garbage collection thrashing:
```bash
# Monitor .NET runtime counters in real-time
dotnet-counters monitor --process-id "$PID" --counters System.Runtime
```
*Key Metrics to Verify:*
- `% Time in GC`: Should remain `< 1%`.
- `Gen 2 Collections / sec`: Should remain `0`.
- `Allocation Rate`: Should remain near `0 B/sec` once steady state is reached.

### C. Inspect Network Sockets & TCP Backpressure
Check that all 30 TCP RTSP sockets are connected and have empty receive queues:
```bash
# Check all established TCP sockets to port 8554
ss -tnp '( dport = :8554 or sport = :8554 )'

# Inspect TCP socket buffer overflows / drops
netstat -s | grep -iE 'buffer|listen|drop|retransmit'
```
*Diagnosis:* If `Recv-Q` is consistently non-zero, the network throughput is saturating or socket buffers are overflowing. Ensure `buffer_size=4194304` is active.

### D. Verify Headless Xvfb Display Surface & Visual Output
Because the application runs headless in Xvfb, verify that the 30-tile grid is visually rendering without display errors:
```bash
# Capture screenshot of Xvfb virtual framebuffer :0
DISPLAY=:0 import -window root /tmp/grid_screenshot.png 2>/dev/null || \
xwd -root -silent -display :0 | convert xwd:- /tmp/grid_screenshot.png

# Check image dimensions (should match 2560x1440)
file /tmp/grid_screenshot.png
```

---

## 4. Troubleshooting Matrix

| Issue | Root Cause | Resolution |
| :--- | :--- | :--- |
| `FileNotFoundException: Unable to locate FFmpeg native libraries` | Native `libavcodec` not found in library path | Set `FFMPEG_PATH=/usr/lib/x86_64-linux-gnu` or install `libavcodec-dev`. |
| `EMFILE: Too many open files` | OS file descriptor limit too low | Verify `FFmpegHelper.RaiseFileDescriptorLimit(10240)` ran or set `ulimit -n 65536`. |
| `Recv-Q` growing on TCP sockets | Worker thread overwhelmed by 1440p decode | Ensure `codecCtx->thread_count = 1` and host has sufficient vCPUs (`c7i.8xlarge`). |
| Stream frames dropping to < 5 FPS | High GC pause times or dispatcher event queue spam | Verify zero-allocation buffers and that coalesced render dispatching is active. |
| Memory leaks during Phase 2 churn | Incomplete disposal of FFmpeg contexts on stream drop | Verify `avcodec_free_context`, `avformat_close_input`, and `sws_freeContext` run before 3-second reconnect backoff. |
| Avalonia fails to start under Xvfb | Missing X11 libraries or display server | Ensure `xvfb` and `libx11-dev` are installed and `xvfb-run -a -s "-screen 0 2560x1440x24"` is used. |
