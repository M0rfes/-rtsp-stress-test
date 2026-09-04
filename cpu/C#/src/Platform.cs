using System;
using System.Runtime.InteropServices;
using Avalonia;

namespace RtspStressTest;

public static class Platform
{
    public const int NofileTarget = 10240;
    public const int StreamStaggerMs = 20;

    public static string Name
    {
        get
        {
            if (OperatingSystem.IsMacOS()) return "macOS";
            if (OperatingSystem.IsLinux()) return "Linux";
            if (OperatingSystem.IsWindows()) return "Windows";
            return RuntimeInformation.OSDescription;
        }
    }

    public static void LogCpuPath()
    {
        if (OperatingSystem.IsMacOS())
        {
            Console.WriteLine("[Platform] macOS: software H.264 decode, Metal compositor");
        }
        else if (OperatingSystem.IsLinux())
        {
            Console.WriteLine("[Platform] Linux: software H.264 decode (no VA-API)");
        }
        else if (OperatingSystem.IsWindows())
        {
            Console.WriteLine("[Platform] Windows: software H.264 decode, ANGLE compositor");
        }
    }
}
