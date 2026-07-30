using System.Text.Json.Nodes;
using AgentController.Windows.Automation;
using AgentController.Windows.Protocol;

namespace AgentController.Windows.Tools;

internal static class CaptureTools
{
    internal static void Register(ToolRegistry registry, UiAutomationService automation)
    {
        registry.Register("screenshot_screen", "Capture the Windows virtual desktop as PNG. This captures visible pixels.", ToolSchema.Empty(),
            _ => ToolResult.Image(CaptureService.CaptureScreen(), "image/png", new JsonObject { ["captureMode"] = "visible-desktop" }), readOnly: true);

        var windowSchema = ToolSchema.Object(ToolSchema.AppProperties(), "app");
        registry.Register("screenshot_window", "Capture one top-level window as PNG using PrintWindow, with visible-pixel fallback.", windowSchema, args =>
        {
            using var process = AppService.Resolve(AppTools.Required(args, "app"));
            var window = AppService.ResolveWindow(process, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
            var data = CaptureService.CaptureWindow(window.Handle);
            return ToolResult.Image(data, "image/png", new JsonObject
            {
                ["app"] = process.ProcessName,
                ["pid"] = process.Id,
                ["windowIndex"] = window.Index,
                ["captureMode"] = "print-window"
            });
        }, readOnly: true);

        registry.Register("screenshot_element", "Capture the visible pixels inside an element's bounding rectangle as PNG.", ToolSchema.Object(ToolSchema.SelectorProperties(), "app"), args =>
        {
            var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
            var data = CaptureService.CaptureElement(element);
            return ToolResult.Image(data, "image/png", new JsonObject { ["captureMode"] = "visible-element-bounds" });
        }, readOnly: true);

        registry.Register("start_recording", "Video recording is not implemented in the Windows milestone.", ToolSchema.Object(ToolSchema.AppProperties(), "app"),
            _ => ToolResult.Error("start_recording is not implemented on Windows yet; use screenshot_window for evidence."));
        registry.Register("stop_recording", "Video recording is not implemented in the Windows milestone.", ToolSchema.Empty(),
            _ => ToolResult.Error("stop_recording is not implemented on Windows yet."));
    }
}
