using System;
using System.IO;

namespace RtspStressTest;

public sealed class AppConfig
{
    public string RtspUrl { get; set; } = "rtsp://127.0.0.1:8554/live";
    public int StreamCount { get; set; } = 30;
    public string LogPath { get; set; } = "/var/log/benchmark/fps_metrics.log";
    public string MachineId { get; set; } = Environment.MachineName;
    public string? FFmpegPath { get; set; }
    public string HwAccel { get; set; } = "auto";
    public int RenderFps { get; set; } = 30;

    public static AppConfig Load(string[] args)
    {
        var config = new AppConfig();

        var envUrl = Environment.GetEnvironmentVariable("RTSP_URL");
        if (!string.IsNullOrWhiteSpace(envUrl))
        {
            config.RtspUrl = envUrl;
        }

        var envCount = Environment.GetEnvironmentVariable("STREAM_COUNT");
        if (!string.IsNullOrWhiteSpace(envCount) && int.TryParse(envCount, out var parsedCount) && parsedCount > 0)
        {
            config.StreamCount = parsedCount;
        }

        var envLogPath = Environment.GetEnvironmentVariable("FPS_METRICS_LOG_PATH");
        if (!string.IsNullOrWhiteSpace(envLogPath))
        {
            config.LogPath = envLogPath;
        }
        else
        {
            var envLogDir = Environment.GetEnvironmentVariable("BENCHMARK_LOG_DIR");
            if (!string.IsNullOrWhiteSpace(envLogDir))
            {
                config.LogPath = Path.Combine(envLogDir, "fps_metrics.log");
            }
        }

        var envMachineId = Environment.GetEnvironmentVariable("MACHINE_ID");
        if (!string.IsNullOrWhiteSpace(envMachineId))
        {
            config.MachineId = envMachineId;
        }

        var envFfmpegPath = Environment.GetEnvironmentVariable("FFMPEG_PATH") ??
                            Environment.GetEnvironmentVariable("FFMPEG_LIBRARIES_PATH");
        if (!string.IsNullOrWhiteSpace(envFfmpegPath))
        {
            config.FFmpegPath = envFfmpegPath;
        }

        var envHw = Environment.GetEnvironmentVariable("HW_ACCEL");
        if (!string.IsNullOrWhiteSpace(envHw))
        {
            config.HwAccel = envHw;
        }

        var envRenderFps = Environment.GetEnvironmentVariable("RENDER_FPS");
        if (!string.IsNullOrWhiteSpace(envRenderFps) && int.TryParse(envRenderFps, out var rfps) && rfps > 0)
        {
            config.RenderFps = rfps;
        }

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if ((arg == "--url" || arg == "-u") && i + 1 < args.Length)
            {
                config.RtspUrl = args[++i];
            }
            else if ((arg == "--streams" || arg == "-s") && i + 1 < args.Length)
            {
                if (int.TryParse(args[++i], out var count) && count > 0)
                {
                    config.StreamCount = count;
                }
            }
            else if ((arg == "--log-path" || arg == "-l") && i + 1 < args.Length)
            {
                config.LogPath = args[++i];
            }
            else if (arg == "--log-dir" && i + 1 < args.Length)
            {
                config.LogPath = Path.Combine(args[++i], "fps_metrics.log");
            }
            else if ((arg == "--machine-id" || arg == "-m") && i + 1 < args.Length)
            {
                config.MachineId = args[++i];
            }
            else if (arg == "--ffmpeg-path" && i + 1 < args.Length)
            {
                config.FFmpegPath = args[++i];
            }
            else if (arg == "--hw-accel" && i + 1 < args.Length)
            {
                config.HwAccel = args[++i];
            }
            else if (arg == "--render-fps" && i + 1 < args.Length)
            {
                if (int.TryParse(args[++i], out var renderFps) && renderFps > 0)
                {
                    config.RenderFps = renderFps;
                }
            }
            else if (arg == "--help" || arg == "-h")
            {
                PrintHelp();
                Environment.Exit(0);
            }
        }

        config.LogPath = ResolveLogPath(config.LogPath);
        return config;
    }

    private static string ResolveLogPath(string preferredPath)
    {
        try
        {
            var dir = Path.GetDirectoryName(preferredPath);
            if (string.IsNullOrEmpty(dir))
            {
                dir = ".";
            }

            Directory.CreateDirectory(dir);
            var testFile = Path.Combine(dir, ".test_write_perm_" + Guid.NewGuid().ToString("N"));
            File.WriteAllText(testFile, "test");
            File.Delete(testFile);
            return preferredPath;
        }
        catch (Exception ex)
        {
            var fallbackDir = Path.Combine(Directory.GetCurrentDirectory(), "logs");
            Directory.CreateDirectory(fallbackDir);
            var fallbackPath = Path.Combine(fallbackDir, Path.GetFileName(preferredPath));
            Console.WriteLine($"[Config] Warning: Cannot write to '{preferredPath}' ({ex.Message}). Falling back to '{fallbackPath}'");
            return fallbackPath;
        }
    }

    private static void PrintHelp()
    {
        Console.WriteLine("30-Camera RTSP Video Grid Benchmark (C# Avalonia GPU Zero-Copy)");
        Console.WriteLine("Usage: rtsp-stress-test-csharp-gpu [options]");
        Console.WriteLine();
        Console.WriteLine("Options:");
        Console.WriteLine("  --url, -u <url>         RTSP stream URL (default: rtsp://127.0.0.1:8554/live)");
        Console.WriteLine("  --streams, -s <count>   Number of streams in grid (default: 30)");
        Console.WriteLine("  --hw-accel <type>       cuda | vaapi | videotoolbox | d3d11va | auto (default: auto)");
        Console.WriteLine("  --log-path, -l <path>   Telemetry log file path (default: /var/log/benchmark/fps_metrics.log)");
        Console.WriteLine("  --log-dir <dir>         Telemetry log directory");
        Console.WriteLine("  --machine-id, -m <id>   Machine/node identifier (default: hostname)");
        Console.WriteLine("  --ffmpeg-path <path>    Explicit path to FFmpeg native libraries");
        Console.WriteLine("  --render-fps <fps>      UI refresh rate (default: 30)");
        Console.WriteLine("  --help, -h              Show this help message");
    }
}
