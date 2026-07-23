using System.Text.Json.Nodes;
using Deskestro.Windows.Automation;
using Deskestro.Windows.Protocol;

namespace Deskestro.Windows.Tools;

internal sealed class ToolRegistry
{
    internal delegate JsonObject Handler(JsonObject arguments);
    private sealed record Definition(string Name, string Description, JsonObject Schema, Handler Call, bool ReadOnly, bool Destructive);
    private readonly Dictionary<string, Definition> tools = new(StringComparer.Ordinal);

    internal ToolRegistry()
    {
        var automation = new UiAutomationService();
        AppTools.Register(this);
        ElementTools.Register(this, automation);
        InteractionTools.Register(this, automation);
        RawInputTools.Register(this, automation);
        CaptureTools.Register(this, automation);
        SystemTools.Register(this);
        MenuTools.Register(this);
        FlowTools.Register(this);
    }

    internal void Register(string name, string description, JsonObject schema, Handler handler, bool readOnly = false, bool destructive = false)
        => tools[name] = new Definition(name, description, schema, handler, readOnly, destructive);

    internal JsonArray ListTools()
    {
        var result = new JsonArray();
        foreach (var tool in tools.Values.OrderBy(t => t.Name))
        {
            var annotations = new JsonObject
            {
                ["openWorldHint"] = false,
                ["destructiveHint"] = tool.Destructive
            };
            if (tool.ReadOnly) annotations["readOnlyHint"] = true;
            result.Add(new JsonObject
            {
                ["name"] = tool.Name,
                ["description"] = tool.Description,
                ["inputSchema"] = tool.Schema.DeepClone(),
                ["annotations"] = annotations
            });
        }
        return result;
    }

    internal JsonObject Call(string name, JsonObject arguments)
        => tools.TryGetValue(name, out var tool) ? tool.Call(arguments) : ToolResult.Error($"Unknown tool: {name}");
}
