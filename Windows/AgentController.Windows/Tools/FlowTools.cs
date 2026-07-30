using System.Text.Json.Nodes;
using AgentController.Windows.Protocol;

namespace AgentController.Windows.Tools;

internal static class FlowTools
{
    private static readonly string FlowDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentController", "flows");

    internal static void Register(ToolRegistry registry)
    {
        var runProperties = new JsonObject
        {
            ["steps"] = new JsonObject { ["type"] = "array", ["description"] = "Array of {tool, arguments} MCP tool calls." },
            ["stopOnError"] = ToolSchema.Boolean("Stop after the first MCP tool error.", true)
        };
        registry.Register("run_steps", "Run a sequence of AgentController tool calls in order.", ToolSchema.Object(runProperties, "steps"),
            args => RunSteps(registry, args));

        var saveProperties = new JsonObject
        {
            ["name"] = ToolSchema.String("Flow name; letters, numbers, dash, underscore, and spaces are accepted."),
            ["steps"] = new JsonObject { ["type"] = "array", ["description"] = "Array of {tool, arguments} MCP tool calls." }
        };
        registry.Register("save_flow", "Save a reusable flow under the current Windows user profile.", ToolSchema.Object(saveProperties, "name", "steps"), args =>
        {
            var name = Sanitize(AppTools.Required(args, "name"));
            var steps = args["steps"] as JsonArray ?? throw new InvalidOperationException("steps must be an array.");
            Directory.CreateDirectory(FlowDirectory);
            var path = Path.Combine(FlowDirectory, name + ".json");
            File.WriteAllText(path, new JsonObject { ["name"] = name, ["steps"] = steps.DeepClone() }.ToJsonString());
            return ToolResult.Json(new JsonObject { ["saved"] = true, ["name"] = name, ["path"] = path });
        });

        registry.Register("list_flows", "List saved Windows AgentController flows.", ToolSchema.Empty(), _ =>
        {
            Directory.CreateDirectory(FlowDirectory);
            var flows = new JsonArray(Directory.EnumerateFiles(FlowDirectory, "*.json")
                .Select(path => (JsonNode?)Path.GetFileNameWithoutExtension(path)).ToArray());
            return ToolResult.Json(new JsonObject { ["flows"] = flows });
        }, readOnly: true);

        var runSavedProperties = new JsonObject
        {
            ["name"] = ToolSchema.String("Saved flow name."),
            ["stopOnError"] = ToolSchema.Boolean("Stop after the first MCP tool error.", true)
        };
        registry.Register("run_saved_flow", "Run a previously saved Windows AgentController flow.", ToolSchema.Object(runSavedProperties, "name"), args =>
        {
            var name = Sanitize(AppTools.Required(args, "name"));
            var path = Path.Combine(FlowDirectory, name + ".json");
            if (!File.Exists(path)) return ToolResult.Error($"Flow not found: {name}");
            var saved = JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? throw new InvalidOperationException("Saved flow is invalid JSON.");
            var runArgs = new JsonObject
            {
                ["steps"] = saved["steps"]?.DeepClone(),
                ["stopOnError"] = UiAutomationService.Bool(args, "stopOnError", true)
            };
            return RunSteps(registry, runArgs);
        });
    }

    private static JsonObject RunSteps(ToolRegistry registry, JsonObject args)
    {
        var steps = args["steps"] as JsonArray ?? throw new InvalidOperationException("steps must be an array.");
        var stopOnError = UiAutomationService.Bool(args, "stopOnError", true);
        var results = new JsonArray();
        var passed = 0;
        for (var index = 0; index < steps.Count; index++)
        {
            var step = steps[index] as JsonObject ?? throw new InvalidOperationException($"Step {index} must be an object.");
            var name = UiAutomationService.String(step, "tool") ?? UiAutomationService.String(step, "name")
                ?? throw new InvalidOperationException($"Step {index} is missing tool.");
            if (name is "run_steps" or "run_saved_flow")
                return ToolResult.Error("Recursive flow execution is not allowed.");
            var arguments = (step["arguments"] ?? step["args"]) as JsonObject ?? new JsonObject();
            JsonObject result;
            try { result = registry.Call(name, arguments); }
            catch (Exception ex) { result = ToolResult.Error($"{name}: {ex.Message}"); }
            var isError = result["isError"]?.GetValue<bool>() == true;
            if (!isError) passed++;
            results.Add(new JsonObject
            {
                ["index"] = index,
                ["tool"] = name,
                ["isError"] = isError,
                ["result"] = result.DeepClone()
            });
            if (isError && stopOnError) break;
        }
        return ToolResult.Json(new JsonObject
        {
            ["passed"] = passed,
            ["executed"] = results.Count,
            ["total"] = steps.Count,
            ["results"] = results
        });
    }

    private static string Sanitize(string name)
    {
        var filtered = new string(name.Where(character => char.IsLetterOrDigit(character) || character is '-' or '_' or ' ').ToArray()).Trim();
        if (string.IsNullOrWhiteSpace(filtered)) throw new InvalidOperationException("Flow name has no valid characters.");
        return filtered;
    }
}
