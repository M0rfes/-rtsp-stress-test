using System;
using System.Runtime.InteropServices;
using Avalonia.OpenGL;

namespace RtspStressTest;

internal unsafe sealed class GlExtras
{
    public const int GL_RED = 0x1903;
    public const int GL_RG = 0x8227;
    public const int GL_R8 = 0x8229;
    public const int GL_RG8 = 0x822B;
    public const int GL_UNPACK_ALIGNMENT = 0x0CF5;
    public const int GL_UNPACK_ROW_LENGTH = 0x0CF2;
    public const int GL_CLAMP_TO_EDGE = 0x812F;
    public const int GL_TEXTURE_WRAP_S = 0x2802;
    public const int GL_TEXTURE_WRAP_T = 0x2803;
    public const int GL_TEXTURE_2D = 0x0DE1;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void GlTexSubImage2D(int target, int level, int xoffset, int yoffset, int width, int height, int format, int type, IntPtr pixels);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void GlPixelStorei(int pname, int param);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void GlUniform1i(int location, int v0);

    private readonly GlTexSubImage2D? _texSubImage2D;
    private readonly GlPixelStorei? _pixelStorei;
    private readonly GlUniform1i? _uniform1i;

    public GlExtras(GlInterface gl)
    {
        _texSubImage2D = Load<GlTexSubImage2D>(gl, "glTexSubImage2D");
        _pixelStorei = Load<GlPixelStorei>(gl, "glPixelStorei");
        _uniform1i = Load<GlUniform1i>(gl, "glUniform1i");
    }

    public void TexSubImage2D(int target, int level, int xoffset, int yoffset, int width, int height, int format, int type, void* pixels)
    {
        _texSubImage2D?.Invoke(target, level, xoffset, yoffset, width, height, format, type, (IntPtr)pixels);
    }

    public void PixelStorei(int pname, int param)
    {
        _pixelStorei?.Invoke(pname, param);
    }

    public void Uniform1i(int location, int v0)
    {
        _uniform1i?.Invoke(location, v0);
    }

    private static T? Load<T>(GlInterface gl, string name) where T : Delegate
    {
        var ptr = gl.GetProcAddress(name);
        return ptr == IntPtr.Zero ? null : Marshal.GetDelegateForFunctionPointer<T>(ptr);
    }
}
