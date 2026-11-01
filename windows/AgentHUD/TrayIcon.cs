using System.Runtime.InteropServices;

namespace AgentHUD;

/// The notification-area icon: a left click shows or hides the HUD, a right click opens Show or hide, Refresh and
/// Quit. It listens on the HUD window's own messages, which it subclasses, so it needs no window of its own.
public sealed class TrayIcon : IDisposable
{
    private const int CallbackMessage = 0x8000 + 0x4D; // WM_APP + 77
    private const uint IconId = 1;
    private const int CommandToggle = 1, CommandRefresh = 2, CommandQuit = 3;

    private readonly IntPtr window;
    private readonly SubclassProc procedure;
    private readonly IntPtr icon;
    private readonly uint taskbarCreated;
    private string tooltip;
    private bool disposed;

    public event Action? ToggleRequested;
    public event Action? RefreshRequested;
    public event Action? QuitRequested;

    public TrayIcon(IntPtr window, string tooltip)
    {
        this.window = window;
        this.tooltip = tooltip;
        icon = LoadImageW(IntPtr.Zero, Path.Combine(AppContext.BaseDirectory, "Assets", "AgentHUD.ico"), 1 /* IMAGE_ICON */,
                          GetSystemMetrics(49 /* SM_CXSMICON */), GetSystemMetrics(50 /* SM_CYSMICON */), 0x10 /* LR_LOADFROMFILE */);
        taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        procedure = Procedure;
        SetWindowSubclass(window, procedure, IntPtr.Zero, IntPtr.Zero);
        Add();
    }

    /// The text shown when the pointer rests on the icon.
    public void SetTooltip(string text)
    {
        tooltip = text.Length > 120 ? text[..120] : text;
        var data = Data();
        data.uFlags = 0x4; // NIF_TIP
        Shell_NotifyIconW(1 /* NIM_MODIFY */, ref data);
    }

    private void Add()
    {
        var data = Data();
        data.uFlags = 0x1 | 0x2 | 0x4; // NIF_MESSAGE | NIF_ICON | NIF_TIP
        Shell_NotifyIconW(0 /* NIM_ADD */, ref data);
    }

    private NotifyIconData Data() => new()
    {
        cbSize = (uint)Marshal.SizeOf<NotifyIconData>(),
        hWnd = window,
        uID = IconId,
        uCallbackMessage = CallbackMessage,
        hIcon = icon,
        szTip = tooltip,
    };

    private IntPtr Procedure(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, IntPtr id, IntPtr data)
    {
        if (message == CallbackMessage)
        {
            switch ((int)(lParam.ToInt64() & 0xFFFF))
            {
                case 0x0202: // WM_LBUTTONUP
                    ToggleRequested?.Invoke();
                    return IntPtr.Zero;
                case 0x0205: // WM_RBUTTONUP
                    ShowMenu();
                    return IntPtr.Zero;
            }
        }
        else if (message == taskbarCreated)
        {
            // Explorer restarted and forgot every icon.
            Add();
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var menu = CreatePopupMenu();
        AppendMenuW(menu, 0, (UIntPtr)CommandToggle, "Show or hide");
        AppendMenuW(menu, 0, (UIntPtr)CommandRefresh, "Refresh now");
        AppendMenuW(menu, 0x800 /* MF_SEPARATOR */, UIntPtr.Zero, null);
        AppendMenuW(menu, 0, (UIntPtr)CommandQuit, "Quit Agent HUD");
        GetCursorPos(out var point);
        // The menu closes when it loses focus only if its owner is in front.
        SetForegroundWindow(window);
        var chosen = TrackPopupMenuEx(menu, 0x100 /* TPM_RETURNCMD */ | 0x20 /* TPM_RIGHTALIGN */, point.X, point.Y, window, IntPtr.Zero);
        DestroyMenu(menu);
        switch (chosen)
        {
            case CommandToggle: ToggleRequested?.Invoke(); break;
            case CommandRefresh: RefreshRequested?.Invoke(); break;
            case CommandQuit: QuitRequested?.Invoke(); break;
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        var data = Data();
        Shell_NotifyIconW(2 /* NIM_DELETE */, ref data);
        RemoveWindowSubclass(window, procedure, IntPtr.Zero);
        if (icon != IntPtr.Zero) DestroyIcon(icon);
    }

    // MARK: Win32

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, IntPtr id, IntPtr data);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public int uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X; public int Y; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Shell_NotifyIconW(uint message, ref NotifyIconData data);

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc procedure, IntPtr id, IntPtr data);

    [DllImport("comctl32.dll")]
    private static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProc procedure, IntPtr id);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadImageW(IntPtr instance, string name, uint type, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessageW(string name);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string? text);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr window, IntPtr parameters);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
}
