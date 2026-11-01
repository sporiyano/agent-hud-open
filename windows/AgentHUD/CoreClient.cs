using System.Diagnostics;
using Microsoft.UI.Dispatching;

namespace AgentHUD;

/// Runs `agenthud-core --watch` from this app's folder and hands each snapshot it prints to the interface thread. The
/// core quits when its standard input closes, so it goes when this process does, however that ends. A core that
/// stops on its own is started again after a pause.
public sealed class CoreClient : IDisposable
{
    private readonly DispatcherQueue dispatcher;
    private Process? process;
    private bool disposed;
    private int restarts;

    public event Action<Snapshot>? SnapshotReceived;
    public event Action<string>? Failed;

    public CoreClient(DispatcherQueue dispatcher)
    {
        this.dispatcher = dispatcher;
    }

    public static string ExecutablePath => Path.Combine(AppContext.BaseDirectory, "agenthud-core.exe");

    public void Start()
    {
        if (disposed) return;
        if (!File.Exists(ExecutablePath))
        {
            Report($"agenthud-core.exe is missing from {AppContext.BaseDirectory}");
            return;
        }
        var info = new ProcessStartInfo(ExecutablePath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            WorkingDirectory = AppContext.BaseDirectory,
        };
        info.ArgumentList.Add("--watch");
        var started = new Process { StartInfo = info, EnableRaisingEvents = true };
        started.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not { Length: > 0 } line) return;
            if (Snapshot.Parse(line) is { } snapshot)
            {
                restarts = 0;
                dispatcher.TryEnqueue(() => SnapshotReceived?.Invoke(snapshot));
            }
        };
        var errors = new System.Text.StringBuilder();
        started.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is { Length: > 0 } line && errors.Length < 4000) errors.AppendLine(line);
        };
        started.Exited += (_, _) =>
        {
            if (disposed) return;
            var message = errors.Length > 0 ? errors.ToString().Trim() : $"agenthud-core stopped (exit code {started.ExitCode})";
            Report(message);
            // Another copy holds the lock: starting again would only fail again.
            if (message.Contains("already running", StringComparison.OrdinalIgnoreCase) || restarts >= 5) return;
            restarts += 1;
            Task.Delay(TimeSpan.FromSeconds(5 * restarts)).ContinueWith(_ => dispatcher.TryEnqueue(Start));
        };
        try
        {
            started.Start();
        }
        catch (Exception error)
        {
            Report($"Could not start agenthud-core: {error.Message}");
            return;
        }
        started.BeginOutputReadLine();
        started.BeginErrorReadLine();
        process = started;
    }

    /// Asks the core to read the accounts again now.
    public void Refresh()
    {
        try { process?.StandardInput.WriteLine("refresh"); process?.StandardInput.Flush(); }
        catch (Exception) { }
    }

    private void Report(string message) => dispatcher.TryEnqueue(() => Failed?.Invoke(message));

    public void Dispose()
    {
        disposed = true;
        if (process is not { } running) return;
        try
        {
            running.StandardInput.Close();
            if (!running.WaitForExit(2000)) running.Kill();
        }
        catch (Exception) { }
        running.Dispose();
        process = null;
    }
}
