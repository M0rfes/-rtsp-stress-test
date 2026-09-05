#!/usr/bin/env python3
"""00start_rtsp_server.py - Pre-flight download, configure, and start local MediaMTX RTSP Server.

Ensures port 8554 is live and broadcasting 30 test streams (cam0..cam29 and /live).
If the server is already running, it verifies reachability and exits 0 immediately.

Usage:
    python benchmark_windows/00start_rtsp_server.py
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path

from bench_utils import IS_WINDOWS, ROOT_DIR, check_rtsp_stream_reachability

VERSION = os.environ.get("MEDIAMTX_VERSION", "v1.20.1")
SERVER_DIR = ROOT_DIR / "rtsp-server"
BIN_DIR = SERVER_DIR / "bin"
RUNTIME_CONFIG = SERVER_DIR / "mediamtx.runtime.yml"


def get_server_binary() -> Path:
    ext = ".exe" if IS_WINDOWS else ""
    return BIN_DIR / f"mediamtx{ext}"


def download_mediamtx(target_bin: Path) -> None:
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    os_name = platform.system().lower()
    machine = platform.machine().lower()

    if IS_WINDOWS:
        arch = "amd64" if ("64" in machine or "arm" not in machine) else "arm64"
        asset_name = f"mediamtx_{VERSION}_windows_{arch}.zip"
    elif os_name == "darwin":
        arch = "arm64" if ("arm" in machine or "aarch" in machine) else "amd64"
        asset_name = f"mediamtx_{VERSION}_darwin_{arch}.tar.gz"
    else:
        arch = "arm64" if ("arm" in machine or "aarch" in machine) else "amd64"
        asset_name = f"mediamtx_{VERSION}_linux_{arch}.tar.gz"

    url = f"https://github.com/bluenviron/mediamtx/releases/download/{VERSION}/{asset_name}"
    archive_path = BIN_DIR / asset_name

    print(f"[*] Downloading MediaMTX {VERSION} from {url}...")
    urllib.request.urlretrieve(url, archive_path)

    print(f"[*] Extracting {asset_name} to {BIN_DIR}...")
    if asset_name.endswith(".zip"):
        with zipfile.ZipFile(archive_path, "r") as z:
            z.extractall(BIN_DIR)
    elif asset_name.endswith((".tar.gz", ".tgz")):
        with tarfile.open(archive_path, "r:gz") as t:
            t.extractall(BIN_DIR)

    if archive_path.exists():
        archive_path.unlink()

    if target_bin.exists():
        os.chmod(target_bin, 0o755)
        print(f"[✓] MediaMTX installed at {target_bin}")
    else:
        raise RuntimeError(f"Failed to locate extracted binary at {target_bin}")


def generate_config() -> None:
    print("[*] Generating MediaMTX configuration (30 camera paths + /live)...")
    gen_script = SERVER_DIR / "generate_mediamtx.py"
    res = subprocess.run(
        [sys.executable, str(gen_script)],
        cwd=str(SERVER_DIR),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    with open(RUNTIME_CONFIG, "w", encoding="utf-8") as f:
        f.write(res.stdout)
    print(f"[✓] Generated config -> {RUNTIME_CONFIG}")


def start_server() -> None:
    target_bin = get_server_binary()
    if not target_bin.exists():
        download_mediamtx(target_bin)

    generate_config()

    print("[*] Launching MediaMTX background process on port 8554...")
    kwargs = {}
    if IS_WINDOWS:
        # Launch detached from current console so it stays running
        kwargs["creationflags"] = (
            subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        )
        kwargs["close_fds"] = True

    proc = subprocess.Popen(
        [str(target_bin), str(RUNTIME_CONFIG)],
        cwd=str(SERVER_DIR),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        **kwargs,
    )
    print(f"[✓] MediaMTX started (PID: {proc.pid})")


def main() -> None:
    print("==========================================================")
    print(" 00 RTSP SERVER: Verifying & Launching MediaMTX Server   ")
    print("==========================================================")

    # 1. Check if already reachable
    target_url = "rtsp://127.0.0.1:8554/live"
    if check_rtsp_stream_reachability(target_url, timeout=1.5):
        print(f"[✓] RTSP server is ALREADY ACTIVE and reachable at {target_url}!")
        sys.exit(0)

    # 2. Check for FFmpeg in PATH (required by MediaMTX test pattern generator)
    has_ffmpeg = bool(shutil.which("ffmpeg") or shutil.which("ffmpeg.exe"))
    if not has_ffmpeg:
        print("\n" + "!" * 65)
        print(" [AGENT ACTION REQUIRED] FFmpeg is required to generate test streams!")
        print(" Install with:")
        print("   >>> winget install Gyan.FFmpeg --silent")
        print("!" * 65 + "\n")
        sys.exit(1)

    # 3. Start MediaMTX
    start_server()

    # 4. Wait for RTSP port 8554 to become reachable
    print("[*] Waiting for RTSP port 8554 to accept connections...")
    for _ in range(15):
        if check_rtsp_stream_reachability(target_url, timeout=1.0):
            print("\n[✓] RTSP Server is ONLINE and broadcasting:")
            print("    • rtsp://127.0.0.1:8554/live")
            print("    • rtsp://127.0.0.1:8554/cam0 ... /cam29")
            print("==========================================================\n")
            sys.exit(0)
        time.sleep(1.0)

    print("\n[!] Warning: Port 8554 did not respond after 15 seconds. Please check logs in rtsp-server/.")
    sys.exit(1)


if __name__ == "__main__":
    main()
