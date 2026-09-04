using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RtspStressTest;

public sealed class FpsBuckets
{
    public long Fps25To30 { get; set; }
    public long Fps20To24 { get; set; }
    public long Fps10To19 { get; set; }
    public long Fps5To9 { get; set; }
    public long FpsUnder5 { get; set; }

    public long TotalAcceptable => Fps25To30 + Fps20To24;
    public long TotalUnacceptable => Fps10To19 + Fps5To9 + FpsUnder5;
    public long TotalStreamSeconds => TotalAcceptable + TotalUnacceptable;

    public void Reset()
    {
        Fps25To30 = 0;
        Fps20To24 = 0;
        Fps10To19 = 0;
        Fps5To9 = 0;
        FpsUnder5 = 0;
    }

    public void AddSample(uint fps)
    {
        if (fps >= 25)
        {
            Fps25To30++;
        }
        else if (fps >= 20)
        {
            Fps20To24++;
        }
        else if (fps >= 10)
        {
            Fps10To19++;
        }
        else if (fps >= 5)
        {
            Fps5To9++;
        }
        else
        {
            FpsUnder5++;
        }
    }

    public FpsStreamSecondsWrapper ToWrapper() => new()
    {
        Acceptable = new AcceptableBuckets
        {
            Fps25To30 = Fps25To30,
            Fps20To24 = Fps20To24
        },
        Unacceptable = new UnacceptableBuckets
        {
            Fps10To19 = Fps10To19,
            Fps5To9 = Fps5To9,
            FpsUnder5 = FpsUnder5
        }
    };
}

public sealed class TelemetryPayload
{
    [JsonPropertyName("timestamp")]
    public string Timestamp { get; set; } = string.Empty;

    [JsonPropertyName("machine_id")]
    public string MachineId { get; set; } = string.Empty;

    [JsonPropertyName("framework")]
    public string Framework { get; set; } = "csharp_avalonia";

    [JsonPropertyName("hardware_mode")]
    public string HardwareMode { get; set; } = "cpu";

    [JsonPropertyName("window_duration_seconds")]
    public int WindowDurationSeconds { get; set; } = 60;

    [JsonPropertyName("active_streams")]
    public int ActiveStreams { get; set; } = 30;

    [JsonPropertyName("fps_stream_seconds")]
    public FpsStreamSecondsWrapper FpsStreamSeconds { get; set; } = new();

    [JsonPropertyName("decode_fps_stream_seconds")]
    public FpsStreamSecondsWrapper DecodeFpsStreamSeconds { get; set; } = new();

    [JsonPropertyName("avg_painted_fps")]
    public double AvgPaintedFps { get; set; }

    [JsonPropertyName("avg_decoded_fps")]
    public double AvgDecodedFps { get; set; }
}

public sealed class FpsStreamSecondsWrapper
{
    [JsonPropertyName("acceptable")]
    public AcceptableBuckets Acceptable { get; set; } = new();

    [JsonPropertyName("unacceptable")]
    public UnacceptableBuckets Unacceptable { get; set; } = new();
}

public sealed class AcceptableBuckets
{
    [JsonPropertyName("25_to_30_fps")]
    public long Fps25To30 { get; set; }

    [JsonPropertyName("20_to_24_fps")]
    public long Fps20To24 { get; set; }
}

public sealed class UnacceptableBuckets
{
    [JsonPropertyName("10_to_19_fps")]
    public long Fps10To19 { get; set; }

    [JsonPropertyName("5_to_9_fps")]
    public long Fps5To9 { get; set; }

    [JsonPropertyName("under_5_fps")]
    public long FpsUnder5 { get; set; }
}

public sealed class TelemetryManager
{
    private readonly string _logPath;
    private readonly string _machineId;
    private readonly int _activeStreams;
    private readonly object _lock = new();

    private readonly FpsBuckets _paintedBuckets = new();
    private readonly FpsBuckets _decodedBuckets = new();
    private readonly List<ulong> _prevPaintedFrames = new();
    private readonly List<ulong> _prevDecodedFrames = new();
    private int _secondsInWindow;
    private long _accumulatedActiveStreams;
    private int _activeStreamsSampleCount;
    private long _accumulatedPaintedFrames;
    private long _accumulatedDecodedFrames;

    public float AggregateFps { get; private set; }
    public int LiveStreams { get; private set; }
    public int SecondsInWindow => _secondsInWindow;

    public TelemetryManager(string logPath, string machineId, int activeStreams)
    {
        _logPath = logPath;
        _machineId = machineId;
        _activeStreams = activeStreams;
    }

    public void Tick(IReadOnlyList<StreamWorker> workers)
    {
        lock (_lock)
        {
            var count = workers.Count;
            while (_prevPaintedFrames.Count < count)
            {
                _prevPaintedFrames.Add(0);
                _prevDecodedFrames.Add(0);
            }

            float totalFps = 0f;
            var live = 0;

            for (var i = 0; i < count; i++)
            {
                var worker = workers[i];
                var paintedCur = worker.PaintedFrames;
                var decodedCur = worker.DecodedFrames;

                var prevP = _prevPaintedFrames[i];
                var prevD = _prevDecodedFrames[i];

                if (!worker.IsConnected)
                {
                    // Phase 2 Rule: Do NOT count frames or log bucket seconds for dropped / inactive streams
                    _prevPaintedFrames[i] = paintedCur;
                    _prevDecodedFrames[i] = decodedCur;
                    worker.CurrentPaintedFps = 0;
                    worker.CurrentDecodedFps = 0;
                    worker.CurrentFps = 0;
                    continue;
                }

                live++;
                var deltaP = (paintedCur >= prevP) ? (uint)(paintedCur - prevP) : (uint)paintedCur;
                var deltaD = (decodedCur >= prevD) ? (uint)(decodedCur - prevD) : (uint)decodedCur;

                _prevPaintedFrames[i] = paintedCur;
                _prevDecodedFrames[i] = decodedCur;

                worker.CurrentPaintedFps = deltaP;
                worker.CurrentDecodedFps = deltaD;

                // Spec score: unique presented frames. Decode is pipeline throughput.
                worker.CurrentFps = deltaP;
                totalFps += deltaP;

                _paintedBuckets.AddSample(deltaP);
                _decodedBuckets.AddSample(deltaD);
                _accumulatedPaintedFrames += deltaP;
                _accumulatedDecodedFrames += deltaD;
            }

            AggregateFps = totalFps;
            LiveStreams = live;
            _accumulatedActiveStreams += live;
            _activeStreamsSampleCount++;
            _secondsInWindow++;

            // Flush rolling 60-second window
            if (_secondsInWindow >= 60)
            {
                FlushWindow();
                _paintedBuckets.Reset();
                _decodedBuckets.Reset();
                _accumulatedActiveStreams = 0;
                _activeStreamsSampleCount = 0;
                _accumulatedPaintedFrames = 0;
                _accumulatedDecodedFrames = 0;
                _secondsInWindow = 0;
            }
        }
    }

    public FpsBuckets GetCurrentBucketsSnapshot()
    {
        lock (_lock)
        {
            return new FpsBuckets
            {
                Fps25To30 = _paintedBuckets.Fps25To30,
                Fps20To24 = _paintedBuckets.Fps20To24,
                Fps10To19 = _paintedBuckets.Fps10To19,
                Fps5To9 = _paintedBuckets.Fps5To9,
                FpsUnder5 = _paintedBuckets.FpsUnder5
            };
        }
    }

    private void FlushWindow()
    {
        var timestamp = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'");
        var avgActiveStreams = _activeStreamsSampleCount > 0 
            ? (int)Math.Round((double)_accumulatedActiveStreams / _activeStreamsSampleCount) 
            : LiveStreams;

        var streamSeconds = _paintedBuckets.TotalStreamSeconds;
        var avgPainted = streamSeconds > 0 ? (double)_accumulatedPaintedFrames / streamSeconds : 0;
        var avgDecoded = streamSeconds > 0 ? (double)_accumulatedDecodedFrames / streamSeconds : 0;

        var payload = new TelemetryPayload
        {
            Timestamp = timestamp,
            MachineId = _machineId,
            Framework = "csharp_avalonia",
            HardwareMode = "cpu",
            WindowDurationSeconds = 60,
            ActiveStreams = avgActiveStreams,
            FpsStreamSeconds = _paintedBuckets.ToWrapper(),
            DecodeFpsStreamSeconds = _decodedBuckets.ToWrapper(),
            AvgPaintedFps = Math.Round(avgPainted, 2),
            AvgDecodedFps = Math.Round(avgDecoded, 2)
        };

        var options = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        var json = JsonSerializer.Serialize(payload, options);

        try
        {
            var dir = Path.GetDirectoryName(_logPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            File.AppendAllText(_logPath, json + Environment.NewLine);

            Console.WriteLine($"[Telemetry] Flushed 60s window ({streamSeconds} stream-seconds) to {_logPath}");
            Console.WriteLine($"            Painted  avg={avgPainted:0.0}  Acceptable (25-30: {_paintedBuckets.Fps25To30}, 20-24: {_paintedBuckets.Fps20To24}) | Unacc (<5: {_paintedBuckets.FpsUnder5})");
            Console.WriteLine($"            Decoded  avg={avgDecoded:0.0}  Acceptable (25-30: {_decodedBuckets.Fps25To30}, 20-24: {_decodedBuckets.Fps20To24}) | Unacc (<5: {_decodedBuckets.FpsUnder5})");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Telemetry] Error writing to log file '{_logPath}': {ex.Message}");
        }
    }
}
