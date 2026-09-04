using Avalonia.OpenGL;

namespace RtspStressTest;

internal static class VideoShaders
{
    public static string Vertex(bool core)
    {
        return core
            ? """
              #version 330 core
              layout(location = 0) in vec2 aPosition;
              layout(location = 1) in vec2 aTexCoord;
              out vec2 vTexCoord;
              void main() {
                  gl_Position = vec4(aPosition, 0.0, 1.0);
                  vTexCoord = aTexCoord;
              }
              """
            : """
              attribute vec2 aPosition;
              attribute vec2 aTexCoord;
              varying vec2 vTexCoord;
              void main() {
                  gl_Position = vec4(aPosition, 0.0, 1.0);
                  vTexCoord = aTexCoord;
              }
              """;
    }

    public static string Nv12(bool core)
    {
        return core
            ? """
              #version 330 core
              in vec2 vTexCoord;
              uniform sampler2D texY;
              uniform sampler2D texUV;
              out vec4 fragColor;
              void main() {
                  float y = texture(texY, vTexCoord).r;
                  vec2 uv = texture(texUV, vTexCoord).rg;
                  float u = uv.r - 0.5;
                  float v = uv.g - 0.5;
                  float r = y + 1.5748 * v;
                  float g = y - 0.1873 * u - 0.4681 * v;
                  float b = y + 1.8556 * u;
                  fragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
              }
              """
            : """
              #ifdef GL_ES
              precision mediump float;
              #endif
              varying vec2 vTexCoord;
              uniform sampler2D texY;
              uniform sampler2D texUV;
              void main() {
                  float y = texture2D(texY, vTexCoord).r;
                  vec2 uv = texture2D(texUV, vTexCoord).rg;
                  float u = uv.r - 0.5;
                  float v = uv.g - 0.5;
                  float r = y + 1.5748 * v;
                  float g = y - 0.1873 * u - 0.4681 * v;
                  float b = y + 1.8556 * u;
                  gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
              }
              """;
    }

    public static string Yuv420p(bool core)
    {
        return core
            ? """
              #version 330 core
              in vec2 vTexCoord;
              uniform sampler2D texY;
              uniform sampler2D texU;
              uniform sampler2D texV;
              out vec4 fragColor;
              void main() {
                  float y = texture(texY, vTexCoord).r;
                  float u = texture(texU, vTexCoord).r - 0.5;
                  float v = texture(texV, vTexCoord).r - 0.5;
                  float r = y + 1.5748 * v;
                  float g = y - 0.1873 * u - 0.4681 * v;
                  float b = y + 1.8556 * u;
                  fragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
              }
              """
            : """
              #ifdef GL_ES
              precision mediump float;
              #endif
              varying vec2 vTexCoord;
              uniform sampler2D texY;
              uniform sampler2D texU;
              uniform sampler2D texV;
              void main() {
                  float y = texture2D(texY, vTexCoord).r;
                  float u = texture2D(texU, vTexCoord).r - 0.5;
                  float v = texture2D(texV, vTexCoord).r - 0.5;
                  float r = y + 1.5748 * v;
                  float g = y - 0.1873 * u - 0.4681 * v;
                  float b = y + 1.8556 * u;
                  gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
              }
              """;
    }

    public static int CompileProgram(GlInterface gl, string vsSource, string fsSource)
    {
        var vs = gl.CreateShader(GlConsts.GL_VERTEX_SHADER);
        var vsErr = gl.CompileShaderAndGetError(vs, vsSource);
        if (vsErr != null)
        {
            System.Console.Error.WriteLine($"[GLShader] Vertex shader compilation failed:\n{vsErr}");
        }

        var fs = gl.CreateShader(GlConsts.GL_FRAGMENT_SHADER);
        var fsErr = gl.CompileShaderAndGetError(fs, fsSource);
        if (fsErr != null)
        {
            System.Console.Error.WriteLine($"[GLShader] Fragment shader compilation failed:\n{fsErr}");
        }

        var program = gl.CreateProgram();
        gl.AttachShader(program, vs);
        gl.AttachShader(program, fs);
        gl.BindAttribLocationString(program, 0, "aPosition");
        gl.BindAttribLocationString(program, 1, "aTexCoord");
        var linkErr = gl.LinkProgramAndGetError(program);
        if (linkErr != null)
        {
            System.Console.Error.WriteLine($"[GLShader] Program link failed:\n{linkErr}");
        }

        gl.DeleteShader(vs);
        gl.DeleteShader(fs);
        return program;
    }
}
