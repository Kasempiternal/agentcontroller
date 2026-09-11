using System.Text.Json.Nodes;
using AgentController.Windows.Backends;
using AgentController.Windows.Protocol;
using AgentController.Windows.Routing;

namespace AgentController.Windows.Tools;

internal static class BackendRouter
{
    private static readonly Dictionary<string, JsonObject> Handles = new(StringComparer.Ordinal);
    private static int seq;

    internal static JsonObject? TryDispatch(string name, JsonObject arguments)
    {
        if (arguments["elementId"]?.GetValue<string>() is { } handleId && Handles.TryGetValue(handleId, out var handle))
        {
            try { return PerformHandle(name, arguments, handle); }
            catch (Exception ex) { return ToolResult.Error(ex.Message); }
        }
        if (!CapabilityRecord.RoutableTools.Contains(name)) return null;
        var identity = TargetIdentity.From(arguments);
        if (identity is null) return null;
        var capability = CapabilityProbe.Probe(identity);
        if (identity.Kind == IdentityKind.Url && capability.Backend != "cdp")
            return ToolResult.Error(capability.AskDetail ?? capability.Reason);
        if (identity.Kind == IdentityKind.IosSimulator)
            return ToolResult.Error(capability.AskDetail ?? capability.Reason);
        if (!capability.Handles(name)) return null;
        try { return Perform(name, arguments, identity, capability); }
        catch (Exception ex)
        {
            return identity.Kind is IdentityKind.Url or IdentityKind.IosSimulator
                ? ToolResult.Error(ex.Message) : null;
        }
    }

    private static List<string> Store(IReadOnlyList<JsonObject> refs)
    {
        var ids = new List<string>(refs.Count);
        foreach (var item in refs)
        {
            seq++;
            var id = $"e{seq}";
            Handles[id] = item;
            ids.Add(id);
        }
        return ids;
    }

    private static JsonObject PerformHandle(string name, JsonObject arguments, JsonObject handle)
    {
        var kind = handle["kind"]?.GetValue<string>();
        if (kind == "cdp")
        {
            var client = WebCdpBackend.EnsureSession(handle["sessionKey"]?.GetValue<string>());
            var backendId = handle["backendNodeId"]?.GetValue<int>() ?? 0;
            if (name is "click" or "double_click")
            {
                WebCdpBackend.Click(client, backendId);
                if (name == "double_click") WebCdpBackend.Click(client, backendId);
                return ToolResult.Json(new JsonObject { ["success"] = true, ["method"] = "cdp-click" });
            }
            if (name == "type_text")
            {
                var text = arguments["text"]?.GetValue<string>() ?? throw new InvalidOperationException("Missing text.");
                WebCdpBackend.TypeText(client, backendId, text);
                return ToolResult.Json(new JsonObject { ["success"] = true, ["method"] = "cdp-type" });
            }
        }
        if (kind == "blender")
        {
            var endpoints = BlenderBackend.Handshake();
            if (endpoints.Count != 1) return ToolResult.Error("Blender socket not uniquely available");
            if (CodeExecConsent.Require(arguments, "bpy", "Python inside Blender") is { } denied) return denied;
            var objectName = (handle["name"]?.GetValue<string>() ?? "").Replace("\\", "\\\\").Replace("'", "\\'");
            var code = $"import bpy\nobj=bpy.data.objects.get('{objectName}')\nresult={{'selected': False}}\nif obj:\n    bpy.context.view_layer.objects.active=obj\n    obj.select_set(True)\n    result={{'selected': True, 'name': obj.name}}\n";
            var result = BlenderBackend.Execute(endpoints[0], code);
            return ToolResult.Json(new JsonObject { ["backend"] = endpoints[0].Kind, ["result"] = result.DeepClone(), ["method"] = "bpy-select" });
        }
        return ToolResult.Error($"Unknown routed handle kind {kind}");
    }

    private static JsonObject Perform(string name, JsonObject arguments, TargetIdentity identity, CapabilityRecord capability)
    {
        if (capability.Backend == "cdp") return PerformCdp(name, arguments, identity);
        if (capability.Backend is "bpy-lab" or "bpy-ws") return PerformBlender(name, arguments, capability);
        return ToolResult.Error($"Router asked to handle {capability.Backend}");
    }

    private static JsonObject PerformCdp(string name, JsonObject arguments, TargetIdentity identity)
    {
        var url = identity.Url ?? identity.Raw;
        if (name is "snapshot" or "describe_screen")
        {
            var interactive = !string.Equals(arguments["mode"]?.GetValue<string>(), "all", StringComparison.OrdinalIgnoreCase);
            var refs = WebCdpBackend.Snapshot(url, interactive);
            var ids = Store(refs);
            var elements = new JsonArray();
            for (var i = 0; i < ids.Count; i++)
            {
                var item = new JsonObject
                {
                    ["id"] = ids[i],
                    ["role"] = refs[i]["role"]?.DeepClone() ?? "generic",
                    ["enabled"] = true
                };
                if (refs[i]["label"]?.GetValue<string>() is { Length: > 0 } label) item["label"] = label;
                elements.Add(item);
            }
            return ToolResult.Json(new JsonObject { ["backend"] = "cdp", ["count"] = elements.Count, ["elements"] = elements });
        }
        if (name == "run_app_code")
        {
            var code = arguments["code"]?.GetValue<string>() ?? throw new InvalidOperationException("Missing code.");
            if (CodeExecConsent.Require(arguments, "cdp", "JavaScript inside the page") is { } denied) return denied;
            var result = WebCdpBackend.Evaluate(url, code);
            return ToolResult.Json(new JsonObject { ["backend"] = "cdp", ["result"] = result.DeepClone() });
        }
        if (name is "screenshot_window" or "screenshot_element" or "screenshot_screen")
            return ToolResult.Image(WebCdpBackend.Screenshot(url), "image/jpeg");
        if (name == "open_url")
        {
            WebCdpBackend.EnsureSession(url);
            return ToolResult.Json(new JsonObject { ["backend"] = "cdp", ["url"] = url });
        }
        throw new InvalidOperationException($"CDP routing for {name} is not implemented");
    }

    private static JsonObject PerformBlender(string name, JsonObject arguments, CapabilityRecord capability)
    {
        var endpoints = BlenderBackend.Handshake();
        if (endpoints.Count != 1) return ToolResult.Error(capability.AskDetail ?? "Blender socket unavailable");
        var endpoint = endpoints[0];
        if (name is "snapshot" or "describe_screen")
        {
            var objects = BlenderBackend.SceneObjects(endpoint);
            var refs = objects.Select(item => new JsonObject { ["kind"] = "blender", ["name"] = item["name"]?.DeepClone(), ["role"] = item["type"]?.DeepClone() ?? "OBJECT" }).ToList();
            var ids = Store(refs);
            var elements = new JsonArray();
            for (var i = 0; i < ids.Count; i++)
                elements.Add(new JsonObject { ["id"] = ids[i], ["role"] = refs[i]["role"]?.DeepClone(), ["label"] = refs[i]["name"]?.DeepClone(), ["enabled"] = true });
            return ToolResult.Json(new JsonObject { ["backend"] = endpoint.Kind, ["count"] = elements.Count, ["elements"] = elements });
        }
        if (name == "run_app_code")
        {
            var code = arguments["code"]?.GetValue<string>() ?? throw new InvalidOperationException("Missing code.");
            if (CodeExecConsent.Require(arguments, "bpy", "Python inside Blender") is { } denied) return denied;
            var result = BlenderBackend.Execute(endpoint, code);
            return ToolResult.Json(new JsonObject { ["backend"] = endpoint.Kind, ["result"] = result.DeepClone() });
        }
        throw new InvalidOperationException($"Blender routing for {name} is not implemented");
    }
}
