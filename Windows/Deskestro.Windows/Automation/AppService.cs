using System.Diagnostics;
using System.Text.Json.Nodes;

namespace Deskestro.Windows.Automation;

internal sealed record WindowRecord(
    nint Handle,
    int ProcessId,
    int Index,
    string Title,
    NativeMethods.Rect Bounds,
    bool IsVisible,
    bool IsMinimized);

internal static class AppService
{
    internal static JsonArray ListApps()
    {
        var foreground = NativeMethods.GetForegroundWindow();
        var result = new JsonArray();
        foreach (var process in Process.GetProcesses().OrderBy(p => Safe(() => p.ProcessName) ?? string.Empty))
        {
            try
            {
                if (process.HasExited || process.MainWindowHandle == nint.Zero)
                    continue;
                result.Add(ToJson(process, process.MainWindowHandle == foreground));
            }
            catch { }
            finally { process.Dispose(); }
        }
        return result;
    }

    internal static Process Resolve(string app)
    {
        if (int.TryParse(app, out var pid))
        {
            try { return Process.GetProcessById(pid); }
            catch { throw new InvalidOperationException($"Application not running: {app}"); }
        }

        var normalized = Path.GetFileNameWithoutExtension(app);
        var candidates = Process.GetProcesses();
        Process? match = null;
        foreach (var process in candidates)
        {
            try
            {
                var processName = process.ProcessName;
                var title = process.MainWindowTitle;
                var executable = Safe(() => process.MainModule?.FileName);
                if (processName.Equals(normalized, StringComparison.OrdinalIgnoreCase) ||
                    (!string.IsNullOrWhiteSpace(title) && title.Equals(app, StringComparison.OrdinalIgnoreCase)) ||
                    (!string.IsNullOrWhiteSpace(executable) && executable.Equals(app, StringComparison.OrdinalIgnoreCase)))
                {
                    match = process;
                    break;
                }
            }
            catch { }
        }

        foreach (var process in candidates)
            if (!ReferenceEquals(process, match)) process.Dispose();
        return match ?? throw new InvalidOperationException($"Application not running: {app}");
    }

    internal static JsonObject Launch(string executable, string? arguments, bool foreground)
    {
        var start = new ProcessStartInfo(executable)
        {
            Arguments = arguments ?? string.Empty,
            UseShellExecute = true
        };
        var process = Process.Start(start) ?? throw new InvalidOperationException($"Could not launch: {executable}");
        try
        {
            _ = process.WaitForInputIdle(5000);
            process.Refresh();
            if (foreground && process.MainWindowHandle != nint.Zero)
                _ = NativeMethods.SetForegroundWindow(process.MainWindowHandle);
            return ToJson(process, foreground);
        }
        finally { process.Dispose(); }
    }

    internal static JsonObject Frontmost()
    {
        var hwnd = NativeMethods.GetForegroundWindow();
        if (hwnd == nint.Zero) throw new InvalidOperationException("No foreground application found.");
        _ = NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
        using var process = Process.GetProcessById((int)pid);
        return ToJson(process, true);
    }

    internal static JsonObject ToJson(Process process, bool active)
    {
        var executable = Safe(() => process.MainModule?.FileName);
        return new JsonObject
        {
            ["name"] = Safe(() => process.ProcessName) ?? "Unknown",
            ["identifier"] = executable is null ? Safe(() => process.ProcessName) : Path.GetFileName(executable),
            ["executablePath"] = executable,
            ["pid"] = process.Id,
            ["isActive"] = active,
            ["mainWindowTitle"] = Safe(() => process.MainWindowTitle) ?? string.Empty
        };
    }

    internal static List<WindowRecord> WindowsFor(int? pid = null, bool includeHidden = false)
    {
        var records = new List<WindowRecord>();
        var indices = new Dictionary<int, int>();
        _ = NativeMethods.EnumWindows((hwnd, lParam) =>
        {
            _ = NativeMethods.GetWindowThreadProcessId(hwnd, out var owner);
            if (owner == 0 || (pid is not null && owner != pid.Value)) return true;
            var visible = NativeMethods.IsWindowVisible(hwnd);
            if (!includeHidden && !visible) return true;
            if (!NativeMethods.GetWindowRect(hwnd, out var rect) || rect.Width <= 0 || rect.Height <= 0) return true;
            var title = NativeMethods.WindowTitle(hwnd);
            if (string.IsNullOrWhiteSpace(title) && !visible) return true;
            var ownerId = (int)owner;
            var index = indices.GetValueOrDefault(ownerId);
            indices[ownerId] = index + 1;
            records.Add(new WindowRecord(hwnd, ownerId, index, title, rect, visible, NativeMethods.IsIconic(hwnd)));
            return true;
        }, nint.Zero);
        return records;
    }

    internal static WindowRecord ResolveWindow(Process process, int index)
    {
        return WindowsFor(process.Id, includeHidden: true).FirstOrDefault(w => w.Index == index)
            ?? throw new InvalidOperationException($"Window {index} not found for {process.ProcessName}.");
    }

    internal static JsonObject WindowJson(WindowRecord window)
    {
        string appName;
        try { using var process = Process.GetProcessById(window.ProcessId); appName = process.ProcessName; }
        catch { appName = "Unknown"; }
        return new JsonObject
        {
            ["title"] = window.Title,
            ["appName"] = appName,
            ["pid"] = window.ProcessId,
            ["index"] = window.Index,
            ["handle"] = window.Handle.ToInt64().ToString("X"),
            ["isVisible"] = window.IsVisible,
            ["isMinimized"] = window.IsMinimized,
            ["bounds"] = new JsonObject
            {
                ["x"] = window.Bounds.Left,
                ["y"] = window.Bounds.Top,
                ["width"] = window.Bounds.Width,
                ["height"] = window.Bounds.Height
            }
        };
    }

    private static T? Safe<T>(Func<T?> action)
    {
        try { return action(); }
        catch { return default; }
    }
}
