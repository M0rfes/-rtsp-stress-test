using System;
using System.Runtime.InteropServices;

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

    public static void LogGpuPath()
    {
        if (OperatingSystem.IsMacOS())
        {
            Console.WriteLine("[Platform] macOS: VideoToolbox + IOSurface / OpenGL (no VA-API/EGL)");
        }
        else if (OperatingSystem.IsLinux())
        {
            Console.WriteLine("[Platform] Linux: CUDA / VA-API hardware decode");
        }
        else if (OperatingSystem.IsWindows())
        {
            Console.WriteLine("[Platform] Windows: D3D11VA / CUDA hardware decode");
        }
    }
}
