import { useEffect, useRef, useImperativeHandle, forwardRef } from 'react';

export interface StreamFpsReport {
  streamId: number;
  fps: number;
  isConnected: boolean;
  lastDeltaMs: number;
  uiFrames: number;
  decodedFrames: number;
}

export interface VideoPlayerRef {
  getFpsAndReset: () => number;
  getReportAndReset: () => StreamFpsReport;
  updateFpsDisplay: (fps: number) => void;
}

interface VideoPlayerProps {
  streamId: number;
  wsPort: number;
}

function isMacPlatform(): boolean {
  return /Mac/i.test(navigator.userAgent);
}

export const VideoPlayer = forwardRef<VideoPlayerRef, VideoPlayerProps>(({ streamId, wsPort }, ref) => {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const fpsBadgeRef = useRef<HTMLSpanElement | null>(null);
  const statusDotRef = useRef<HTMLSpanElement | null>(null);
  const placeholderRef = useRef<HTMLDivElement | null>(null);

  // Performance-critical mutable state to decouple video decoding/rendering from React cycle
  const frameCountRef = useRef<number>(0);
  const decodedCountRef = useRef<number>(0);
  const lastPtsRef = useRef<number | null>(null);
  const lastPresentedTimeRef = useRef<number>(0);
  const lastDeltaMsRef = useRef<number>(0);
  const isConnectedRef = useRef<boolean>(false);
  const hasConfiguredRef = useRef<boolean>(false);
  const currentCodecRef = useRef<string>('');
  const lastDescRef = useRef<Uint8Array | null>(null);
  const hasSeenKeyframeRef = useRef<boolean>(false);
  const decoderRef = useRef<VideoDecoder | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const hwAccelRef = useRef<HardwareAcceleration>('prefer-hardware');
  const presentSizeRef = useRef({ width: 0, height: 0 });
  const isMac = isMacPlatform();

  // BitmapRenderer context ref for GPU Zero-Copy
  const bitmapCtxRef = useRef<ImageBitmapRenderingContext | null>(null);

  useImperativeHandle(ref, () => ({
    getFpsAndReset: () => {
      const fps = frameCountRef.current;
      frameCountRef.current = 0;
      decodedCountRef.current = 0;
      return fps;
    },
    getReportAndReset: () => {
      const uiFrames = frameCountRef.current;
      const decodedFrames = decodedCountRef.current;
      const fps = uiFrames;
      frameCountRef.current = 0;
      decodedCountRef.current = 0;
      const now = performance.now();
      const connected = isConnectedRef.current && (lastPresentedTimeRef.current > 0 && now - lastPresentedTimeRef.current < 3000);
      return {
        streamId,
        fps,
        isConnected: connected,
        lastDeltaMs: lastDeltaMsRef.current,
        uiFrames,
        decodedFrames,
      };
    },
    updateFpsDisplay: (fps: number) => {
      // Direct DOM update: 0% React re-render overhead at 750 FPS
      if (fpsBadgeRef.current) {
        fpsBadgeRef.current.textContent = `${fps} FPS`;
        fpsBadgeRef.current.className = 'fps-badge ' + (
          fps >= 25 ? 'acceptable' : fps >= 20 ? 'warning' : 'unacceptable'
        );
      }
      if (statusDotRef.current) {
        statusDotRef.current.className = 'status-dot ' + (fps > 0 ? 'active' : 'waiting');
      }
      if (placeholderRef.current && fps > 0) {
        placeholderRef.current.style.display = 'none';
      }
    },
  }));

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    let isDestroyed = false;
    const updatePresentSize = () => {
      const dpr = window.devicePixelRatio || 1;
      presentSizeRef.current = {
        width: Math.max(1, Math.round(canvas.clientWidth * dpr)),
        height: Math.max(1, Math.round(canvas.clientHeight * dpr)),
      };
    };
    updatePresentSize();
    const resizeObserver = typeof ResizeObserver !== 'undefined'
      ? new ResizeObserver(updatePresentSize)
      : null;
    if (resizeObserver) {
      resizeObserver.observe(canvas.parentElement || canvas);
    }

    // Architecture Constraint:
    // "Render the frames using BitmapRenderer (transferFromImageBitmap) to prevent CPU-to-GPU memory copies."
    let bitmapCtx = bitmapCtxRef.current;
    if (!bitmapCtx) {
      try {
        bitmapCtx = canvas.getContext('bitmaprenderer');
      } catch (err) {
        console.warn(`[Stream ${streamId}] getContext('bitmaprenderer') fallback:`, err);
      }
      bitmapCtxRef.current = bitmapCtx;
    }

    if (!bitmapCtx) {
      console.error(`[Stream ${streamId}] Failed to acquire ImageBitmapRenderingContext`);
    }

    const createDecoder = () => {
      if (isDestroyed) return;

      try {
        if (decoderRef.current && decoderRef.current.state !== 'closed') {
          try { decoderRef.current.close(); } catch { /* ignore */ }
        }

        const decoder = new VideoDecoder({
          output: (videoFrame: VideoFrame) => {
            if (isDestroyed) {
              videoFrame.close();
              return;
            }

            decodedCountRef.current++;

            // Effective FPS gate: only count frames with a new unique PTS
            const curPts = videoFrame.timestamp;
            if (curPts === lastPtsRef.current) {
              videoFrame.close();
              return;
            }
            lastPtsRef.current = curPts;

            const targetW = isMac && presentSizeRef.current.width > 0
              ? presentSizeRef.current.width
              : videoFrame.displayWidth;
            const targetH = isMac && presentSizeRef.current.height > 0
              ? presentSizeRef.current.height
              : videoFrame.displayHeight;
            if (canvas.width !== targetW || canvas.height !== targetH) {
              canvas.width = targetW;
              canvas.height = targetH;
            }

            const bitmapPromise = isMac
              ? createImageBitmap(videoFrame, { resizeWidth: targetW, resizeHeight: targetH, resizeQuality: 'low' })
              : createImageBitmap(videoFrame);
            bitmapPromise
              .then((bitmap) => {
                videoFrame.close();

                if (isDestroyed) {
                  bitmap.close();
                  return;
                }

                if (bitmapCtxRef.current) {
                  // Direct zero-copy transfer of GPU texture into canvas swapchain
                  bitmapCtxRef.current.transferFromImageBitmap(bitmap);
                } else {
                  bitmap.close();
                }

                // Record presentation: Δt pacing and connection state
                const now = performance.now();
                if (lastPresentedTimeRef.current > 0) {
                  lastDeltaMsRef.current = now - lastPresentedTimeRef.current;
                }
                lastPresentedTimeRef.current = now;
                isConnectedRef.current = true;
                frameCountRef.current++;

                if (placeholderRef.current && placeholderRef.current.style.display !== 'none') {
                  placeholderRef.current.style.display = 'none';
                }
              })
              .catch((err) => {
                videoFrame.close();
                console.warn(`[Stream ${streamId}] createImageBitmap error:`, err);
              });
          },
          error: (err: any) => {
            console.warn(`[Stream ${streamId}] VideoDecoder error: ${err?.message || err}. Adapting acceleration...`);
            hasSeenKeyframeRef.current = false;
            hasConfiguredRef.current = false;

            // On macOS Apple Silicon, if 30 streams saturate VideoToolbox sessions,
            // adaptively relax to 'no-preference' to prevent continuous session crashing
            if (hwAccelRef.current === 'prefer-hardware') {
              hwAccelRef.current = 'no-preference';
            }

            setTimeout(() => {
              if (!isDestroyed) createDecoder();
            }, 200);
          },
        });

        decoderRef.current = decoder;

        // If we already have cached codec description, reconfigure immediately
        if (lastDescRef.current && currentCodecRef.current) {
          try {
            decoder.configure({
              codec: currentCodecRef.current,
              description: lastDescRef.current,
              hardwareAcceleration: hwAccelRef.current,
              optimizeForLatency: true,
            });
            hasConfiguredRef.current = true;
          } catch {
            // Wait for next AVCC packet
          }
        }
      } catch (err: any) {
        console.error(`[Stream ${streamId}] Failed to create VideoDecoder:`, err?.message || err);
      }
    };

    createDecoder();

    // Connect to WebSocket stream
    const wsUrl = `ws://127.0.0.1:${wsPort}/stream/${streamId}`;
    const ws = new WebSocket(wsUrl);
    ws.binaryType = 'arraybuffer';
    wsRef.current = ws;

    ws.onopen = () => {
      if (statusDotRef.current) {
        statusDotRef.current.className = 'status-dot waiting';
      }
    };

    ws.onmessage = (event: MessageEvent) => {
      if (isDestroyed) return;
      if (!decoderRef.current || decoderRef.current.state === 'closed') return;
      if (typeof event.data === 'string') return;

      const buffer = event.data as ArrayBuffer;
      if (buffer.byteLength < 11) return;

      const view = new DataView(buffer);
      const isKey = view.getUint8(0) === 1;
      const timestampUs = Number(view.getBigInt64(1));
      const descLen = view.getUint16(9);
      const offset = 11 + descLen;

      // When GStreamer emits AVCC description (extradata) on caps
      if (descLen > 0 && (!hasConfiguredRef.current || decoderRef.current.state === 'unconfigured')) {
        const desc = new Uint8Array(buffer, 11, descLen);
        lastDescRef.current = desc;

        // Derive codec string from AVCDecoderConfigurationRecord bytes 1..3 (profile, constraints, level)
        let codecStr = 'avc1.42c032';
        if (descLen >= 4) {
          const profile = desc[1].toString(16).padStart(2, '0');
          const constraints = desc[2].toString(16).padStart(2, '0');
          const level = desc[3].toString(16).padStart(2, '0');
          codecStr = `avc1.${profile}${constraints}${level}`;
        }

        if (currentCodecRef.current !== codecStr || !hasConfiguredRef.current) {
          try {
            decoderRef.current.configure({
              codec: codecStr,
              description: desc,
              hardwareAcceleration: hwAccelRef.current,
              optimizeForLatency: true,
            });
            hasConfiguredRef.current = true;
            currentCodecRef.current = codecStr;
          } catch (err: any) {
            console.error(`[Stream ${streamId}] Decoder configure failed (${codecStr}):`, err?.message || err);
          }
        }
      }

      if (!hasConfiguredRef.current || decoderRef.current.state !== 'configured') {
        return;
      }

      // WebCodecs requires decoding to start with a keyframe
      if (!hasSeenKeyframeRef.current) {
        if (!isKey) return;
        hasSeenKeyframeRef.current = true;
      }

      // Skip in-band parameter sets (SPS=7, PPS=8, SEI=6) so IDR slice (type 5) starts the chunk
      let nalOffset = offset;
      const nalView = new DataView(buffer);
      while (nalOffset + 4 < buffer.byteLength) {
        const nalLen = nalView.getUint32(nalOffset);
        if (nalOffset + 4 + nalLen > buffer.byteLength) break;
        const nalType = (new Uint8Array(buffer, nalOffset + 4, 1))[0] & 0x1f;
        if (nalType === 7 || nalType === 8 || nalType === 6) {
          nalOffset += 4 + nalLen;
        } else {
          break;
        }
      }

      const nalData = new Uint8Array(buffer, nalOffset);
      if (nalData.length === 0) return;

      // Backpressure guard: if decoder queue is severely backed up, drop delta frames
      if (!isKey && decoderRef.current.decodeQueueSize > 2) {
        return;
      }

      try {
        const chunk = new EncodedVideoChunk({
          type: isKey ? 'key' : 'delta',
          timestamp: timestampUs,
          data: nalData,
        });
        decoderRef.current.decode(chunk);
      } catch (decodeErr: any) {
        console.warn(`[Stream ${streamId}] decode error:`, decodeErr?.message || decodeErr);
      }
    };

    ws.onclose = () => {
      isConnectedRef.current = false;
      lastPtsRef.current = null;
      if (!isDestroyed && statusDotRef.current) {
        statusDotRef.current.className = 'status-dot offline';
      }
    };

    return () => {
      isDestroyed = true;
      if (resizeObserver) {
        resizeObserver.disconnect();
      }
      if (wsRef.current) {
        wsRef.current.close();
        wsRef.current = null;
      }
      if (decoderRef.current) {
        if (decoderRef.current.state !== 'closed') {
          try { decoderRef.current.close(); } catch { /* ignore */ }
        }
        decoderRef.current = null;
      }
    };
  }, [streamId, wsPort]);

  return (
    <div className="video-player-card">
      <div className="player-overlay">
        <span ref={statusDotRef} className="status-dot waiting" />
        <span className="stream-id-tag">CH-{String(streamId + 1).padStart(2, '0')}</span>
        <span ref={fpsBadgeRef} className="fps-badge warning">0 FPS</span>
      </div>
      <canvas ref={canvasRef} className="video-canvas" width={2560} height={1440} />
      <div ref={placeholderRef} className="waiting-placeholder">
        <span>Connecting CH-{streamId + 1}...</span>
      </div>
    </div>
  );
});

VideoPlayer.displayName = 'VideoPlayer';
