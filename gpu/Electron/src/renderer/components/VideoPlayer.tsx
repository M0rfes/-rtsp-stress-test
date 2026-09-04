import React, { useEffect, useRef, useImperativeHandle, forwardRef } from 'react';

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

type HwAccelPref = 'no-preference' | 'prefer-hardware' | 'prefer-software';

function isMacPlatform(): boolean {
  const preloadPlatform = (window as unknown as { electronBenchmark?: { platform?: string } }).electronBenchmark?.platform;
  if (preloadPlatform) return preloadPlatform === 'darwin';
  return /Mac/i.test(navigator.userAgent);
}

export const VideoPlayer = forwardRef<VideoPlayerRef, VideoPlayerProps>(({ streamId, wsPort }, ref) => {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const fpsBadgeRef = useRef<HTMLSpanElement | null>(null);
  const statusDotRef = useRef<HTMLSpanElement | null>(null);
  const placeholderRef = useRef<HTMLDivElement | null>(null);

  // High performance mutable refs to decouple video rendering from React render cycle
  const frameCountRef = useRef<number>(0);
  const lastTickTimeRef = useRef<number>(performance.now());
  const lastPtsRef = useRef<number | null>(null);
  const lastPresentedTimeRef = useRef<number>(0);
  const lastDeltaMsRef = useRef<number>(0);
  const isConnectedRef = useRef<boolean>(false);
  const connectedSinceRef = useRef<number>(0);
  const pendingFramesRef = useRef<number>(0);
  const hasConfiguredRef = useRef<boolean>(false);
  const currentCodecRef = useRef<string>('');
  const decoderRef = useRef<VideoDecoder | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const hwAccelRef = useRef<HwAccelPref>('prefer-hardware');
  const presentSizeRef = useRef({ width: 0, height: 0 });
  const isMac = isMacPlatform();

  // Offscreen canvas and BitmapRenderer context refs
  const offscreenCanvasRef = useRef<OffscreenCanvas | null>(null);
  const bitmapCtxRef = useRef<ImageBitmapRenderingContext | null>(null);

  useImperativeHandle(ref, () => ({
    getFpsAndReset: () => {
      const now = performance.now();
      const elapsedSec = (now - lastTickTimeRef.current) / 1000;
      lastTickTimeRef.current = now;
      const fps = elapsedSec > 0 ? Math.round(frameCountRef.current / elapsedSec) : 0;
      frameCountRef.current = 0;
      return fps;
    },
    getReportAndReset: () => {
      const now = performance.now();
      const elapsedSec = (now - lastTickTimeRef.current) / 1000;
      lastTickTimeRef.current = now;
      const fps = elapsedSec > 0 ? Math.round(frameCountRef.current / elapsedSec) : 0;
      frameCountRef.current = 0;
      // Only mark connected if we've been receiving frames for at least 1s
      const connected = isConnectedRef.current
        && lastPresentedTimeRef.current > 0
        && now - lastPresentedTimeRef.current < 3000
        && connectedSinceRef.current > 0
        && now - connectedSinceRef.current >= 1000;
      return {
        streamId,
        fps,
        isConnected: connected,
        lastDeltaMs: lastDeltaMsRef.current,
      };
    },
    updateFpsDisplay: (fps: number) => {
      // Direct DOM update: zero React re-renders for maximum V8 throughput
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

    // Architecture Constraint:
    // "Render the VideoFrame objects to an OffscreenCanvas. You MUST use the BitmapRenderer context
    // (transferFromImageBitmap) or WebGPU (importExternalTexture) to ensure zero-copy GPU-to-GPU transfer.
    // Do not use Canvas 2D drawImage."
    let offscreen: OffscreenCanvas | null = offscreenCanvasRef.current;
    let bitmapCtx: ImageBitmapRenderingContext | null = bitmapCtxRef.current;

    if (!bitmapCtx) {
      try {
        if ('transferControlToOffscreen' in canvas && !offscreenCanvasRef.current) {
          offscreen = canvas.transferControlToOffscreen();
          offscreenCanvasRef.current = offscreen;
          bitmapCtx = offscreen.getContext('bitmaprenderer') as ImageBitmapRenderingContext | null;
        }
      } catch (err) {
        console.warn(`[Stream ${streamId}] transferControlToOffscreen fallback:`, err);
      }

      if (!bitmapCtx) {
        bitmapCtx = canvas.getContext('bitmaprenderer') as ImageBitmapRenderingContext | null;
      }
      bitmapCtxRef.current = bitmapCtx;
    }

    if (!bitmapCtx) {
      console.error(`[Stream ${streamId}] Failed to acquire ImageBitmapRenderingContext`);
      return;
    }

    const updatePresentSize = () => {
      const dpr = window.devicePixelRatio || 1;
      const cssW = Math.max(1, Math.round(canvas.clientWidth * dpr));
      const cssH = Math.max(1, Math.round(canvas.clientHeight * dpr));
      presentSizeRef.current = { width: cssW, height: cssH };
    };
    updatePresentSize();
    const resizeObserver = typeof ResizeObserver !== 'undefined'
      ? new ResizeObserver(updatePresentSize)
      : null;
    if (resizeObserver) {
      resizeObserver.observe(canvas.parentElement || canvas);
    }

    // Helper to find SPS in Annex B buffer and extract codec string (H.264 Level 5.0+ for 1440p)
    const extractSpsCodec = (data: Uint8Array): string | null => {
      for (let i = 0; i < data.length - 5; i++) {
        let scLen = 0;
        if (data[i] === 0 && data[i + 1] === 0) {
          if (data[i + 2] === 1) scLen = 3;
          else if (data[i + 2] === 0 && data[i + 3] === 1) scLen = 4;
        }
        if (scLen > 0) {
          const nalType = data[i + scLen] & 0x1F;
          if (nalType === 7 && i + scLen + 3 < data.length) {
            const profile = data[i + scLen + 1].toString(16).padStart(2, '0');
            const constraints = data[i + scLen + 2].toString(16).padStart(2, '0');
            const level = data[i + scLen + 3].toString(16).padStart(2, '0');
            return `avc1.${profile}${constraints}${level}`;
          }
          i += scLen;
        }
      }
      return null;
    };

    const onDecodedFrame = (videoFrame: VideoFrame) => {
      if (isDestroyed) {
        videoFrame.close();
        return;
      }

      const curPts = videoFrame.timestamp;
      if (lastPtsRef.current !== null && curPts === lastPtsRef.current) {
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

      if (offscreen) {
        if (offscreen.width !== targetW || offscreen.height !== targetH) {
          offscreen.width = targetW;
          offscreen.height = targetH;
        }
      } else if (canvas) {
        if (canvas.width !== targetW || canvas.height !== targetH) {
          canvas.width = targetW;
          canvas.height = targetH;
        }
      }

      pendingFramesRef.current++;

      const bitmapOptions: ImageBitmapOptions | undefined = isMac
        ? { resizeWidth: targetW, resizeHeight: targetH, resizeQuality: 'low' }
        : undefined;

      const bitmapPromise = bitmapOptions
        ? createImageBitmap(videoFrame, bitmapOptions)
        : createImageBitmap(videoFrame);
      bitmapPromise
        .then((bitmap) => {
          videoFrame.close();
          pendingFramesRef.current--;

          if (isDestroyed) {
            bitmap.close();
            return;
          }

          if (bitmapCtxRef.current) {
            bitmapCtxRef.current.transferFromImageBitmap(bitmap);

            const now = performance.now();
            if (lastPresentedTimeRef.current > 0) {
              lastDeltaMsRef.current = now - lastPresentedTimeRef.current;
            }
            lastPresentedTimeRef.current = now;
            if (!isConnectedRef.current) {
              connectedSinceRef.current = now;
            }
            isConnectedRef.current = true;
            frameCountRef.current++;
          } else {
            bitmap.close();
          }

          if (placeholderRef.current && placeholderRef.current.style.display !== 'none') {
            placeholderRef.current.style.display = 'none';
          }
        })
        .catch(() => {
          pendingFramesRef.current--;
          videoFrame.close();
        });
    };

    const createDecoder = (): VideoDecoder | null => {
      try {
        return new VideoDecoder({
          output: onDecodedFrame,
          error: (err) => {
            console.warn(`[Stream ${streamId}] VideoDecoder error:`, err);
            hasConfiguredRef.current = false;
            if (isMac && hwAccelRef.current === 'prefer-hardware') {
              hwAccelRef.current = 'no-preference';
              console.warn(`[Stream ${streamId}] VideoToolbox session saturated, falling back to no-preference`);
            }
          },
        });
      } catch (err) {
        console.error(`[Stream ${streamId}] Failed to initialize VideoDecoder:`, err);
        return null;
      }
    };

    decoderRef.current = createDecoder();
    if (!decoderRef.current) {
      return;
    }

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
      if (isDestroyed || !decoderRef.current) return;
      if (typeof event.data === 'string') return;

      const buffer = event.data as ArrayBuffer;
      if (buffer.byteLength < 10) return;

      const view = new DataView(buffer);
      const isKey = view.getUint8(0) === 1;
      const timestampUs = Number(view.getBigInt64(1));
      const nalData = new Uint8Array(buffer, 9);

      if (isKey) {
        const detectedCodec = extractSpsCodec(nalData) || 'avc1.42c032';
        const needsConfig = !hasConfiguredRef.current
          || currentCodecRef.current !== detectedCodec
          || decoderRef.current.state !== 'configured';
        if (needsConfig) {
          try {
            if (decoderRef.current.state === 'closed') {
              const nextDecoder = createDecoder();
              if (!nextDecoder) return;
              decoderRef.current = nextDecoder;
            }
            decoderRef.current.configure({
              codec: detectedCodec,
              avc: { format: 'annexb' },
              hardwareAcceleration: hwAccelRef.current,
              optimizeForLatency: true,
            });
            hasConfiguredRef.current = true;
            currentCodecRef.current = detectedCodec;
          } catch (configErr) {
            console.error(`[Stream ${streamId}] Failed to configure decoder with ${detectedCodec}:`, configErr);
          }
        }
      }

      // Can only decode if decoder has been configured with a keyframe
      if (!hasConfiguredRef.current || decoderRef.current.state !== 'configured') {
        return;
      }

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
      } catch (decodeErr) {
        console.warn(`[Stream ${streamId}] decode error:`, decodeErr);
      }
    };

    ws.onclose = () => {
      isConnectedRef.current = false;
      connectedSinceRef.current = 0;
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
          decoderRef.current.close();
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
