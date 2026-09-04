using System;
using System.Runtime.InteropServices;

namespace RtspStressTest;

internal static class CoreVideoInterop
{
    public const int LockReadOnly = 1;

    [DllImport("/System/Library/Frameworks/CoreVideo.framework/CoreVideo")]
    public static extern int CVPixelBufferLockBaseAddress(IntPtr pixelBuffer, nint lockFlags);

    [DllImport("/System/Library/Frameworks/CoreVideo.framework/CoreVideo")]
    public static extern int CVPixelBufferUnlockBaseAddress(IntPtr pixelBuffer, nint lockFlags);

    [DllImport("/System/Library/Frameworks/CoreVideo.framework/CoreVideo")]
    public static extern IntPtr CVPixelBufferGetBaseAddressOfPlane(IntPtr pixelBuffer, nint planeIndex);

    [DllImport("/System/Library/Frameworks/CoreVideo.framework/CoreVideo")]
    public static extern nint CVPixelBufferGetBytesPerRowOfPlane(IntPtr pixelBuffer, nint planeIndex);

    [DllImport("/System/Library/Frameworks/CoreVideo.framework/CoreVideo")]
    public static extern nint CVPixelBufferGetPlaneCount(IntPtr pixelBuffer);
}
