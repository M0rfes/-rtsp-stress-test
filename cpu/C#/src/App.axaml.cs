using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;

namespace RtspStressTest;

public partial class App : Application
{
    public static AppConfig Config { get; set; } = new();
    public static TelemetryManager? Telemetry { get; set; }

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var telemetry = Telemetry ?? new TelemetryManager(Config.LogPath, Config.MachineId, Config.StreamCount);
            desktop.MainWindow = new MainWindow(Config, telemetry);
        }

        base.OnFrameworkInitializationCompleted();
    }
}
