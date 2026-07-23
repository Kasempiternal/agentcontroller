using System.Diagnostics;
using System.Text.Json.Nodes;

namespace Deskestro.Windows.Automation;

internal static class AppLauncher
{
    internal static JsonObject Launch(string executable, string? arguments, bool foreground)
    {
        var processName = Path.GetFileNameWithoutExtension(executable);
        var before = Process.GetProcessesByName(processName).Select(p => p.Id).ToHashSet();
        var started = Process.Start(new ProcessStartInfo(executable)
        {
            Arguments = arguments ?? string.Empty,
            UseShellExecute = true
        }) ?? throw new InvalidOperationException($"Could not launch: {executable}");

        try { _ = started.WaitForInputIdle(1000); }
        catch (InvalidOperationException) { }

        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < TimeSpan.FromSeconds(5))
        {
            Process? resolved = null;
            try
            {
                started.Refresh();
                if (!started.HasExited && started.MainWindowHandle != nint.Zero)
                    resolved = started;
            }
            catch (InvalidOperationException) { }

            var candidates = Process.GetProcessesByName(processName);
            if (resolved is null)
            {
                resolved = candidates
                    .Where(p => SafeWindowHandle(p) != nint.Zero)
                    .OrderBy(p => before.Contains(p.Id))
                    .ThenByDescending(p => p.Id)
                    .FirstOrDefault();
            }

            if (resolved is not null)
            {
                var hwnd = SafeWindowHandle(resolved);
                if (foreground && hwnd != nint.Zero) _ = NativeMethods.SetForegroundWindow(hwnd);
                var result = AppService.ToJson(resolved, foreground);
                foreach (var candidate in candidates)
                    if (!ReferenceEquals(candidate, resolved)) candidate.Dispose();
                if (!ReferenceEquals(resolved, started)) resolved.Dispose();
                return result;
            }

            foreach (var candidate in candidates) candidate.Dispose();
            Thread.Sleep(100);
        }

        throw new InvalidOperationException($"The launch command completed, but no '{processName}' window appeared within 5 seconds.");
    }

    private static nint SafeWindowHandle(Process process)
    {
        try { process.Refresh(); return process.MainWindowHandle; }
        catch { return nint.Zero; }
    }
}
