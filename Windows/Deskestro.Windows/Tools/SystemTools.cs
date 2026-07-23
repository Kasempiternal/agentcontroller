using System.Text.Json.Nodes;
using Deskestro.Windows.Protocol;

namespace Deskestro.Windows.Tools;

internal static class SystemTools
{
    internal static void Register(ToolRegistry registry)
    {
        registry.Register("check_permissions", "Report Windows automation readiness and security boundaries.", ToolSchema.Empty(), _ =>
            ToolResult.Json(new JsonObject
            {
                ["allGranted"] = true,
                ["uiAutomationAvailable"] = true,
                ["screenCaptureAvailable"] = Environment.UserInteractive,
                ["userInteractive"] = Environment.UserInteractive,
                ["limitations"] = new JsonArray(
                    "Windows UIPI blocks input and some automation across integrity levels.",
                    "The interactive desktop must be unlocked.",
                    "Raw input is foreground-only; UIA control patterns remain background-safe.")
            }), readOnly: true);

        registry.Register("get_clipboard", "Read Unicode text from the system-wide Windows clipboard.", ToolSchema.Empty(), _ =>
        {
            try
            {
                var text = System.Windows.Forms.Clipboard.ContainsText() ? System.Windows.Forms.Clipboard.GetText() : string.Empty;
                return ToolResult.Json(new JsonObject { ["text"] = text });
            }
            catch (System.Runtime.InteropServices.ExternalException ex)
            {
                return ToolResult.Error($"Clipboard is busy: {ex.Message}");
            }
        }, readOnly: true);

        registry.Register("set_clipboard", "Replace the system-wide Windows clipboard text.", ToolSchema.Object(new JsonObject
        {
            ["text"] = ToolSchema.String("Text to place on the clipboard.")
        }, "text"), args =>
        {
            try
            {
                System.Windows.Forms.Clipboard.SetText(AppTools.Required(args, "text"));
                return ToolResult.Json(new JsonObject { ["success"] = true });
            }
            catch (System.Runtime.InteropServices.ExternalException ex)
            {
                return ToolResult.Error($"Clipboard is busy: {ex.Message}");
            }
        }, destructive: true);
    }
}
