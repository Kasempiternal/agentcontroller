using System.Diagnostics;
using System.Text.Json.Nodes;
using AgentController.Windows.Automation;
using AgentController.Windows.Protocol;

namespace AgentController.Windows.Tools;

internal static class AppTools
{
    internal static void Register(ToolRegistry registry)
    {
        registry.Register("list_apps", "List desktop applications with top-level windows.", ToolSchema.Empty(),
            _ => ToolResult.Json(new JsonObject { ["apps"] = AppService.ListApps() }), readOnly: true);

        registry.Register("get_frontmost_app", "Return the application that currently owns foreground focus.", ToolSchema.Empty(),
            _ => ToolResult.Json(AppService.Frontmost()), readOnly: true);

        var launch = new JsonObject
        {
            ["path"] = ToolSchema.String("Executable path, app URI, document, or shell-resolvable application name."),
            ["bundleId"] = ToolSchema.String("Compatibility alias for path on Windows."),
            ["arguments"] = ToolSchema.String("Optional command-line arguments."),
            ["foreground"] = ToolSchema.Boolean("Allow the launched app to take focus.", false)
        };
        registry.Register("launch_app", "Launch a Windows application. Use path; bundleId is accepted as a compatibility alias.", ToolSchema.Object(launch), args =>
        {
            var path = UiAutomationService.String(args, "path") ?? UiAutomationService.String(args, "bundleId")
                ?? throw new InvalidOperationException("Missing path.");
            return ToolResult.Json(AppLauncher.Launch(path, UiAutomationService.String(args, "arguments"), UiAutomationService.Bool(args, "foreground")));
        });

        var appOnly = ToolSchema.Object(AppProperties(), "app");
        registry.Register("activate_app", "Bring an application to the foreground. This intentionally changes user focus.", appOnly, args =>
        {
            using var process = AppService.Resolve(Required(args, "app"));
            var window = AppService.ResolveWindow(process, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
            _ = NativeMethods.ShowWindow(window.Handle, NativeMethods.SwRestore);
            var ok = NativeMethods.SetForegroundWindow(window.Handle);
            return ok ? ToolResult.Json(new JsonObject { ["success"] = true, ["pid"] = process.Id }) : ToolResult.Error("Windows refused to activate the application.");
        });

        var quitProperties = AppProperties();
        quitProperties["force"] = ToolSchema.Boolean("Force-kill if a graceful close is unavailable. Unsaved work can be lost.", false);
        registry.Register("quit_app", "Request that an application close. force:true terminates it and can lose unsaved work.", ToolSchema.Object(quitProperties, "app"), args =>
        {
            using var process = AppService.Resolve(Required(args, "app"));
            var force = UiAutomationService.Bool(args, "force");
            var graceful = process.CloseMainWindow();
            if (!graceful && force) process.Kill(entireProcessTree: true);
            if (!graceful && !force) return ToolResult.Error("The app has no closable main window. Retry with force:true only if data loss is acceptable.");
            return ToolResult.Json(new JsonObject { ["success"] = true, ["method"] = graceful ? "close-window" : "terminate" });
        }, destructive: true);

        registry.Register("hide_app", "Hide all top-level windows without terminating the process. Hidden UI may disappear from UI Automation.", appOnly, args => ShowAll(args, NativeMethods.SwHide, "hide"));
        registry.Register("unhide_app", "Show hidden top-level windows without intentionally activating them.", appOnly, args => ShowAll(args, NativeMethods.SwShowNoActivate, "show-no-activate"));

        var urlSchema = ToolSchema.Object(new JsonObject
        {
            ["url"] = ToolSchema.String("URL, file path, or shell URI."),
            ["foreground"] = ToolSchema.Boolean("Accepted for compatibility; Windows shell controls activation.", false)
        }, "url");
        registry.Register("open_url", "Open a URL, file, or registered shell URI with the default Windows application.", urlSchema, args =>
        {
            var value = Required(args, "url");
            Process.Start(new ProcessStartInfo(value) { UseShellExecute = true });
            return ToolResult.Json(new JsonObject { ["success"] = true, ["url"] = value });
        });

        registry.Register("reset_app_state", "Not generically available on Windows; application data locations are app-specific.", ToolSchema.Object(new JsonObject
        {
            ["app"] = ToolSchema.String("Application identifier."),
            ["wipeData"] = ToolSchema.Boolean("Required opt-in in the macOS implementation.", false)
        }, "app"), _ => ToolResult.Error("reset_app_state is unsupported on Windows because Win32/MSIX applications do not share one safe data-container model."), destructive: true);

        RegisterWindowTools(registry);
    }

    private static void RegisterWindowTools(ToolRegistry registry)
    {
        var listProperties = new JsonObject { ["app"] = ToolSchema.String("Optional application identifier; omit for all visible windows.") };
        registry.Register("list_windows", "List top-level Windows desktop windows.", ToolSchema.Object(listProperties), args =>
        {
            int? pid = null;
            if (UiAutomationService.String(args, "app") is { } app)
            {
                using var process = AppService.Resolve(app);
                pid = process.Id;
            }
            var windows = new JsonArray(AppService.WindowsFor(pid).Select(w => (JsonNode?)AppService.WindowJson(w)).ToArray());
            return ToolResult.Json(new JsonObject { ["windows"] = windows });
        }, readOnly: true);

        var appSchema = ToolSchema.Object(AppProperties(), "app");
        registry.Register("get_window_bounds", "Get a top-level window's bounds.", appSchema, args =>
        {
            using var process = AppService.Resolve(Required(args, "app"));
            var window = AppService.ResolveWindow(process, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
            return ToolResult.Json(AppService.WindowJson(window));
        }, readOnly: true);

        var setProperties = AppProperties();
        setProperties["x"] = ToolSchema.Number("New left coordinate; omit to preserve.");
        setProperties["y"] = ToolSchema.Number("New top coordinate; omit to preserve.");
        setProperties["width"] = ToolSchema.Number("New width; omit to preserve.");
        setProperties["height"] = ToolSchema.Number("New height; omit to preserve.");
        registry.Register("set_window_bounds", "Move or resize a top-level window without activating it.", ToolSchema.Object(setProperties, "app"), args =>
        {
            using var process = AppService.Resolve(Required(args, "app"));
            var window = AppService.ResolveWindow(process, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
            var x = Number(args, "x", window.Bounds.Left);
            var y = Number(args, "y", window.Bounds.Top);
            var width = Math.Max(1, Number(args, "width", window.Bounds.Width));
            var height = Math.Max(1, Number(args, "height", window.Bounds.Height));
            var ok = NativeMethods.SetWindowPos(window.Handle, nint.Zero, x, y, width, height, NativeMethods.SwpNoZOrder | NativeMethods.SwpNoActivate);
            return ok ? ToolResult.Json(new JsonObject { ["success"] = true }) : ToolResult.Error("Windows refused to move or resize the window.");
        });

        registry.Register("minimize_window", "Minimize a top-level window.", appSchema, args => WindowShow(args, 6, "minimized"));
        registry.Register("restore_window", "Restore a minimized/hidden top-level window without intentionally activating it.", appSchema, args => WindowShow(args, NativeMethods.SwShowNoActivate, "restored"));
    }

    private static JsonObject WindowShow(JsonObject args, int command, string state)
    {
        using var process = AppService.Resolve(Required(args, "app"));
        var window = AppService.ResolveWindow(process, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
        _ = NativeMethods.ShowWindow(window.Handle, command);
        return ToolResult.Json(new JsonObject { ["success"] = true, ["state"] = state });
    }

    private static JsonObject ShowAll(JsonObject args, int command, string method)
    {
        using var process = AppService.Resolve(Required(args, "app"));
        var windows = AppService.WindowsFor(process.Id, includeHidden: true);
        foreach (var window in windows) _ = NativeMethods.ShowWindow(window.Handle, command);
        return ToolResult.Json(new JsonObject { ["success"] = windows.Count > 0, ["windowCount"] = windows.Count, ["method"] = method });
    }

    private static JsonObject AppProperties() => ToolSchema.AppProperties();
    internal static string Required(JsonObject args, string name) => UiAutomationService.String(args, name) ?? throw new InvalidOperationException($"Missing {name}.");
    private static int Number(JsonObject args, string name, int fallback)
    {
        if (args[name] is not JsonValue value) return fallback;
        if (value.TryGetValue<int>(out var integer)) return integer;
        if (value.TryGetValue<double>(out var number)) return (int)Math.Round(number);
        return fallback;
    }
}
