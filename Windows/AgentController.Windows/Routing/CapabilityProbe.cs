using System.Net.Sockets;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using AgentController.Windows.Backends;
using AgentController.Windows.Protocol;

namespace AgentController.Windows.Routing;

internal enum IdentityKind { Url, IosSimulator, ProcessId, Application }

internal sealed record TargetIdentity(string Raw, IdentityKind Kind, string? Url = null, int? Pid = null, string? BundleHint = null, string? Udid = null)
{
    internal bool IsHttp => Url is not null && (Url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
        || Url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
        || Url.StartsWith("file://", StringComparison.OrdinalIgnoreCase)
        || Url.StartsWith("about:", StringComparison.OrdinalIgnoreCase));

    internal static TargetIdentity Parse(string raw)
    {
        var trimmed = raw.Trim();
        if (ParseUrl(trimmed) is { } url) return new(trimmed, IdentityKind.Url, Url: url);
        if (ParseUdid(trimmed) is { } udid) return new(trimmed, IdentityKind.IosSimulator, Udid: udid);
        if (int.TryParse(trimmed, out var pid) && pid > 0) return new(trimmed, IdentityKind.ProcessId, Pid: pid);
        return new(trimmed, IdentityKind.Application, BundleHint: trimmed);
    }

    internal static TargetIdentity? From(JsonObject args)
    {
        if (args["url"]?.GetValue<string>() is { } url && ParseUrl(url) is not null)
            return Parse(url);
        if (args["udid"]?.GetValue<string>() is { } udid && ParseUdid(udid) is not null)
            return Parse(udid);
        foreach (var key in new[] { "app", "target", "bundleId" })
        {
            if (args[key]?.GetValue<string>() is { Length: > 0 } value)
                return Parse(value);
        }
        return null;
    }

    internal static string? ParseUrl(string raw)
    {
        var lowered = raw.ToLowerInvariant();
        return lowered.StartsWith("http://") || lowered.StartsWith("https://")
            || lowered.StartsWith("file://") || lowered.StartsWith("about:") || lowered.StartsWith("data:")
            ? raw : null;
    }

    internal static string? ParseUdid(string raw)
    {
        var value = raw.StartsWith("sim:", StringComparison.OrdinalIgnoreCase) ? raw[4..] : raw;
        if (value.Equals("booted", StringComparison.OrdinalIgnoreCase)) return "booted";
        var compact = value.Replace("-", "");
        return Regex.IsMatch(compact, "^[0-9A-Fa-f]+$") && compact.Length is 32 or 40 ? value : null;
    }
}

internal sealed class CapabilityRecord
{
    internal static readonly HashSet<string> RoutableTools = new(StringComparer.Ordinal)
    {
        "snapshot", "describe_screen", "click", "double_click", "right_click", "type_text",
        "read_text", "read_all_text", "assert_visible", "assert_not_visible", "assert_value",
        "wait_for_element", "find_elements", "get_element_tree", "get_element_attributes",
        "get_focused_element", "screenshot_window", "screenshot_element", "scroll",
        "scroll_until_visible", "swipe", "drag_drop", "send_shortcut", "open_url", "run_app_code"
    };

    internal required string Target { get; set; }
    internal required string Backend { get; set; }
    internal required string Reason { get; set; }
    internal string Fallback { get; set; } = "ax";
    internal string? Endpoint { get; set; }
    internal string? Protocol { get; set; }
    internal bool Headless { get; set; }
    internal string? Ask { get; set; }
    internal string? AskDetail { get; set; }
    internal JsonArray Candidates { get; set; } = new();
    internal JsonObject Extras { get; set; } = new();

    internal bool Handles(string tool) => Backend is not "ax" and not "hid" && RoutableTools.Contains(tool);

    internal JsonObject ToJson()
    {
        var payload = new JsonObject
        {
            ["target"] = Target,
            ["backend"] = Backend,
            ["fallback"] = Fallback,
            ["reason"] = Reason,
            ["headless"] = Headless
        };
        if (Endpoint is not null) payload["endpoint"] = Endpoint;
        if (Protocol is not null) payload["protocol"] = Protocol;
        if (Ask is not null) payload["ask"] = Ask;
        if (AskDetail is not null) payload["askDetail"] = AskDetail;
        if (Candidates.Count > 0) payload["candidates"] = Candidates.DeepClone();
        foreach (var kv in Extras) payload[kv.Key] = kv.Value?.DeepClone();
        return payload;
    }
}

internal static class CapabilityProbe
{
    private static readonly HashSet<string> Chromium = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome", "google chrome", "chromium", "msedge", "microsoft edge", "brave", "chrome.exe", "msedge.exe"
    };
    private static readonly HashSet<string> Browsers = new(Chromium, StringComparer.OrdinalIgnoreCase) { "firefox", "safari" };
    private static readonly HashSet<string> Blender = new(StringComparer.OrdinalIgnoreCase)
    {
        "blender", "blender.exe", "org.blenderfoundation.blender"
    };

    internal static CapabilityRecord Classify(TargetIdentity identity)
    {
        if (identity.Kind == IdentityKind.Url && identity.IsHttp)
            return new() { Target = identity.Raw, Backend = "cdp", Reason = "URL identity — CDP compact a11y refs.", Headless = true };
        if (identity.Kind == IdentityKind.IosSimulator)
            return new() { Target = identity.Raw, Backend = "ios-sim", Reason = "iOS simulator — macOS AgentController only." };
        if (identity.BundleHint is not null && Blender.Contains(identity.BundleHint))
            return new() { Target = identity.Raw, Backend = "bpy-lab", Reason = "Blender identity — bpy if a socket handshakes." };
        if (identity.BundleHint is not null && Chromium.Contains(identity.BundleHint))
            return new() { Target = identity.Raw, Backend = "cdp", Reason = "Chromium-family browser — CDP when a debug port is reachable." };
        if (identity.BundleHint is not null && Browsers.Contains(identity.BundleHint))
            return new() { Target = identity.Raw, Backend = "ax", Reason = "Browser without CDP attach — UI Automation of the window." };
        return new() { Target = identity.Raw, Backend = "ax", Reason = "Native app — UI Automation; HID/focus only as escape hatch." };
    }

    internal static CapabilityRecord Probe(TargetIdentity identity)
    {
        var record = Classify(identity);
        if (record.Backend == "cdp") return ProbeCdp(identity, record);
        if (record.Backend is "bpy-lab" or "bpy-ws") return ProbeBlender(record);
        if (record.Backend == "ios-sim")
        {
            record.Backend = "ax";
            record.Ask = "missing-addon";
            record.AskDetail = "iOS simulator control is implemented on the macOS AgentController server.";
            record.Reason = "ax-fallback: iOS sim routing is macOS-only";
        }
        return record;
    }

    private static CapabilityRecord ProbeCdp(TargetIdentity identity, CapabilityRecord record)
    {
        var binary = WebCdpBackend.FindChromeBinary();
        if (binary is not null) record.Extras["chromeBinary"] = binary;
        var port = WebCdpBackend.FindDebugPort();
        if (port is int p)
        {
            record.Endpoint = $"127.0.0.1:{p}";
            record.Protocol = "cdp";
            record.Headless = false;
            record.Extras["attached"] = true;
            record.Reason = "Attached to an existing Chrome DevTools port.";
            return record;
        }
        if (identity.Kind == IdentityKind.Url && identity.IsHttp)
        {
            if (binary is null)
            {
                record.Backend = "ax";
                record.Ask = "missing-addon";
                record.AskDetail = "No Chromium browser found. Install Chrome/Edge, or launch with --remote-debugging-port=9222.";
                record.Reason = "URL target but no CDP browser is available.";
                return record;
            }
            record.Headless = true;
            record.Protocol = "cdp";
            record.Extras["available"] = true;
            return record;
        }
        record.Backend = "ax";
        record.Reason = "Chromium without a DevTools port — UI Automation for browser chrome.";
        return record;
    }

    private static CapabilityRecord ProbeBlender(CapabilityRecord record)
    {
        var endpoints = BlenderBackend.Handshake();
        if (endpoints.Count == 0)
        {
            record.Backend = "ax";
            record.Ask = "missing-addon";
            record.AskDetail = "Blender identified but no Lab/community socket answered on 127.0.0.1:9876-9896.";
            record.Reason = "ax-fallback: blender addon not listening";
            return record;
        }
        if (endpoints.Count > 1)
        {
            record.Backend = "ax";
            record.Ask = "multi-instance";
            record.AskDetail = "Multiple Blender sockets answered. Pass a port to pick one.";
            foreach (var ep in endpoints)
                record.Candidates.Add(new JsonObject { ["port"] = ep.Port, ["backend"] = ep.Kind, ["detail"] = ep.Detail });
            return record;
        }
        var hit = endpoints[0];
        record.Backend = hit.Kind;
        record.Endpoint = $"{hit.Host}:{hit.Port}";
        record.Protocol = hit.Kind == "bpy-lab" ? "blender-lab" : "blender-ws";
        record.Reason = "Blender socket handshake succeeded.";
        if (!CodeExecConsent.IsGranted("bpy"))
        {
            record.Ask = "code-exec-consent";
            record.AskDetail = "run_app_code executes Python inside Blender. Pass consent:true once.";
        }
        return record;
    }

    internal static bool PortOpen(string host, int port, int timeoutMs = 200)
    {
        try
        {
            using var client = new TcpClient();
            var task = client.ConnectAsync(host, port);
            return task.Wait(timeoutMs) && client.Connected;
        }
        catch { return false; }
    }
}

internal static class CodeExecConsent
{
    internal static string FilePath()
    {
        var overridePath = Environment.GetEnvironmentVariable("AGENTCONTROLLER_CONSENT_PATH");
        if (!string.IsNullOrEmpty(overridePath)) return overridePath;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AgentController", "code-exec-consent.json");
    }

    internal static bool IsGranted(string backend)
    {
        try
        {
            var json = JsonNode.Parse(File.ReadAllText(FilePath())) as JsonObject;
            var granted = json?["granted"] as JsonArray;
            return granted?.Any(item => item?.GetValue<string>() == backend) == true;
        }
        catch { return false; }
    }

    internal static void Grant(string backend)
    {
        var path = FilePath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var granted = new HashSet<string>(StringComparer.Ordinal);
        if (IsGranted(backend)) granted.Add(backend);
        try
        {
            if (JsonNode.Parse(File.ReadAllText(path))?["granted"] is JsonArray existing)
                foreach (var item in existing)
                    if (item?.GetValue<string>() is { } value) granted.Add(value);
        }
        catch { /* first write */ }
        granted.Add(backend);
        File.WriteAllText(path, new JsonObject { ["granted"] = new JsonArray(granted.OrderBy(v => v).Select(v => (JsonNode?)v).ToArray()) }.ToJsonString());
    }

    internal static JsonObject? Require(JsonObject args, string backend, string detail)
    {
        if (IsGranted(backend)) return null;
        if (args["consent"]?.GetValue<bool>() == true)
        {
            Grant(backend);
            return null;
        }
        return ToolResult.Error($"Code execution ({detail}) requires consent:true once per machine. This runs inside the target app.");
    }
}
