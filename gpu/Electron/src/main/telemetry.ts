import fs from 'fs';
import path from 'path';
import { config } from './config';

export interface FpsStreamSeconds {
  acceptable: {
    '25_to_30_fps': number;
    '20_to_24_fps': number;
  };
  unacceptable: {
    '10_to_19_fps': number;
    '5_to_9_fps': number;
    'under_5_fps': number;
  };
}

export interface FpsMetricsPayload {
  timestamp: string;
  machine_id: string;
  framework: string;
  hardware_mode: string;
  window_duration_seconds: number;
  active_streams: number;
  fps_stream_seconds: FpsStreamSeconds;
}

export class TelemetryManager {
  private currentBuckets: FpsStreamSeconds;
  private tickCountInWindow: number = 0;
  private totalFlushes: number = 0;
  private logFilePath: string;
  private activeStreams: number;
  private listeners: ((payload: FpsMetricsPayload, currentWindowSec: number, streamFpsList: number[]) => void)[] = [];

  constructor() {
    this.activeStreams = config.streamCount;
    this.currentBuckets = this.createEmptyBuckets();
    this.logFilePath = this.resolveLogFilePath(config.fpsLogPath);
  }

  private createEmptyBuckets(): FpsStreamSeconds {
    return {
      acceptable: {
        '25_to_30_fps': 0,
        '20_to_24_fps': 0,
      },
      unacceptable: {
        '10_to_19_fps': 0,
        '5_to_9_fps': 0,
        'under_5_fps': 0,
      },
    };
  }

  private resolveLogFilePath(targetPath: string): string {
    const dir = path.dirname(targetPath);
    try {
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }
      fs.accessSync(dir, fs.constants.W_OK);
      return targetPath;
    } catch (err) {
      console.warn(`[Telemetry] Cannot write to ${targetPath} (${(err as Error).message}). Falling back to local ./logs directory.`);
      const fallbackDir = path.resolve(process.cwd(), 'logs');
      if (!fs.existsSync(fallbackDir)) {
        fs.mkdirSync(fallbackDir, { recursive: true });
      }
      return path.join(fallbackDir, 'fps_metrics.log');
    }
  }

  /**
   * Called on every 1-second tick with the frame counts painted by each stream.
   * @param streamFpsList Array of FPS painted during the past second for each stream.
   */
  public recordTick(streamFpsList: number[]): void {
    this.tickCountInWindow++;
    this.activeStreams = streamFpsList.length;

    for (const fps of streamFpsList) {
      if (fps >= 25) {
        this.currentBuckets.acceptable['25_to_30_fps']++;
      } else if (fps >= 20) {
        this.currentBuckets.acceptable['20_to_24_fps']++;
      } else if (fps >= 10) {
        this.currentBuckets.unacceptable['10_to_19_fps']++;
      } else if (fps >= 5) {
        this.currentBuckets.unacceptable['5_to_9_fps']++;
      } else {
        this.currentBuckets.unacceptable['under_5_fps']++;
      }
    }

    const currentPayload = this.buildPayload();
    this.notifyListeners(currentPayload, this.tickCountInWindow, streamFpsList);

    if (this.tickCountInWindow >= config.windowDurationSeconds) {
      this.flushToDisk();
    }
  }

  public flushToDisk(): void {
    const payload = this.buildPayload();
    const jsonString = JSON.stringify(payload, null, 2);

    try {
      // Append to the log file so continuous 24h benchmark records all 60s windows
      fs.appendFileSync(this.logFilePath, jsonString + '\n\n', 'utf-8');
      this.totalFlushes++;
      console.log(`[Telemetry] Flushed 60s window #${this.totalFlushes} to ${this.logFilePath}`);
      console.log(`[Telemetry] Stats (Mode: ${config.hardwareMode}): Acceptable (25-30: ${payload.fps_stream_seconds.acceptable['25_to_30_fps']}, 20-24: ${payload.fps_stream_seconds.acceptable['20_to_24_fps']}), Unacceptable (<5: ${payload.fps_stream_seconds.unacceptable['under_5_fps']})`);
    } catch (err) {
      console.error(`[Telemetry] Error writing metrics to ${this.logFilePath}:`, err);
    }

    // Immediately reset internal counters to zero for the next window
    this.currentBuckets = this.createEmptyBuckets();
    this.tickCountInWindow = 0;
  }

  public buildPayload(): FpsMetricsPayload {
    return {
      timestamp: new Date().toISOString(),
      machine_id: config.machineId,
      framework: config.framework,
      hardware_mode: config.hardwareMode,
      window_duration_seconds: config.windowDurationSeconds,
      active_streams: this.activeStreams,
      fps_stream_seconds: {
        acceptable: { ...this.currentBuckets.acceptable },
        unacceptable: { ...this.currentBuckets.unacceptable },
      },
    };
  }

  public onUpdate(fn: (payload: FpsMetricsPayload, currentWindowSec: number, streamFpsList: number[]) => void): void {
    this.listeners.push(fn);
  }

  private notifyListeners(payload: FpsMetricsPayload, currentWindowSec: number, streamFpsList: number[]): void {
    for (const listener of this.listeners) {
      try {
        listener(payload, currentWindowSec, streamFpsList);
      } catch (err) {
        console.error('[Telemetry] Listener error:', err);
      }
    }
  }

  public getLogPath(): string {
    return this.logFilePath;
  }
}

export const telemetry = new TelemetryManager();
