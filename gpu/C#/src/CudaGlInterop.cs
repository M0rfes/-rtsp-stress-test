using System;
using System.Runtime.InteropServices;

namespace RtspStressTest;

internal static class CudaGlInterop
{
    public const int Success = 0;
    public const int MemoryTypeDevice = 0x02;
    public const int MemoryTypeArray = 0x03;
    public const uint RegisterFlagsNone = 0;
    public const uint Texture2D = 0x0DE1;

    public static bool Available { get; }

    static CudaGlInterop()
    {
        try
        {
            Available = cuInit(0) == Success;
        }
        catch (DllNotFoundException)
        {
            Available = false;
        }
        catch (EntryPointNotFoundException)
        {
            Available = false;
        }
    }

    [DllImport("libcuda.so.1", EntryPoint = "cuInit")]
    private static extern int cuInitLinux(uint flags);

    [DllImport("nvcuda", EntryPoint = "cuInit")]
    private static extern int cuInitWindows(uint flags);

    public static int cuInit(uint flags)
        => OperatingSystem.IsWindows() ? cuInitWindows(flags) : cuInitLinux(flags);

    [DllImport("libcuda.so.1", EntryPoint = "cuCtxPushCurrent_v2")]
    private static extern int cuCtxPushCurrentLinux(IntPtr ctx);

    [DllImport("nvcuda", EntryPoint = "cuCtxPushCurrent_v2")]
    private static extern int cuCtxPushCurrentWindows(IntPtr ctx);

    public static int cuCtxPushCurrent(IntPtr ctx)
        => OperatingSystem.IsWindows() ? cuCtxPushCurrentWindows(ctx) : cuCtxPushCurrentLinux(ctx);

    [DllImport("libcuda.so.1", EntryPoint = "cuCtxPopCurrent_v2")]
    private static extern int cuCtxPopCurrentLinux(out IntPtr ctx);

    [DllImport("nvcuda", EntryPoint = "cuCtxPopCurrent_v2")]
    private static extern int cuCtxPopCurrentWindows(out IntPtr ctx);

    public static int cuCtxPopCurrent(out IntPtr ctx)
        => OperatingSystem.IsWindows() ? cuCtxPopCurrentWindows(out ctx) : cuCtxPopCurrentLinux(out ctx);

    [DllImport("libcuda.so.1", EntryPoint = "cuGraphicsGLRegisterImage")]
    private static extern int RegisterImageLinux(out IntPtr resource, uint image, uint target, uint flags);

    [DllImport("nvcuda", EntryPoint = "cuGraphicsGLRegisterImage")]
    private static extern int RegisterImageWindows(out IntPtr resource, uint image, uint target, uint flags);

    public static int cuGraphicsGLRegisterImage(out IntPtr resource, uint image, uint target, uint flags)
        => OperatingSystem.IsWindows()
            ? RegisterImageWindows(out resource, image, target, flags)
            : RegisterImageLinux(out resource, image, target, flags);

    [DllImport("libcuda.so.1", EntryPoint = "cuGraphicsUnregisterResource")]
    private static extern int UnregisterLinux(IntPtr resource);

    [DllImport("nvcuda", EntryPoint = "cuGraphicsUnregisterResource")]
    private static extern int UnregisterWindows(IntPtr resource);

    public static int cuGraphicsUnregisterResource(IntPtr resource)
        => OperatingSystem.IsWindows() ? UnregisterWindows(resource) : UnregisterLinux(resource);

    [DllImport("libcuda.so.1", EntryPoint = "cuGraphicsMapResources")]
    private static extern int MapLinux(int count, ref IntPtr resources, IntPtr stream);

    [DllImport("nvcuda", EntryPoint = "cuGraphicsMapResources")]
    private static extern int MapWindows(int count, ref IntPtr resources, IntPtr stream);

    public static int cuGraphicsMapResources(int count, ref IntPtr resources, IntPtr stream)
        => OperatingSystem.IsWindows()
            ? MapWindows(count, ref resources, stream)
            : MapLinux(count, ref resources, stream);

    [DllImport("libcuda.so.1", EntryPoint = "cuGraphicsUnmapResources")]
    private static extern int UnmapLinux(int count, ref IntPtr resources, IntPtr stream);

    [DllImport("nvcuda", EntryPoint = "cuGraphicsUnmapResources")]
    private static extern int UnmapWindows(int count, ref IntPtr resources, IntPtr stream);

    public static int cuGraphicsUnmapResources(int count, ref IntPtr resources, IntPtr stream)
        => OperatingSystem.IsWindows()
            ? UnmapWindows(count, ref resources, stream)
            : UnmapLinux(count, ref resources, stream);

    [DllImport("libcuda.so.1", EntryPoint = "cuGraphicsSubResourceGetMappedArray")]
    private static extern int MappedArrayLinux(out IntPtr array, IntPtr resource, uint arrayIndex, uint mipLevel);

    [DllImport("nvcuda", EntryPoint = "cuGraphicsSubResourceGetMappedArray")]
    private static extern int MappedArrayWindows(out IntPtr array, IntPtr resource, uint arrayIndex, uint mipLevel);

    public static int cuGraphicsSubResourceGetMappedArray(out IntPtr array, IntPtr resource, uint arrayIndex, uint mipLevel)
        => OperatingSystem.IsWindows()
            ? MappedArrayWindows(out array, resource, arrayIndex, mipLevel)
            : MappedArrayLinux(out array, resource, arrayIndex, mipLevel);

    [DllImport("libcuda.so.1", EntryPoint = "cuMemcpy2D_v2")]
    private static extern int Memcpy2DLinux(ref CUDA_MEMCPY2D copy);

    [DllImport("nvcuda", EntryPoint = "cuMemcpy2D_v2")]
    private static extern int Memcpy2DWindows(ref CUDA_MEMCPY2D copy);

    public static int cuMemcpy2D(ref CUDA_MEMCPY2D copy)
        => OperatingSystem.IsWindows() ? Memcpy2DWindows(ref copy) : Memcpy2DLinux(ref copy);

    [StructLayout(LayoutKind.Sequential)]
    public struct CUDA_MEMCPY2D
    {
        public nuint srcXInBytes;
        public nuint srcY;
        public int srcMemoryType;
        public int pad0;
        public IntPtr srcHost;
        public ulong srcDevice;
        public IntPtr srcArray;
        public nuint srcPitch;
        public nuint dstXInBytes;
        public nuint dstY;
        public int dstMemoryType;
        public int pad1;
        public IntPtr dstHost;
        public ulong dstDevice;
        public IntPtr dstArray;
        public nuint dstPitch;
        public nuint WidthInBytes;
        public nuint Height;
    }
}
