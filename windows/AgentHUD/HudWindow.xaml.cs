using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.UI;

namespace AgentHUD;

/// The HUD: a small strip at the top of the primary screen with a mark per agent, coloured by how much of its quota is
/// used, that opens into the panel while the pointer is over it: every quota window, the newest sessions and the
/// balances.
public sealed partial class HudWindow : Window
{
    private const double StripWidth = 260, PanelWidth = 400, StripHeight = 36, MaxPanelHeight = 640;

    private Snapshot? snapshot;
    private string? error;
    private bool expanded;
    private readonly DispatcherTimer collapseTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(30) };

    public IntPtr Handle { get; }

    public HudWindow()
    {
        InitializeComponent();
        Handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        AppWindow.Title = "Agent HUD";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AgentHUD.ico"));
        var corner = 2; // DWMWCP_ROUND
        DwmSetWindowAttribute(Handle, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref corner, sizeof(int));

        Root.PointerEntered += (_, _) => { collapseTimer.Stop(); SetExpanded(true); };
        Root.PointerExited += (_, _) => collapseTimer.Start();
        collapseTimer.Tick += (_, _) => { collapseTimer.Stop(); SetExpanded(false); };
        clock.Tick += (_, _) => Render();
        clock.Start();
        // Closing the window from the keyboard hides it; Quit in the tray menu ends the app.
        AppWindow.Closing += (_, e) => { e.Cancel = true; AppWindow.Hide(); };
        Summary.Text = "Agent HUD · starting…";
        Place();
    }

    public void Show(Snapshot next)
    {
        if (next.Version > Snapshot.SupportedVersion) error = "This agenthud-core is newer than the HUD; some fields may be missing.";
        else error = next.Error;
        snapshot = next;
        Render();
    }

    public void ShowError(string message)
    {
        error = message;
        Render();
    }

    public void ToggleVisible()
    {
        if (AppWindow.IsVisible) AppWindow.Hide();
        else { AppWindow.Show(); Place(); }
    }

    private void SetExpanded(bool value)
    {
        if (expanded == value) return;
        expanded = value;
        Panel.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        Render();
    }

    // MARK: Drawing

    private void Render()
    {
        Marks.Children.Clear();
        var rows = snapshot?.Rows.Where(r => r.IsCurrentAccount).ToList() ?? new List<Row>();
        foreach (var group in rows.GroupBy(r => r.Vendor))
        {
            var worst = group.Max(r => r.UsedPct ?? -1);
            var level = Worst(group.Select(r => r.Level));
            var working = snapshot?.WorkingVendors.Contains(group.Key) == true;
            Marks.Children.Add(Mark(group.Key, group.First().VendorName, level, worst, working));
        }
        if (snapshot is null) Summary.Text = error is null ? "Agent HUD · starting…" : "Agent HUD · not running";
        else if (snapshot.IsLoading && rows.Count == 0) Summary.Text = "Reading…";
        else if (rows.Count == 0) Summary.Text = "No agents found";
        else Summary.Text = snapshot.MaxUsedPct is { } max ? $"{Math.Round(max)}%" : "—";
        Summary.Foreground = new SolidColorBrush(LevelColor(snapshot?.Level, fallback: Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)));

        Panel.Children.Clear();
        if (expanded) FillPanel(rows);
        Place();
    }

    private void FillPanel(List<Row> rows)
    {
        if (error is { } message) Panel.Children.Add(Caption(message, Color.FromArgb(0xFF, 0xFF, 0x9F, 0x0A), wrap: true));
        if (snapshot is null) return;
        foreach (var group in snapshot.Rows.GroupBy(r => r.VendorName))
        {
            Panel.Children.Add(Heading(group.Key));
            foreach (var row in group) Panel.Children.Add(QuotaRow(row));
        }
        var sessions = snapshot.Sessions.OrderByDescending(s => s.IsLive).ThenByDescending(s => s.ObservedAt).Take(5).ToList();
        if (sessions.Count > 0)
        {
            Panel.Children.Add(Heading("Sessions"));
            foreach (var session in sessions) Panel.Children.Add(SessionRow(session));
        }
        foreach (var account in snapshot.Billing.Where(b => b.Balances.Count > 0))
        {
            Panel.Children.Add(Heading(account.Name));
            Panel.Children.Add(Caption(string.Join(" · ", account.Balances), Colors.White));
        }
        Panel.Children.Add(Caption($"Updated {snapshot.GeneratedAt.ToLocalTime():HH:mm}", Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)));
    }

    private static UIElement Mark(string vendor, string name, string? level, double used, bool working)
    {
        var grid = new Grid { Width = 22, Height = 22 };
        ToolTipService.SetToolTip(grid, used >= 0 ? $"{name}: {Math.Round(used)}% used" : name);
        grid.Children.Add(Logo(vendor, name, 18));
        var dot = new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 7, Height = 7,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Fill = new SolidColorBrush(LevelColor(level, fallback: Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF))),
            Stroke = new SolidColorBrush(Color.FromArgb(0xFF, 0x1C, 0x1C, 0x1E)), StrokeThickness = 1.5,
        };
        grid.Children.Add(dot);
        if (working) grid.Opacity = 1; else grid.Opacity = 0.85;
        return grid;
    }

    private static UIElement QuotaRow(Row row)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
        var name = new TextBlock { Text = row.ShortName, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(name, row.Name);
        var bar = new ProgressBar
        {
            Minimum = 0, Maximum = 100, Value = row.UsedPct ?? 0, Height = 6, VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(LevelColor(row.Level, fallback: Color.FromArgb(0xFF, 0x8E, 0x8E, 0x93))),
            Opacity = row.IsCurrentAccount ? 1 : 0.5,
        };
        var used = row.UsedPct is { } pct ? $"{Math.Round(pct)}%" : "N/A";
        var detail = new TextBlock
        {
            Text = $"{used} · {row.ResetLabel}", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)),
        };
        Grid.SetColumn(bar, 1);
        Grid.SetColumn(detail, 2);
        grid.Children.Add(name);
        grid.Children.Add(bar);
        grid.Children.Add(detail);
        return grid;
    }

    private static UIElement SessionRow(Session session)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var colour = session.IsWaiting ? Color.FromArgb(0xFF, 0xFF, 0x9F, 0x0A)
            : session.IsLive ? Color.FromArgb(0xFF, 0x34, 0xC7, 0x59) : Color.FromArgb(0x60, 0xFF, 0xFF, 0xFF);
        line.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 6, Height = 6, Fill = new SolidColorBrush(colour), VerticalAlignment = VerticalAlignment.Center });
        if (session.Vendor is { } vendor) line.Children.Add(Logo(vendor, vendor, 14));
        line.Children.Add(new TextBlock { Text = session.Title, FontSize = 12, MaxWidth = 230, TextTrimming = TextTrimming.CharacterEllipsis });
        line.Children.Add(new TextBlock { Text = session.Status, FontSize = 11, Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)) });
        ToolTipService.SetToolTip(line, string.Join(" · ", new[] { session.Title, session.Project, session.Client }.Where(s => !string.IsNullOrEmpty(s))));
        return line;
    }

    private static TextBlock Heading(string text) => new()
    {
        Text = text, FontSize = 11, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 0),
        Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
    };

    private static TextBlock Caption(string text, Color colour, bool wrap = false) => new()
    {
        Text = text, FontSize = 11, Foreground = new SolidColorBrush(colour),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
    };

    // MARK: Artwork and colours

    private static readonly Dictionary<string, string> Artwork = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Claude"] = "claude", ["Codex"] = "chatgpt", ["ChatGPT"] = "chatgpt", ["Antigravity"] = "antigravity",
        ["DeepSeek"] = "deepseek", ["Grok"] = "grok", ["Grok Bot"] = "grok-bot", ["Cursor"] = "cursor",
        ["OpenCode"] = "opencode", ["Kimi"] = "kimi", ["GLM"] = "glm", ["Pi"] = "pi", ["GitHub Copilot"] = "copilot",
        ["Copilot"] = "copilot", ["OpenClaw"] = "openclaw", ["Hermes"] = "hermes", ["ZCode"] = "zcode",
        ["CodeBuddy"] = "codebuddy", ["WorkBuddy"] = "workbuddy", ["Qwen"] = "qwen", ["Qoder"] = "qoder",
    };

    /// Marks drawn in one colour, which the Mac tints to the menu's text; here they take white.
    private static readonly HashSet<string> Monochrome = new(StringComparer.OrdinalIgnoreCase)
    {
        "grok", "cursor", "kimi", "pi", "copilot", "hermes", "zcode", "chatgpt",
    };

    private static FrameworkElement Logo(string vendor, string name, double size)
    {
        if (Artwork.TryGetValue(vendor, out var file))
        {
            var uri = new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Vendors", file + ".png"));
            if (Monochrome.Contains(file))
                return new BitmapIcon { UriSource = uri, ShowAsMonochrome = true, Foreground = new SolidColorBrush(Colors.White), Width = size, Height = size };
            return new Image { Source = new BitmapImage(uri), Width = size, Height = size };
        }
        return new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size / 4),
            Background = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
            Child = new TextBlock
            {
                Text = name.Length > 0 ? name[..1].ToUpperInvariant() : "?", FontSize = size * 0.6, FontWeight = FontWeights.Bold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    private static string? Worst(IEnumerable<string?> levels)
    {
        var all = levels.ToList();
        if (all.Contains("critical")) return "critical";
        if (all.Contains("warning")) return "warning";
        return all.Contains("ok") ? "ok" : null;
    }

    private static Color LevelColor(string? level, Color fallback) => level switch
    {
        "ok" => Color.FromArgb(0xFF, 0x34, 0xC7, 0x59),
        "warning" => Color.FromArgb(0xFF, 0xFF, 0xCC, 0x00),
        "critical" => Color.FromArgb(0xFF, 0xFF, 0x3B, 0x30),
        _ => fallback,
    };

    // MARK: Placement

    /// Centred at the top of the primary screen's work area, as tall as what it shows.
    private void Place()
    {
        var scale = GetDpiForWindow(Handle) / 96.0;
        if (scale <= 0) scale = 1;
        var width = expanded ? PanelWidth : StripWidth;
        double height = StripHeight;
        if (expanded)
        {
            Root.Measure(new Windows.Foundation.Size(width, double.PositiveInfinity));
            height = Math.Clamp(Root.DesiredSize.Height, StripHeight, MaxPanelHeight);
        }
        var area = DisplayArea.Primary.WorkArea;
        var pixels = new SizeInt32((int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale));
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - pixels.Width) / 2, area.Y + (int)(6 * scale), pixels.Width, pixels.Height));
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}
