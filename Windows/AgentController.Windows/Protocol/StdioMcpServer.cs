using System.Text.Json;
using System.Text.Json.Nodes;
using AgentController.Windows.Tools;

namespace AgentController.Windows.Protocol;

internal sealed class StdioMcpServer(ToolRegistry registry)
{
    private static readonly HashSet<string> SupportedVersions =
    [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18"
    ];

    public void Run()
    {
        string? line;
        while ((line = Console.ReadLine()) is not null)
        {
            line = line.TrimStart((char)0xFEFF);
            if (string.IsNullOrWhiteSpace(line))
                continue;

            JsonObject? response;
            try
            {
                var request = JsonNode.Parse(line) as JsonObject
                    ?? throw new JsonException("Request must be a JSON object.");
                response = Dispatch(request);
            }
            catch (JsonException ex)
            {
                response = Failure(null, -32700, $"Parse error: {ex.Message}");
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"agentcontroller-windows request error: {ex}");
                response = Failure(null, -32603, "Internal error");
            }

            if (response is null)
                continue;

            Console.WriteLine(response.ToJsonString(JsonDefaults.Compact));
            Console.Out.Flush();
        }
    }

    private JsonObject? Dispatch(JsonObject request)
    {
        var id = request["id"]?.DeepClone();
        if (id is null)
            return null;

        var method = request["method"]?.GetValue<string>();
        return method switch
        {
            "initialize" => Success(id, Initialize(request["params"] as JsonObject)),
            "ping" => Success(id, new JsonObject()),
            "tools/list" => Success(id, new JsonObject { ["tools"] = registry.ListTools() }),
            "tools/call" => Success(id, CallTool(request["params"] as JsonObject)),
            _ => Failure(id, -32601, $"Method not found: {method}")
        };
    }

    private static JsonObject Initialize(JsonObject? parameters)
    {
        var requested = parameters?["protocolVersion"]?.GetValue<string>();
        var version = requested is not null && SupportedVersions.Contains(requested)
            ? requested
            : "2025-06-18";

        return new JsonObject
        {
            ["protocolVersion"] = version,
            ["capabilities"] = new JsonObject { ["tools"] = new JsonObject() },
            ["serverInfo"] = new JsonObject
            {
                ["name"] = "agentcontroller-windows",
                ["version"] = "2.2.0"
            },
            ["instructions"] =
                "AgentController Windows drives desktop applications through Windows UI Automation. " +
                "Start with list_apps, then snapshot or find_elements. UI Automation patterns " +
                "are background-safe; raw coordinate and keyboard fallbacks require foreground:true " +
                "and may briefly move focus. Windows UIPI prevents controlling higher-integrity apps."
        };
    }

    private JsonObject CallTool(JsonObject? parameters)
    {
        var name = parameters?["name"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(name))
            return ToolResult.Error("Missing tool name.");

        var arguments = parameters?["arguments"] as JsonObject ?? new JsonObject();
        try
        {
            return registry.Call(name, arguments);
        }
        catch (InvalidOperationException ex)
        {
            return ToolResult.Error($"{name}: {ex.Message}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"agentcontroller-windows tool {name} failed: {ex}");
            return ToolResult.Error($"{name}: {ex.Message}");
        }
    }

    private static JsonObject Success(JsonNode id, JsonNode result) => new()
    {
        ["jsonrpc"] = "2.0",
        ["result"] = result,
        ["id"] = id
    };

    private static JsonObject Failure(JsonNode? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0",
        ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
        ["id"] = id
    };
}
