using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Markup.Xaml;
using Avalonia.Media;

namespace RtspStressTest;

public partial class VideoTileControl : UserControl
{
    private StreamWorker? _worker;
    private VideoGlControl? _videoSurface;
    private TextBlock? _connectingText;
    private TextBlock? _cameraIdText;
    private Ellipse? _statusDot;
    private TextBlock? _resolutionText;
    private TextBlock? _hwText;
    private TextBlock? _fpsText;
    private Border? _fpsBadge;

    private static readonly IBrush GreenBrush = new SolidColorBrush(Color.Parse("#2ecc71"));
    private static readonly IBrush AmberBrush = new SolidColorBrush(Color.Parse("#f39c12"));
    private static readonly IBrush RedBrush = new SolidColorBrush(Color.Parse("#e74c3c"));
    private static readonly IBrush GreenBadgeBg = new SolidColorBrush(Color.Parse("#223822"));
    private static readonly IBrush AmberBadgeBg = new SolidColorBrush(Color.Parse("#383218"));
    private static readonly IBrush RedBadgeBg = new SolidColorBrush(Color.Parse("#381e1e"));

    public VideoTileControl()
    {
        InitializeComponent();
    }

    private void InitializeComponent()
    {
        AvaloniaXamlLoader.Load(this);
        _videoSurface = this.FindControl<VideoGlControl>("VideoSurface");
        _connectingText = this.FindControl<TextBlock>("ConnectingText");
        _cameraIdText = this.FindControl<TextBlock>("CameraIdText");
        _statusDot = this.FindControl<Ellipse>("StatusDot");
        _resolutionText = this.FindControl<TextBlock>("ResolutionText");
        _hwText = this.FindControl<TextBlock>("HwText");
        _fpsText = this.FindControl<TextBlock>("FpsText");
        _fpsBadge = this.FindControl<Border>("FpsBadge");
    }

    public void BindWorker(StreamWorker worker)
    {
        _worker = worker;
        if (_cameraIdText != null)
        {
            _cameraIdText.Text = $"CAM {worker.StreamId:D2}";
        }

        _videoSurface?.AttachWorker(worker);
    }

    public void RequestRenderIfDirty()
    {
        _videoSurface?.RequestRenderIfDirty();
    }

    public void UpdateHud()
    {
        if (_worker == null) return;

        var isConnected = _worker.IsConnected;
        var pFps = _worker.CurrentPaintedFps;
        var dFps = _worker.CurrentDecodedFps;
        var fps = _worker.CurrentFps;

        if (_statusDot != null)
        {
            _statusDot.Fill = isConnected ? GreenBrush : RedBrush;
        }

        if (_resolutionText != null)
        {
            _resolutionText.Text = isConnected && _worker.Width > 0 && _worker.Height > 0
                ? $"{_worker.Width}x{_worker.Height}"
                : "Offline";
        }

        if (_hwText != null)
        {
            _hwText.Text = _worker.IsHwAccelerated ? _worker.HwDeviceName.ToUpperInvariant() : "GPU";
        }

        if (_fpsText != null)
        {
            _fpsText.Text = pFps < dFps && dFps > 0 && pFps > 0
                ? $"{pFps:0} FPS ({dFps:0} dec)"
                : $"{fps:0.0} FPS";

            if (fps >= 25)
            {
                _fpsText.Foreground = GreenBrush;
                if (_fpsBadge != null) _fpsBadge.Background = GreenBadgeBg;
            }
            else if (fps >= 20)
            {
                _fpsText.Foreground = AmberBrush;
                if (_fpsBadge != null) _fpsBadge.Background = AmberBadgeBg;
            }
            else
            {
                _fpsText.Foreground = RedBrush;
                if (_fpsBadge != null) _fpsBadge.Background = RedBadgeBg;
            }
        }

        if (_connectingText != null)
        {
            if (!isConnected && _worker.PaintedFrames == 0 && _worker.DecodedFrames == 0)
            {
                _connectingText.Text = "CONNECTING...";
                _connectingText.IsVisible = true;
            }
            else if (!isConnected)
            {
                _connectingText.Text = "RECONNECTING...";
                _connectingText.IsVisible = true;
            }
            else
            {
                _connectingText.IsVisible = false;
            }
        }
    }
}
