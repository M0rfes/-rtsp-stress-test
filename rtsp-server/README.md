# Shared RTSP Server (AWS VPC)

One encode (`origin`), 30 camera paths (`cam0`…`cam29`). All 10 clients use **the same camera index**. Phase 2 drops `camN` on the server, so tile N goes down on every client at once.

Do **not** cross-build on a Mac. Build each client on its Ubuntu instance (or a matching x86_64 Linux builder). macOS ARM binaries will not run on AWS Linux x86_64, and Qt / CUDA / WebKitGTK / GStreamer do not cross-compile cleanly.

The 6-hour clock does **not** start at `setup.sh`. It starts when you run `sudo /opt/rtsp-server/go.sh` after all 10 clients are already connected.

## AWS

Same VPC/AZ as the 10 clients. SG: inbound **TCP 8554** from the VPC CIDR. Instance: **`c7i.xlarge`** or larger.

```bash
sudo ./rtsp-server/setup.sh
```

This starts the encode (`rtsp-feed-server`) and leaves `rtsp-phase2` blocked on `/opt/rtsp-server/GO`.

On every client (do not restart them at hour 3):

```bash
export RTSP_URL_PATTERN=rtsp://<server-private-ip>:8554/cam%d
export STREAM_COUNT=30
```

Stream `i` → `cam{i}`. After all 10 UIs are up:

```bash
sudo /opt/rtsp-server/go.sh
journalctl -u rtsp-phase2 -f
```

Copy `fps_metrics.log` and `hardware_metrics.csv` when journal shows `phase2_begin`.

## Local

```bash
./rtsp-server/start.sh
# other terminal, short phase 1 for a dry run (no GO file = start immediately):
PHASE1_SECONDS=30 PHASE2_SECONDS=60 python3 ./rtsp-server/phase2.py
```

## Schedule

| Phase | Time | Behavior |
|---|---|---|
| 1 | 0–3 h after `go.sh` | All 30 cameras up |
| 2 | 3–6 h after `go.sh` | Seeded drops: 1–3 cameras, 15–45 s down, 20–75 s gap, seed `20260904` |

SIGTERM restores every camera.
