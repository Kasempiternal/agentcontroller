using System.Text.Json.Nodes;
using AgentController.Windows.Protocol;
using AgentController.Windows.Routing;

namespace AgentController.Windows.Tools;

internal static class CapabilityTools
{
    internal const string InspectDescription =
        "Probe a target (bundle ID, PID, URL, or iOS simulator UDID) and return the best backend this MCP will use. Handshakes native sockets (Blender Lab/community, Chrome CDP, idb). Does not ask except to report multi-instance, missing add-on, or code-exec consent. Do not pick Playwright vs AX vs bpy vs idb — call this, or just snapshot/click, and the server routes.";

    internal const string RunAppCodeDescription =
        "Run a script on the auto-selected backend: Python in Blender (bpy) when the socket handshakes, JavaScript in a CDP page, otherwise an error pointing at AX run_steps. One script is the batch — do not issue one MCP call per primitive. First use per backend requires consent:true (RCE inside the app). Returns {backend, result}.";

    internal static void Register(ToolRegistry registry)
    {
        var inspect = new JsonObject
        {
            ["target"] = ToolSchema.String("Bundle ID, app name, PID, URL, or iOS simulator UDID"),
            ["app"] = ToolSchema.String("Alias of target"),
            ["url"] = ToolSchema.String("Page URL (forces the CDP backend)"),
            ["udid"] = ToolSchema.String("iOS simulator UDID or 'booted'")
        };
        registry.Register("inspect_capabilities", InspectDescription, ToolSchema.Object(inspect), args =>
        {
            var identity = TargetIdentity.From(args) ?? throw new InvalidOperationException("Missing target.");
            return ToolResult.Json(CapabilityProbe.Probe(identity).ToJson());
        }, readOnly: true);

        var run = new JsonObject
        {
            ["app"] = ToolSchema.String("Bundle ID, app name, PID, URL, or simulator UDID"),
            ["target"] = ToolSchema.String("Alias of app"),
            ["url"] = ToolSchema.String("Page URL for CDP JavaScript"),
            ["code"] = ToolSchema.String("Python (Blender) or JavaScript (CDP) to execute"),
            ["language"] = ToolSchema.String("Optional hint: python or javascript."),
            ["consent"] = ToolSchema.Boolean("Required the first time per backend; persists after that.")
        };
        registry.Register("run_app_code", RunAppCodeDescription, ToolSchema.Object(run, "code"), args =>
        {
            var identity = TargetIdentity.From(args) ?? throw new InvalidOperationException("Missing app.");
            if (args["code"]?.GetValue<string>() is null) throw new InvalidOperationException("Missing code.");
            var capability = CapabilityProbe.Probe(identity);
            return ToolResult.Error($"No in-process backend for '{identity.Raw}' (probe backend={capability.Backend}). Use snapshot → elementId → run_steps for native UI.");
        });
    }
}
