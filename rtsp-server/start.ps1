# start.ps1 - Shared RTSP publisher for Windows (10 clients × 30 = 300 TCP readers).
$ErrorActionPreference = "Stop"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Dir

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Error "ffmpeg not found in PATH. Install FFmpeg and retry."
}

$Version = if ($env:MEDIAMTX_VERSION) { $env:MEDIAMTX_VERSION } else { "v1.20.1" }
$BinDir = Join-Path $Dir "bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$Mtx = Join-Path $BinDir "mediamtx.exe"

if (-not (Test-Path $Mtx)) {
    $Asset = "mediamtx_${Version}_windows_amd64.zip"
    $Url = "https://github.com/bluenviron/mediamtx/releases/download/$Version/$Asset"
    $Zip = Join-Path $env:TEMP $Asset
    Write-Host "[*] Downloading MediaMTX $Version..."
    Invoke-WebRequest -Uri $Url -OutFile $Zip
    Expand-Archive -Path $Zip -DestinationPath $BinDir -Force
    Remove-Item $Zip -Force
}

Write-Host "=== Shared RTSP server ==="
Write-Host "  Pattern: rtsp://<this-host>:8554/cam%d"
python3 (Join-Path $Dir "generate_mediamtx.py") | Set-Content -Encoding utf8 (Join-Path $Dir "mediamtx.runtime.yml")
& $Mtx (Join-Path $Dir "mediamtx.runtime.yml")
