using Microsoft.UI.Xaml;

namespace AgentHUD;

/// Starts agenthud-core, the HUD window and the tray icon; quitting from the tray ends all three.
public partial class App : Application
{
    private HudWindow? hud;
    private CoreClient? core;
    private TrayIcon? tray;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        hud = new HudWindow();
        core = new CoreClient(hud.DispatcherQueue);
        core.SnapshotReceived += hud.Show;
        core.Failed += hud.ShowError;
        tray = new TrayIcon(hud.Handle, "Agent HUD");
        tray.ToggleRequested += hud.ToggleVisible;
        tray.RefreshRequested += core.Refresh;
        tray.QuitRequested += Quit;
        hud.Activate();
        core.Start();
    }

    private void Quit()
    {
        tray?.Dispose();
        core?.Dispose();
        hud?.Close();
        Exit();
    }
}
