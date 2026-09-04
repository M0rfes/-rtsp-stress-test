import { useEffect, useRef, useImperativeHandle, forwardRef } from 'react';

export interface StreamFpsReport {
  streamId: number;
  fps: number;
  isConnected: boolean;
  lastDeltaMs: number;
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

  // High-performance mutable refs — zero React re-render overhead
  const frameCountRef = useRef<number>(0);
  const lastPtsRef = useRef<number | null>(null);
  const lastPresentedTimeRef = useRef<number>(0);
  const lastDeltaMsRef = useRef<number>(0);
  const isConnectedRef = useRef<boolean>(false);
  const hasRenderedFirstFrameRef = useRef<boolean>(false);
  const hasSeenKeyframeRef = useRef<boolean>(false);
  const decoderRef = useRef<VideoDecoder | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  useImperativeHandle(ref, () => ({
    getFpsAndReset: () => {
      const fps = frameCountRef.current;
      frameCountRef.current = 0;
      return fps;
    },
    getReportAndReset: () => {
      const fps = frameCountRef.current;
      frameCountRef.current = 0;
      const now = performance.now();
      const connected = isConnectedRef.current && (lastPresentedTimeRef.current > 0 && now - lastPresentedTimeRef.current < 3000);
      return {
        streamId,
        fps,
        isConnected: connected,
        lastDeltaMs: lastDeltaMsRef.current,
      };
    },
    updateFpsDisplay: (fps: number) => {
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

    // Use ImageBitmapRenderingContext for direct GPU compositor transfer
    let bitmapCtx: ImageBitmapRenderingContext | null = null;
    let ctx2d: CanvasRenderingContext2D | null = null;

    const isMac = isMacPlatform();
    try {
      bitmapCtx = canvas.getContext('bitmaprenderer');
    } catch {
      // Fallback to 2D
    }
    if (!bitmapCtx) {
      ctx2d = canvas.getContext('2d', { alpha: false, desynchronized: isMac });
      if (ctx2d && isMac) {
        ctx2d.imageSmoothingEnabled = false;
      }
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

            // Effective FPS gate: only count frames with a new unique PTS
            const curPts = videoFrame.timestamp;
            if (curPts === lastPtsRef.current) {
              videoFrame.close();
              return;
            }
            lastPtsRef.current = curPts;

            if (streamId === 0 && !hasRenderedFirstFrameRef.current) {
              hasRenderedFirstFrameRef.current = true;
              console.log(`[Stream 0] SUCCESS: First frame rendered via ImageBitmap! Dimensions: ${videoFrame.displayWidth}x${videoFrame.displayHeight}`);
            }

            // Convert hardware VideoFrame to ImageBitmap to guarantee display on WebKit
            const dpr = window.devicePixelRatio || 1;
            const targetW = isMac
              ? Math.max(1, Math.round((canvas.clientWidth || videoFrame.displayWidth) * dpr))
              : videoFrame.displayWidth;
            const targetH = isMac
              ? Math.max(1, Math.round((canvas.clientHeight || videoFrame.displayHeight) * dpr))
              : videoFrame.displayHeight;
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

                if (bitmapCtx) {
                  bitmapCtx.transferFromImageBitmap(bitmap);
                } else if (ctx2d) {
                  if (canvas.width !== bitmap.width || canvas.height !== bitmap.height) {
                    canvas.width = bitmap.width;
                    canvas.height = bitmap.height;
                  }
                  ctx2d.drawImage(bitmap, 0, 0);
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
            console.warn(`[Stream ${streamId}] Decoder error: ${err?.message || err}`);
            hasSeenKeyframeRef.current = false;
            // Delay recreation to prevent cascading restart loops
            setTimeout(() => {
              if (!isDestroyed) createDecoder();
            }, 500);
          },
        });

        decoderRef.current = decoder;
      } catch (err: any) {
        console.error(`[Stream ${streamId}] Failed to create VideoDecoder:`, err?.message || err);
      }
    };

    createDecoder();

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
      if (isDestroyed || !decoderRef.current) return;
      if (typeof event.data === 'string') return;

      const buffer = event.data as ArrayBuffer;
      if (buffer.byteLength < 11) return;

      const view = new DataView(buffer);
      const isKey = view.getUint8(0) === 1;
      const timestampUs = Number(view.getBigInt64(1));
      const descLen = view.getUint16(9);
      const offset = 11 + descLen;

      // Extract native AVCC description produced by GStreamer
      if (descLen > 0 && decoderRef.current.state === 'unconfigured') {
        const desc = new Uint8Array(buffer, 11, descLen);
        try {
          decoderRef.current.configure({
            codec: 'avc1.42c032',
            description: desc,
            optimizeForLatency: true,
            hardwareAcceleration: 'prefer-software',
          });
        } catch (err: any) {
          console.error(`[Stream ${streamId}] Decoder configure failed:`, err?.message || err);
        }
      }

      if (decoderRef.current.state !== 'configured') {
        return;
      }

      // WebCodecs constraint: must start decoding with a keyframe
      if (!hasSeenKeyframeRef.current) {
        if (!isKey) return;
        hasSeenKeyframeRef.current = true;
      }

      // Skip in-band parameter sets (SPS=7, PPS=8, SEI=6) so keyframe chunk begins with IDR slice (type 5)
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

      // Backpressure guard: if decoder queue is backed up, drop delta frame
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
      <canvas ref={canvasRef} className="video-canvas" />
      <div ref={placeholderRef} className="waiting-placeholder">
        <span>Connecting CH-{streamId + 1}...</span>
      </div>
    </div>
  );
});

VideoPlayer.displayName = 'VideoPlayer';
