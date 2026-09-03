import React, { useEffect, useRef, useImperativeHandle, forwardRef } from 'react';

export interface VideoPlayerRef {
  getFpsAndReset: () => number;
  updateFpsDisplay: (fps: number) => void;
}

interface VideoPlayerProps {
  streamId: number;
  wsPort: number;
}

export const VideoPlayer = forwardRef<VideoPlayerRef, VideoPlayerProps>(({ streamId, wsPort }, ref) => {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const fpsBadgeRef = useRef<HTMLSpanElement | null>(null);
  const statusDotRef = useRef<HTMLSpanElement | null>(null);
  const placeholderRef = useRef<HTMLDivElement | null>(null);

  // High performance mutable refs to decouple video rendering from React render cycle
  const frameCountRef = useRef<number>(0);
  const pendingFramesRef = useRef<number>(0);
  const hasConfiguredRef = useRef<boolean>(false);
  const currentCodecRef = useRef<string>('');
  const decoderRef = useRef<VideoDecoder | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  // Offscreen canvas and BitmapRenderer context refs
  const offscreenCanvasRef = useRef<OffscreenCanvas | null>(null);
  const bitmapCtxRef = useRef<ImageBitmapRenderingContext | null>(null);

  useImperativeHandle(ref, () => ({
    getFpsAndReset: () => {
      const fps = frameCountRef.current;
      frameCountRef.current = 0;
      return fps;
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

    // Initialize hardware-accelerated VideoDecoder
    try {
      const decoder = new VideoDecoder({
        output: (videoFrame: VideoFrame) => {
          if (isDestroyed) {
            videoFrame.close();
            return;
          }

          // Adjust canvas/offscreen dimensions to match decoded frame
          if (offscreen) {
            if (offscreen.width !== videoFrame.displayWidth || offscreen.height !== videoFrame.displayHeight) {
              offscreen.width = videoFrame.displayWidth;
              offscreen.height = videoFrame.displayHeight;
            }
          } else if (canvas) {
            if (canvas.width !== videoFrame.displayWidth || canvas.height !== videoFrame.displayHeight) {
              canvas.width = videoFrame.displayWidth;
              canvas.height = videoFrame.displayHeight;
            }
          }

          // Prevent queue buildup under extreme load
          if (pendingFramesRef.current > 2) {
            videoFrame.close();
            return;
          }

          pendingFramesRef.current++;

          // Zero-copy GPU-to-GPU transfer via ImageBitmap and BitmapRenderer context
          createImageBitmap(videoFrame)
            .then((bitmap) => {
              videoFrame.close();
              pendingFramesRef.current--;

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

              frameCountRef.current++;

              if (placeholderRef.current && placeholderRef.current.style.display !== 'none') {
                placeholderRef.current.style.display = 'none';
              }
            })
            .catch((err) => {
              pendingFramesRef.current--;
              videoFrame.close();
            });
        },
        error: (err) => {
          console.error(`[Stream ${streamId}] VideoDecoder error:`, err);
        },
      });

      decoderRef.current = decoder;
    } catch (err) {
      console.error(`[Stream ${streamId}] Failed to initialize VideoDecoder:`, err);
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

      // On keyframe, extract SPS to configure or reconfigure VideoDecoder
      if (isKey) {
        const detectedCodec = extractSpsCodec(nalData) || 'avc1.42c032';
        if (!hasConfiguredRef.current || currentCodecRef.current !== detectedCodec) {
          try {
            decoderRef.current.configure({
              codec: detectedCodec,
              avc: { format: 'annexb' },
              hardwareAcceleration: 'prefer-hardware', // Explicitly request GPU decoding
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
