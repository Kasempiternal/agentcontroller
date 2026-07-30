using System.Text.Json.Nodes;

namespace AgentController.Windows.Tools;

internal static class ToolSchema
{
    internal static JsonObject Empty() => Object(new JsonObject());

    internal static JsonObject Object(JsonObject properties, params string[] required)
    {
        var schema = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = properties.DeepClone(),
            ["additionalProperties"] = false
        };
        if (required.Length > 0)
            schema["required"] = new JsonArray(required.Select(v => (JsonNode?)v).ToArray());
        return schema;
    }

    internal static JsonObject String(string description) => new() { ["type"] = "string", ["description"] = description };
    internal static JsonObject Boolean(string description, bool? defaultValue = null)
    {
        var value = new JsonObject { ["type"] = "boolean", ["description"] = description };
        if (defaultValue is not null) value["default"] = defaultValue.Value;
        return value;
    }
    internal static JsonObject Integer(string description, int? defaultValue = null, int? minimum = null, int? maximum = null)
    {
        var value = new JsonObject { ["type"] = "integer", ["description"] = description };
        if (defaultValue is not null) value["default"] = defaultValue.Value;
        if (minimum is not null) value["minimum"] = minimum.Value;
        if (maximum is not null) value["maximum"] = maximum.Value;
        return value;
    }
    internal static JsonObject Number(string description) => new() { ["type"] = "number", ["description"] = description };

    internal static JsonObject AppProperties() => new()
    {
        ["app"] = String("Process name, executable path/name, window title, or PID."),
        ["windowIndex"] = Integer("Zero-based top-level window index.", 0, 0, 100)
    };

    internal static JsonObject SelectorProperties()
    {
        var properties = AppProperties();
        properties["elementId"] = String("Stable element handle returned by snapshot or find_elements.");
        properties["role"] = String("Windows control type such as Button/Edit/Text, or a compatible AX role such as AXButton.");
        properties["title"] = String("Exact accessible Name/title.");
        properties["titleContains"] = String("Case-insensitive substring of accessible Name/title.");
        properties["identifier"] = String("Exact Windows AutomationId.");
        properties["value"] = String("Exact accessible value converted to text.");
        properties["description"] = String("Exact HelpText/description.");
        properties["descriptionContains"] = String("Case-insensitive HelpText substring.");
        properties["labelContains"] = String("Case-insensitive substring across Name, HelpText, AutomationId, and value.");
        properties["index"] = Integer("Zero-based index among selector matches.", null, 0, 5000);
        properties["maxDepth"] = Integer("Maximum UI Automation tree depth.", 12, 0, 30);
        properties["maxResults"] = Integer("Maximum matches.", 20, 1, 500);
        return properties;
    }
}
