import { spawn, ChildProcess } from 'child_process';
import { EventEmitter } from 'events';
import { getRtspUrlForStream } from './config';
import { STREAM_STAGGER_MS } from './platform';

export interface StreamFrameEvent {
  streamId: number;
  isKey: boolean;
  timestampUs: bigint;
  data: Buffer;
}

export class RtspDemuxer extends EventEmitter {
  public readonly streamId: number;
  public readonly rtspUrl: string;
  private ffmpegProcess: ChildProcess | null = null;
  private isRunning: boolean = false;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private buffer: Buffer = Buffer.alloc(0);
  private currentAuBuffers: Buffer[] = [];
  private hasVclInCurrentAu: boolean = false;
  private currentAuHasKey: boolean = false;
  private currentAuHasSps: boolean = false;
  private lastSps: Buffer | null = null;
  private lastPps: Buffer | null = null;
  private frameCount: number = 0;
  private startTimeUs: bigint = 0n;

  constructor(streamId: number, rtspUrl?: string) {
    super();
    this.streamId = streamId;
    this.rtspUrl = rtspUrl || getRtspUrlForStream(streamId);
  }

  public start(): void {
    if (this.isRunning) return;
    this.isRunning = true;
    this.startTimeUs = BigInt(Math.floor(performance.now() * 1000));
    this.spawnFfmpeg();
  }

  public stop(): void {
    this.isRunning = false;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ffmpegProcess) {
      this.ffmpegProcess.kill('SIGTERM');
      this.ffmpegProcess = null;
    }
    this.buffer = Buffer.alloc(0);
    this.currentAuBuffers = [];
    this.hasVclInCurrentAu = false;
    this.currentAuHasKey = false;
  }

  private spawnFfmpeg(): void {
    if (!this.isRunning) return;

    // FFmpeg demux command:
    // -rtsp_transport tcp: reliable RTSP packet delivery without UDP loss
    // -i <url>: RTSP input
    // -c:v copy: strictly demux without decoding (no CPU decode)
    // -bsf:v "h264_mp4toannexb,dump_extra=freq=keyframe": ensure SPS/PPS on every keyframe in Annex B format
    // -f h264 pipe:1: output Annex B byte stream to stdout
    const args = [
      '-loglevel', 'error',
      '-rtsp_transport', 'tcp',
      '-i', this.rtspUrl,
      '-c:v', 'copy',
      '-bsf:v', 'h264_mp4toannexb,dump_extra=freq=keyframe',
      '-f', 'h264',
      'pipe:1'
    ];

    try {
      this.ffmpegProcess = spawn('ffmpeg', args, {
        stdio: ['ignore', 'pipe', 'pipe']
      });

      this.ffmpegProcess.stdout?.on('data', (chunk: Buffer) => {
        this.handleData(chunk);
      });

      this.ffmpegProcess.stderr?.on('data', (data: Buffer) => {
        const msg = data.toString().trim();
        if (msg) {
          console.warn(`[Demuxer ${this.streamId}] FFmpeg stderr: ${msg}`);
        }
      });

      this.ffmpegProcess.on('close', (code) => {
        this.ffmpegProcess = null;
        this.buffer = Buffer.alloc(0);
        this.currentAuBuffers = [];
        this.hasVclInCurrentAu = false;
        this.currentAuHasKey = false;
        if (this.isRunning) {
          console.warn(`[Demuxer ${this.streamId}] FFmpeg exited with code ${code}. Reconnecting in 3s...`);
          this.reconnectTimer = setTimeout(() => this.spawnFfmpeg(), 3000);
        }
      });

      this.ffmpegProcess.on('error', (err) => {
        console.error(`[Demuxer ${this.streamId}] FFmpeg spawn error:`, err.message);
      });
    } catch (err) {
      console.error(`[Demuxer ${this.streamId}] Failed to start FFmpeg:`, err);
      if (this.isRunning) {
        this.reconnectTimer = setTimeout(() => this.spawnFfmpeg(), 3000);
      }
    }
  }

  /**
   * Parses continuous incoming Annex B bytes into NAL units and emits complete Access Units.
   */
  private handleData(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    let startIndex = 0;
    while (startIndex < this.buffer.length) {
      const startCodeInfo = this.findNextStartCode(this.buffer, startIndex);
      if (!startCodeInfo) {
        this.buffer = this.buffer.subarray(startIndex);
        return;
      }

      const nextStartCodeInfo = this.findNextStartCode(this.buffer, startCodeInfo.offset + startCodeInfo.length);
      if (!nextStartCodeInfo) {
        this.buffer = this.buffer.subarray(startCodeInfo.offset);
        return;
      }

      // We have an entire NAL unit between startCodeInfo.offset and nextStartCodeInfo.offset
      const nalRaw = this.buffer.subarray(startCodeInfo.offset, nextStartCodeInfo.offset);
      const nalType = this.buffer[startCodeInfo.offset + startCodeInfo.length] & 0x1F;

      this.processNalUnit(nalRaw, nalType, startCodeInfo.length);

      startIndex = nextStartCodeInfo.offset;
    }

    this.buffer = Buffer.alloc(0);
  }

  private processNalUnit(nalRaw: Buffer, nalType: number, startCodeLen: number): void {
    // Cache SPS and PPS for guaranteeing self-contained keyframes
    if (nalType === 7) {
      this.lastSps = Buffer.from(nalRaw);
    } else if (nalType === 8) {
      this.lastPps = Buffer.from(nalRaw);
    }

    // Check if this NAL unit marks the boundary of a new Access Unit (coded picture)
    let isNewAu = false;

    if (nalType === 9 || nalType === 7 || nalType === 8 || nalType === 6) {
      // Non-VCL NAL unit (AUD, SPS, PPS, SEI) arriving after slices marks a new frame
      if (this.hasVclInCurrentAu) {
        isNewAu = true;
      }
    } else if (nalType === 1 || nalType === 5) {
      // VCL slice: check if first_mb_in_slice == 0 (bit 7 of the byte following NAL header is 1)
      const headerByte = nalRaw[startCodeLen + 1];
      const isFirstMb = headerByte !== undefined ? (headerByte & 0x80) !== 0 : true;

      if (this.hasVclInCurrentAu && isFirstMb) {
        isNewAu = true;
      }
    }

    if (isNewAu && this.currentAuBuffers.length > 0) {
      this.emitCurrentAccessUnit();
    }

    // Append NAL unit to current Access Unit
    this.currentAuBuffers.push(nalRaw);

    if (nalType === 1 || nalType === 5) {
      this.hasVclInCurrentAu = true;
    }
    if (nalType === 5) {
      this.currentAuHasKey = true;
    }
    if (nalType === 7) {
      this.currentAuHasKey = true;
      this.currentAuHasSps = true;
    }
  }

  private emitCurrentAccessUnit(): void {
    if (this.currentAuBuffers.length === 0) return;

    // If this is a keyframe and SPS is not in the current AU, prepend cached SPS and PPS
    if (this.currentAuHasKey && !this.currentAuHasSps) {
      const prefix: Buffer[] = [];
      if (this.lastSps) prefix.push(this.lastSps);
      if (this.lastPps) prefix.push(this.lastPps);
      this.currentAuBuffers = [...prefix, ...this.currentAuBuffers];
    }

    const fullFrameBuffer = Buffer.concat(this.currentAuBuffers);
    const isKey = this.currentAuHasKey;
    const nowUs = BigInt(Math.floor(performance.now() * 1000));
    const timestampUs = nowUs - this.startTimeUs;

    this.frameCount++;
    this.emit('frame', {
      streamId: this.streamId,
      isKey,
      timestampUs,
      data: fullFrameBuffer
    } as StreamFrameEvent);

    // Reset state for the next Access Unit
    this.currentAuBuffers = [];
    this.hasVclInCurrentAu = false;
    this.currentAuHasKey = false;
    this.currentAuHasSps = false;
  }

  private findNextStartCode(buf: Buffer, fromIndex: number): { offset: number; length: number } | null {
    for (let i = fromIndex; i < buf.length - 2; i++) {
      if (buf[i] === 0 && buf[i + 1] === 0) {
        if (buf[i + 2] === 1) {
          if (i > 0 && buf[i - 1] === 0) {
            return { offset: i - 1, length: 4 };
          }
          return { offset: i, length: 3 };
        }
      }
    }
    return null;
  }
}

export class StreamPool {
  private demuxers: Map<number, RtspDemuxer> = new Map();
  private startTimers: NodeJS.Timeout[] = [];

  constructor(count: number) {
    for (let i = 0; i < count; i++) {
      const demuxer = new RtspDemuxer(i);
      this.demuxers.set(i, demuxer);
    }
  }

  public startAll(): void {
    console.log(`[StreamPool] Starting ${this.demuxers.size} RTSP demuxers (stagger ${STREAM_STAGGER_MS}ms)...`);
    let index = 0;
    for (const demuxer of this.demuxers.values()) {
      const delayMs = index * STREAM_STAGGER_MS;
      index += 1;
      if (delayMs === 0) {
        demuxer.start();
      } else {
        this.startTimers.push(setTimeout(() => demuxer.start(), delayMs));
      }
    }
  }

  public stopAll(): void {
    console.log(`[StreamPool] Stopping ${this.demuxers.size} RTSP demuxers...`);
    for (const timer of this.startTimers) {
      clearTimeout(timer);
    }
    this.startTimers = [];
    for (const demuxer of this.demuxers.values()) {
      demuxer.stop();
    }
    this.demuxers.clear();
  }

  public get(streamId: number): RtspDemuxer | undefined {
    return this.demuxers.get(streamId);
  }

  public getAll(): RtspDemuxer[] {
    return Array.from(this.demuxers.values());
  }
}
