using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Deskestro.Windows.Automation;

internal static class RawInputService
{
    private const uint InputMouse = 0;
    private const uint InputKeyboard = 1;
    private const uint MouseLeftDown = 0x0002;
    private const uint MouseLeftUp = 0x0004;
    private const uint MouseRightDown = 0x0008;
    private const uint MouseRightUp = 0x0010;
    private const uint KeyUp = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        internal uint Type;
        internal InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] internal MouseInput Mouse;
        [FieldOffset(0)] internal KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        internal int Dx;
        internal int Dy;
        internal uint MouseData;
        internal uint Flags;
        internal uint Time;
        internal nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        internal ushort VirtualKey;
        internal ushort Scan;
        internal uint Flags;
        internal uint Time;
        internal nuint ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attachThread, uint attachToThread, bool attach);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(nint hwnd);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    internal static bool DoubleClick(int pid, int x, int y) => InForeground(pid, () =>
    {
        _ = NativeMethods.SetCursorPos(x, y);
        SendMouse(MouseLeftDown, MouseLeftUp);
        Thread.Sleep(70);
        SendMouse(MouseLeftDown, MouseLeftUp);
    });

    internal static bool RightClick(int pid, int x, int y) => InForeground(pid, () =>
    {
        _ = NativeMethods.SetCursorPos(x, y);
        SendMouse(MouseRightDown, MouseRightUp);
    });

    internal static bool SendShortcut(int pid, string key, IReadOnlyList<string> modifiers) => InForeground(pid, () =>
    {
        var keyCode = KeyCode(key);
        var modifierCodes = modifiers.Select(ModifierCode).Distinct().ToArray();
        var inputs = new List<Input>(modifierCodes.Length * 2 + 2);
        foreach (var modifier in modifierCodes) inputs.Add(KeyInput(modifier, keyUp: false));
        inputs.Add(KeyInput(keyCode, keyUp: false));
        inputs.Add(KeyInput(keyCode, keyUp: true));
        foreach (var modifier in modifierCodes.Reverse()) inputs.Add(KeyInput(modifier, keyUp: true));
        Send(inputs);
    });

    internal static bool Drag(int pid, int fromX, int fromY, int toX, int toY, double durationSeconds) => InForeground(pid, () =>
    {
        var duration = Math.Clamp(durationSeconds, 0.05, 10.0);
        var steps = Math.Clamp((int)Math.Ceiling(duration * 60), 4, 300);
        var delay = Math.Max(1, (int)Math.Round(duration * 1000 / steps));
        _ = NativeMethods.SetCursorPos(fromX, fromY);
        SendMouseDown(MouseLeftDown);
        try
        {
            for (var step = 1; step <= steps; step++)
            {
                var progress = step / (double)steps;
                var x = (int)Math.Round(fromX + (toX - fromX) * progress);
                var y = (int)Math.Round(fromY + (toY - fromY) * progress);
                _ = NativeMethods.SetCursorPos(x, y);
                Thread.Sleep(delay);
            }
        }
        finally
        {
            SendMouseUp(MouseLeftUp);
        }
    });

    private static bool InForeground(int pid, Action action)
    {
        using var process = Process.GetProcessById(pid);
        var window = AppService.ResolveWindow(process, 0);
        var previousWindow = NativeMethods.GetForegroundWindow();
        _ = NativeMethods.GetCursorPos(out var previousCursor);
        var activated = previousWindow != window.Handle;

        if (activated)
        {
            _ = NativeMethods.ShowWindow(window.Handle, NativeMethods.SwRestore);
            ActivateWindow(window.Handle);
            Thread.Sleep(120);
            var foreground = NativeMethods.GetForegroundWindow();
            _ = NativeMethods.GetWindowThreadProcessId(foreground, out var foregroundPid);
            if (foregroundPid != pid)
                throw new InvalidOperationException("Windows refused to foreground the target application. Raw input was not sent.");
        }

        try
        {
            action();
            Thread.Sleep(120);
            return activated;
        }
        finally
        {
            _ = NativeMethods.SetCursorPos(previousCursor.X, previousCursor.Y);
            if (activated && previousWindow != nint.Zero) _ = NativeMethods.SetForegroundWindow(previousWindow);
        }
    }

    private static void ActivateWindow(nint targetWindow)
    {
        var foregroundWindow = NativeMethods.GetForegroundWindow();
        var foregroundThread = foregroundWindow == nint.Zero
            ? 0
            : NativeMethods.GetWindowThreadProcessId(foregroundWindow, out _);
        var currentThread = GetCurrentThreadId();
        var attached = foregroundThread != 0 && foregroundThread != currentThread &&
            AttachThreadInput(currentThread, foregroundThread, true);
        try
        {
            _ = BringWindowToTop(targetWindow);
            _ = NativeMethods.SetForegroundWindow(targetWindow);
        }
        finally
        {
            if (attached) _ = AttachThreadInput(currentThread, foregroundThread, false);
        }
    }

    private static void SendMouse(uint down, uint up)
        => Send([MouseEvent(down), MouseEvent(up)]);

    private static void SendMouseDown(uint flags)
        => Send([MouseEvent(flags)]);

    private static void SendMouseUp(uint flags)
        => Send([MouseEvent(flags)]);

    private static Input MouseEvent(uint flags) => new()
    {
        Type = InputMouse,
        Union = new InputUnion { Mouse = new MouseInput { Flags = flags } }
    };

    private static Input KeyInput(ushort virtualKey, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInput { VirtualKey = virtualKey, Flags = keyUp ? KeyUp : 0 }
        }
    };

    private static void Send(IReadOnlyCollection<Input> inputs)
    {
        var array = inputs.ToArray();
        var sent = SendInput((uint)array.Length, array, Marshal.SizeOf<Input>());
        if (sent != array.Length)
            throw new InvalidOperationException($"Windows accepted {sent} of {array.Length} input events. UIPI may be blocking an elevated target.");
    }

    private static ushort ModifierCode(string modifier) => modifier.ToLowerInvariant() switch
    {
        "ctrl" or "control" => 0x11,
        "shift" => 0x10,
        "alt" or "opt" or "option" => 0x12,
        "cmd" or "win" or "windows" => 0x5B,
        _ => throw new InvalidOperationException($"Unknown modifier: {modifier}")
    };

    private static ushort KeyCode(string key)
    {
        var normalized = key.Trim().ToLowerInvariant();
        if (normalized.Length == 1)
        {
            var character = normalized[0];
            if (character is >= 'a' and <= 'z') return char.ToUpperInvariant(character);
            if (character is >= '0' and <= '9') return character;
        }
        if (normalized.StartsWith('f') && int.TryParse(normalized[1..], out var function) && function is >= 1 and <= 24)
            return (ushort)(0x70 + function - 1);
        return normalized switch
        {
            "backspace" => 0x08,
            "tab" => 0x09,
            "return" or "enter" => 0x0D,
            "escape" or "esc" => 0x1B,
            "space" => 0x20,
            "pageup" => 0x21,
            "pagedown" => 0x22,
            "end" => 0x23,
            "home" => 0x24,
            "left" => 0x25,
            "up" => 0x26,
            "right" => 0x27,
            "down" => 0x28,
            "insert" => 0x2D,
            "delete" or "forwarddelete" => 0x2E,
            _ => throw new InvalidOperationException($"Unknown key: {key}")
        };
    }
}
