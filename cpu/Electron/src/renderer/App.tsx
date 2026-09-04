import React, { useEffect, useRef, useState } from 'react';
import { VideoGrid } from './components/VideoGrid';
import { StatsBar, TelemetrySummary } from './components/StatsBar';
import { VideoPlayerRef } from './components/VideoPlayer';

interface InitData {
  streamCount: number;
  framework: string;
  hardwareMode: string;
  targetFps: number;
  windowDurationSeconds: number;
  machineId: string;
  logPath: string;
}

export const App: React.FC = () => {
  const [streamCount, setStreamCount] = useState<number>(() => {
    // Check if preload exposed streamCount or query param
    const win = window as any;
    if (win.electronBenchmark?.streamCount) {
      return win.electronBenchmark.streamCount;
    }
    const params = new URLSearchParams(window.location.search);
    return parseInt(params.get('streams') || '30', 10);
  });

  const wsPort = (window as any).electronBenchmark?.wsPort || 9999;
  const playerRefs = useRef<Map<number, VideoPlayerRef>>(new Map());
  const controlWsRef = useRef<WebSocket | null>(null);

  const [stats, setStats] = useState<TelemetrySummary>({
    machineId: 'initializing...',
    framework: 'electron',
    hardwareMode: 'cpu',
    activeStreams: streamCount,
    currentWindowSec: 0,
    acceptable25to30: 0,
    acceptable20to24: 0,
    unacceptable10to19: 0,
    unacceptable5to9: 0,
    unacceptableUnder5: 0,
    avgFps: 0,
    logPath: '/var/log/benchmark/fps_metrics.log',
  });

  // Connect to control WebSocket
  useEffect(() => {
    const ws = new WebSocket(`ws://127.0.0.1:${wsPort}/control`);
    controlWsRef.current = ws;

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'init') {
          const data: InitData = msg.data;
          setStreamCount(data.streamCount);
          setStats((prev) => ({
            ...prev,
            machineId: data.machineId,
            framework: data.framework,
            hardwareMode: data.hardwareMode,
            activeStreams: data.streamCount,
            logPath: data.logPath,
          }));
        } else if (msg.type === 'telemetry_tick') {
          const { payload, currentWindowSec, streamFpsList } = msg.data;
          const sumFps = (streamFpsList as number[]).reduce((a, b) => a + b, 0);
          const avg = streamFpsList.length > 0 ? sumFps / streamFpsList.length : 0;

          setStats((prev) => ({
            ...prev,
            currentWindowSec,
            acceptable25to30: payload.fps_stream_seconds.acceptable['25_to_30_fps'],
            acceptable20to24: payload.fps_stream_seconds.acceptable['20_to_24_fps'],
            unacceptable10to19: payload.fps_stream_seconds.unacceptable['10_to_19_fps'],
            unacceptable5to9: payload.fps_stream_seconds.unacceptable['5_to_9_fps'],
            unacceptableUnder5: payload.fps_stream_seconds.unacceptable['under_5_fps'],
            avgFps: avg,
          }));
        }
      } catch (err) {
        console.error('Failed to parse control message:', err);
      }
    };

    return () => {
      ws.close();
      controlWsRef.current = null;
    };
  }, [wsPort]);

  // 1-Second Interval: The Master Benchmark Tick
  // Queries each video player for its painted frame count, updates player overlays directly,
  // and transmits the streamFpsList array to the backend telemetry manager
  useEffect(() => {
    const interval = setInterval(() => {
      const streamFpsList: number[] = [];
      const streamReports: { streamId: number; fps: number; isConnected: boolean; lastDeltaMs: number; uiFrames: number; decodedFrames: number }[] = [];

      for (let i = 0; i < streamCount; i++) {
        const player = playerRefs.current.get(i);
        const report = player ? player.getReportAndReset() : { streamId: i, fps: 0, isConnected: false, lastDeltaMs: 0, uiFrames: 0, decodedFrames: 0 };
        streamFpsList.push(report.fps);
        streamReports.push(report);
        if (player) {
          player.updateFpsDisplay(report.fps);
        }
      }

      // Send to backend via control WebSocket
      if (controlWsRef.current && controlWsRef.current.readyState === WebSocket.OPEN) {
        controlWsRef.current.send(
          JSON.stringify({
            type: 'tick_fps',
            streamFpsList,
            streamReports,
          })
        );
      }
    }, 1000);

    return () => clearInterval(interval);
  }, [streamCount]);

  return (
    <>
      <StatsBar stats={stats} />
      <VideoGrid streamCount={streamCount} wsPort={wsPort} playerRefs={playerRefs} />
    </>
  );
};
