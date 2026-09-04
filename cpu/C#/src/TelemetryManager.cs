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

    private readonly FpsBuckets _windowBuckets = new();
    private readonly List<ulong> _prevPaintedFrames = new();
    private readonly List<ulong> _prevDecodedFrames = new();
    private int _secondsInWindow;

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

                var deltaP = (paintedCur >= prevP) ? (uint)(paintedCur - prevP) : (uint)paintedCur;
                var deltaD = (decodedCur >= prevD) ? (uint)(decodedCur - prevD) : (uint)decodedCur;

                _prevPaintedFrames[i] = paintedCur;
                _prevDecodedFrames[i] = decodedCur;

                worker.CurrentPaintedFps = deltaP;
                worker.CurrentDecodedFps = deltaD;

                // Use painted FPS; fallback to decoded FPS in headless Xvfb environments
                var delta = (paintedCur > 0 || deltaP > 0) ? deltaP : deltaD;
                worker.CurrentFps = delta;
                totalFps += delta;

                if (worker.IsConnected)
                {
                    live++;
                }

                // Categorize into performance buckets
                if (delta >= 25)
                {
                    _windowBuckets.Fps25To30++;
                }
                else if (delta >= 20)
                {
                    _windowBuckets.Fps20To24++;
                }
                else if (delta >= 10)
                {
                    _windowBuckets.Fps10To19++;
                }
                else if (delta >= 5)
                {
                    _windowBuckets.Fps5To9++;
                }
                else
                {
                    _windowBuckets.FpsUnder5++;
                }
            }

            AggregateFps = totalFps;
            LiveStreams = live;
            _secondsInWindow++;

            // Flush rolling 60-second window
            if (_secondsInWindow >= 60)
            {
                FlushWindow();
                _windowBuckets.Reset();
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
                Fps25To30 = _windowBuckets.Fps25To30,
                Fps20To24 = _windowBuckets.Fps20To24,
                Fps10To19 = _windowBuckets.Fps10To19,
                Fps5To9 = _windowBuckets.Fps5To9,
                FpsUnder5 = _windowBuckets.FpsUnder5
            };
        }
    }

    private void FlushWindow()
    {
        var timestamp = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'");

        var payload = new TelemetryPayload
        {
            Timestamp = timestamp,
            MachineId = _machineId,
            Framework = "csharp_avalonia",
            HardwareMode = "cpu",
            WindowDurationSeconds = 60,
            ActiveStreams = _activeStreams,
            FpsStreamSeconds = new FpsStreamSecondsWrapper
            {
                Acceptable = new AcceptableBuckets
                {
                    Fps25To30 = _windowBuckets.Fps25To30,
                    Fps20To24 = _windowBuckets.Fps20To24
                },
                Unacceptable = new UnacceptableBuckets
                {
                    Fps10To19 = _windowBuckets.Fps10To19,
                    Fps5To9 = _windowBuckets.Fps5To9,
                    FpsUnder5 = _windowBuckets.FpsUnder5
                }
            }
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

            Console.WriteLine($"[Telemetry] Flushed 60s window ({_windowBuckets.TotalStreamSeconds} stream-seconds) to {_logPath}");
            Console.WriteLine($"            Acceptable (25-30: {_windowBuckets.Fps25To30}, 20-24: {_windowBuckets.Fps20To24}) | Unacceptable (10-19: {_windowBuckets.Fps10To19}, 5-9: {_windowBuckets.Fps5To9}, <5: {_windowBuckets.FpsUnder5})");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[Telemetry] Error writing to log file '{_logPath}': {ex.Message}");
        }
    }
}
