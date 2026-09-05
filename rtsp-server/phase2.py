#!/usr/bin/env python3
"""Phase 2 churn: after 3h, drop/restore the same camera indexes for every client.

Camera N is path camN. All 10 clients must use RTSP_URL_PATTERN=.../cam%d
so stream i maps to cam i. Drops are seeded and identical across the fleet
because there is one server schedule.
"""
from __future__ import annotations

import json
import os
import random
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

API = os.environ.get("MTX_API", "http://127.0.0.1:9997").rstrip("/")
CAMERA_COUNT = int(os.environ.get("CAMERA_COUNT", "30"))
PHASE1_SECONDS = int(os.environ.get("PHASE1_SECONDS", "10800"))
PHASE2_SECONDS = int(os.environ.get("PHASE2_SECONDS", "10800"))
SEED = int(os.environ.get("CHURN_SEED", "20260904"))
DROP_MIN_S = int(os.environ.get("DROP_MIN_S", "15"))
DROP_MAX_S = int(os.environ.get("DROP_MAX_S", "45"))
GAP_MIN_S = int(os.environ.get("GAP_MIN_S", "20"))
GAP_MAX_S = int(os.environ.get("GAP_MAX_S", "75"))
MAX_DOWN = int(os.environ.get("MAX_CONCURRENT_DOWN", "3"))
GO_FILE = os.environ.get("GO_FILE", "").strip()

_stop = False


def log(event: str, **fields) -> None:
    payload = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event,
        **fields,
    }
    print(json.dumps(payload), flush=True)


def request(method: str, path: str, body=None, timeout: float = 10.0):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"{API}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return None
            return json.loads(raw.decode())
    except urllib.error.HTTPError as exc:
        err = exc.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} -> {exc.code} {err}") from exc


def wait_origin() -> None:
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            path = request("GET", "/v3/paths/get/origin")
            if path and path.get("online"):
                log("origin_online")
                return
        except Exception:
            pass
        time.sleep(1)
    raise SystemExit("origin path not online within 120s")


def wait_go() -> None:
    """Block until go.sh writes GO_FILE. Empty GO_FILE = start immediately (local dry-run)."""
    if not GO_FILE:
        return
    log("waiting_for_go", file=GO_FILE)
    while not _stop:
        if os.path.isfile(GO_FILE):
            log("go_received", file=GO_FILE)
            return
        time.sleep(0.5)
    raise SystemExit("stopped while waiting for GO")


ORIGIN = "rtsp://127.0.0.1:8554/origin"
DOWN = "rtsp://127.0.0.1:8554/__offline"


def set_source(cam: int, source: str) -> None:
    request("PATCH", f"/v3/config/paths/patch/cam{cam}", {"source": source})


def kick_readers(cam: int) -> int:
    name = f"cam{cam}"
    kicked = 0
    page = 0
    while True:
        listing = request(
            "GET",
            f"/v3/rtspsessions/list?page={page}&itemsPerPage=100",
        ) or {}
        items = listing.get("items") or []
        for session in items:
            if session.get("path") != name:
                continue
            if session.get("state") == "publish":
                continue
            sid = session.get("id")
            if not sid:
                continue
            try:
                request("POST", f"/v3/rtspsessions/kick/{sid}")
                kicked += 1
            except Exception as exc:
                log("kick_failed", camera=cam, id=sid, error=str(exc))
        if page + 1 >= int(listing.get("pageCount") or 1):
            break
        page += 1
    return kicked


def drop_cameras(cams: list[int]) -> None:
    for cam in cams:
        set_source(cam, DOWN)
        kicked = kick_readers(cam)
        log("camera_down", camera=cam, kicked=kicked)


def restore_cameras(cams: list[int]) -> None:
    for cam in cams:
        try:
            set_source(cam, ORIGIN)
            log("camera_up", camera=cam)
        except Exception as exc:
            log("camera_up_failed", camera=cam, error=str(exc))


def restore_all() -> None:
    restore_cameras(list(range(CAMERA_COUNT)))


def handle_stop(_signum, _frame) -> None:
    global _stop
    _stop = True


def sleep_or_stop(seconds: float) -> None:
    end = time.monotonic() + max(0.0, seconds)
    while not _stop and time.monotonic() < end:
        time.sleep(min(1.0, end - time.monotonic()))


def main() -> int:
    signal.signal(signal.SIGINT, handle_stop)
    signal.signal(signal.SIGTERM, handle_stop)

    rng = random.Random(SEED)
    log(
        "phase1_wait",
        phase1_seconds=PHASE1_SECONDS,
        phase2_seconds=PHASE2_SECONDS,
        cameras=CAMERA_COUNT,
        seed=SEED,
        snapshot="copy fps_metrics.log and hardware_metrics.csv on all 10 clients when phase2_begin fires",
        go_file=GO_FILE or None,
    )
    wait_origin()
    wait_go()
    if _stop:
        return 0
    log("phase1_begin", phase1_seconds=PHASE1_SECONDS)
    sleep_or_stop(PHASE1_SECONDS)
    if _stop:
        return 0

    log("phase2_begin", snapshot_now=True)
    phase2_end = time.monotonic() + PHASE2_SECONDS

    while not _stop and time.monotonic() < phase2_end:
        remaining = [c for c in range(CAMERA_COUNT)]
        n = rng.randint(1, min(MAX_DOWN, CAMERA_COUNT))
        cams = sorted(rng.sample(remaining, n))
        drop_s = rng.randint(DROP_MIN_S, DROP_MAX_S)
        gap_s = rng.randint(GAP_MIN_S, GAP_MAX_S)
        log("event_drop", cameras=cams, down_seconds=drop_s, gap_seconds=gap_s)
        drop_cameras(cams)
        sleep_or_stop(min(drop_s, max(0.0, phase2_end - time.monotonic())))
        restore_cameras(cams)
        if _stop or time.monotonic() >= phase2_end:
            break
        sleep_or_stop(min(gap_s, max(0.0, phase2_end - time.monotonic())))

    restore_all()
    log("phase2_end")
    return 0


if __name__ == "__main__":
    sys.exit(main())
