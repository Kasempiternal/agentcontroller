using System.Text.Json.Nodes;
using AgentController.Windows.Automation;
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
            ["stopOnError"] = ToolSchema.Boolean("Stop after the first MCP tool error.", true),
            ["includeNestedMedia"] = ToolSchema.Boolean("Keep nested screenshot/image payloads in step results (default false).", false)
        };
        registry.Register("run_steps", "THE default way to drive a UI: run an ordered list of tool steps in ONE call instead of one call per action.", ToolSchema.Object(runProperties, "steps"),
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
        var includeNestedMedia = UiAutomationService.Bool(args, "includeNestedMedia", false);
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
                ["result"] = CompactStepResult(result, includeNestedMedia)
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

    private static JsonObject CompactStepResult(JsonObject result, bool includeNestedMedia)
    {
        if (includeNestedMedia) return result.DeepClone().AsObject();
        if (result["content"] is not JsonArray content) return result.DeepClone().AsObject();
        var omitted = false;
        var rewritten = new JsonArray();
        foreach (var item in content)
        {
            if (item is JsonObject obj && obj["type"]?.GetValue<string>() == "image")
            {
                omitted = true;
                var data = obj["data"]?.GetValue<string>() ?? "";
                rewritten.Add(new JsonObject
                {
                    ["type"] = "text",
                    ["text"] = new JsonObject
                    {
                        ["omitted"] = true,
                        ["kind"] = "image",
                        ["mimeType"] = obj["mimeType"]?.GetValue<string>() ?? "image",
                        ["approxBytes"] = data.Length * 3 / 4
                    }.ToJsonString()
                });
            }
            else rewritten.Add(item?.DeepClone());
        }
        if (!omitted) return result.DeepClone().AsObject();
        var copy = result.DeepClone().AsObject();
        copy["content"] = rewritten;
        copy["nestedMediaOmitted"] = true;
        return copy;
    }
}
