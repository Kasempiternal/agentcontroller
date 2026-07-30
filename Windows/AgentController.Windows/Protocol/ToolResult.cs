using System.Text.Json.Nodes;

namespace AgentController.Windows.Protocol;

internal static class ToolResult
{
    public static JsonObject Json(JsonNode payload) => new()
    {
        ["content"] = new JsonArray(new JsonObject
        {
            ["type"] = "text",
            ["text"] = payload.ToJsonString(JsonDefaults.Compact)
        }),
        ["structuredContent"] = payload.DeepClone(),
        ["isError"] = false
    };

    public static JsonObject Text(string text) => new()
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }),
        ["isError"] = false
    };

    public static JsonObject Error(string message) => new()
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = message }),
        ["isError"] = true
    };

    public static JsonObject Image(byte[] data, string mimeType, JsonObject? metadata = null)
    {
        var content = new JsonArray(new JsonObject
        {
            ["type"] = "image",
            ["data"] = Convert.ToBase64String(data),
            ["mimeType"] = mimeType
        });
        if (metadata is not null)
            content.Add(new JsonObject { ["type"] = "text", ["text"] = metadata.ToJsonString(JsonDefaults.Compact) });
        return new JsonObject { ["content"] = content, ["isError"] = false };
    }
}
