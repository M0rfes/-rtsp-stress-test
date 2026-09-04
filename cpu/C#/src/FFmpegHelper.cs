using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using FFmpeg.AutoGen.Abstractions;
using FFmpeg.AutoGen.Bindings.DynamicallyLoaded;

namespace RtspStressTest;

public static class FFmpegHelper
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RLimit
    {
        public ulong rlim_cur;
        public ulong rlim_max;
    }

    [DllImport("libc", SetLastError = true)]
    private static extern int getrlimit(int resource, ref RLimit rlim);

    [DllImport("libc", SetLastError = true)]
    private static extern int setrlimit(int resource, ref RLimit rlim);

    public static void RaiseFileDescriptorLimit(ulong targetLimit = 10240)
    {
        try
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX) || RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            {
                // RLIMIT_NOFILE is 8 on macOS / Darwin, 7 on Linux
                var resource = RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? 8 : 7;
                var rl = new RLimit();
                if (getrlimit(resource, ref rl) == 0)
                {
                    var oldCur = rl.rlim_cur;
                    var max = rl.rlim_max;
                    rl.rlim_cur = Math.Min(targetLimit, max);
                    if (setrlimit(resource, ref rl) == 0)
                    {
                        Console.WriteLine($"[System] Raised RLIMIT_NOFILE from {oldCur} to {rl.rlim_cur} (max: {max})");
                    }
                    else
                    {
                        // Try with target limit as both cur and max if permitted
                        rl.rlim_cur = targetLimit;
                        rl.rlim_max = targetLimit;
                        if (setrlimit(resource, ref rl) == 0)
                        {
                            Console.WriteLine($"[System] Raised RLIMIT_NOFILE to {targetLimit}");
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[System] Notice: Unable to adjust RLIMIT_NOFILE: {ex.Message}");
        }
    }

    public static void Initialize(string? explicitPath = null)
    {
        var libDir = ResolveLibrariesPath(explicitPath);
        if (string.IsNullOrEmpty(libDir))
        {
            throw new FileNotFoundException("Unable to locate FFmpeg native libraries (libavcodec, libavformat). " +
                                           "Please install FFmpeg or set the FFMPEG_PATH environment variable.");
        }

        Console.WriteLine($"[FFmpeg] Loading native libraries from: {libDir}");
        DynamicallyLoadedBindings.LibrariesPath = libDir;
        DynamicallyLoadedBindings.ThrowErrorIfFunctionNotFound = false;

        // Auto-detect library versions in folder if different from defaults
        DetectAndConfigureLibraryVersions(libDir);

        try
        {
            DynamicallyLoadedBindings.Initialize();
            var version = ffmpeg.av_version_info();
            Console.WriteLine($"[FFmpeg] Successfully initialized FFmpeg native bindings: {version}");
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"Failed to initialize FFmpeg native bindings from '{libDir}': {ex.Message}", ex);
        }
    }

    private static string? ResolveLibrariesPath(string? explicitPath)
    {
        if (!string.IsNullOrEmpty(explicitPath) && Directory.Exists(explicitPath))
        {
            return explicitPath;
        }

        var candidates = new List<string>();

        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            candidates.Add("/opt/homebrew/opt/ffmpeg/lib");
            candidates.Add("/usr/local/opt/ffmpeg/lib");
            candidates.Add("/opt/homebrew/lib");
            candidates.Add("/usr/local/lib");
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        {
            candidates.Add("/usr/lib/x86_64-linux-gnu");
            candidates.Add("/usr/lib/aarch64-linux-gnu");
            candidates.Add("/usr/lib64");
            candidates.Add("/usr/lib");
            candidates.Add("/usr/local/lib");
        }
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            candidates.Add(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ffmpeg", "bin"));
            candidates.Add(AppDomain.CurrentDomain.BaseDirectory);
            candidates.Add(@"C:\ffmpeg\bin");
        }

        foreach (var dir in candidates)
        {
            if (Directory.Exists(dir))
            {
                // Check if directory contains libavcodec
                var files = Directory.GetFiles(dir, "*avcodec*");
                if (files.Length > 0)
                {
                    return dir;
                }
            }
        }

        return null;
    }

    private static void DetectAndConfigureLibraryVersions(string libDir)
    {
        try
        {
            var field = typeof(DynamicallyLoadedBindings).GetField("LibraryVersionMap",
                BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
            if (field?.GetValue(null) is not Dictionary<string, int> map)
            {
                return;
            }

            var files = Directory.GetFiles(libDir);

            // Patterns for versions, e.g. libavcodec.60.dylib or libavcodec.so.60
            foreach (var libName in new[] { "avcodec", "avformat", "avutil", "swscale" })
            {
                var pattern = new Regex($@"lib{libName}[._]so[._](\d+)|lib{libName}[._](\d+)\.(dylib|so)", RegexOptions.IgnoreCase);
                foreach (var file in files)
                {
                    var match = pattern.Match(Path.GetFileName(file));
                    if (match.Success)
                    {
                        var verStr = !string.IsNullOrEmpty(match.Groups[1].Value) ? match.Groups[1].Value : match.Groups[2].Value;
                        if (int.TryParse(verStr, out var ver))
                        {
                            map[libName] = ver;
                            Console.WriteLine($"[FFmpeg] Detected {libName} version: {ver}");
                            break;
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[FFmpeg] Version detection notice: {ex.Message}");
        }
    }
}
