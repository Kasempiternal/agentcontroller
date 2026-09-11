using System.Diagnostics;
using System.Net.Http;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace AgentController.Windows.Backends;

internal static class WebCdpBackend
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMilliseconds(400) };
    private static Process? ownedProcess;
    private static CdpClient? ownedClient;
    private static string? ownedKey;

    private static readonly HashSet<string> Interactive = new(StringComparer.OrdinalIgnoreCase)
    {
        "button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox",
        "slider", "tab", "menuitem", "switch", "option", "treeitem", "spinbutton", "listbox", "textfield"
    };

    internal static string? FindChromeBinary()
    {
        var env = Environment.GetEnvironmentVariable("AGENTCONTROLLER_CHROME");
        if (env is not null)
            return File.Exists(env) ? env : null;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new[]
        {
            Path.Combine(local, "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft", "Edge", "Application", "msedge.exe"),
        };
        return candidates.FirstOrDefault(File.Exists);
    }

    internal static int? FindDebugPort()
    {
        foreach (var port in new[] { 9222, 9229, 9333 })
            if (ListPages(port).Count > 0) return port;
        return null;
    }

    internal static List<(string Url, string Ws)> ListPages(int port)
    {
        try
        {
            var json = Http.GetStringAsync($"http://127.0.0.1:{port}/json/list").GetAwaiter().GetResult();
            var array = JsonNode.Parse(json) as JsonArray ?? [];
            var pages = new List<(string, string)>();
            foreach (var item in array.OfType<JsonObject>())
            {
                var type = item["type"]?.GetValue<string>();
                var ws = item["webSocketDebuggerUrl"]?.GetValue<string>();
                if (ws is null || type is not ("page" or "webview")) continue;
                pages.Add((item["url"]?.GetValue<string>() ?? "", ws));
            }
            return pages;
        }
        catch { return []; }
    }

    internal static List<JsonObject> Flatten(JsonArray nodes, bool interactiveOnly, string sessionKey)
    {
        var refs = new List<JsonObject>();
        foreach (var node in nodes.OfType<JsonObject>())
        {
            if (node["ignored"]?.GetValue<bool>() == true) continue;
            var role = AxAtom(node["role"]) ?? "generic";
            var name = AxAtom(node["name"]) ?? "";
            if (interactiveOnly && !Interactive.Contains(role)) continue;
            var backend = node["backendDOMNodeId"]?.GetValue<int>() ?? 0;
            if (backend <= 0) continue;
            refs.Add(new JsonObject
            {
                ["kind"] = "cdp",
                ["sessionKey"] = sessionKey,
                ["backendNodeId"] = backend,
                ["role"] = role,
                ["label"] = name
            });
        }
        return refs;
    }

    internal static CdpClient EnsureSession(string? url, bool headless = true)
    {
        if (ownedClient is not null && ownedKey == (url ?? "default")) return ownedClient;
        var pages = new List<(string Url, string Ws)>();
        var port = FindDebugPort();
        if (port is int p) pages = ListPages(p);
        if (pages.Count == 0)
        {
            var binary = FindChromeBinary() ?? throw new InvalidOperationException(
                "No Chromium browser found. Install Chrome/Edge, or launch with --remote-debugging-port=9222.");
            port = Launch(binary, headless);
            pages = ListPages(port);
        }
        if (pages.Count == 0) throw new InvalidOperationException("Chrome launched but no DevTools page target was listed");
        var target = pages[0];
        if (url is not null)
        {
            var match = pages.FirstOrDefault(page => page.Url.StartsWith(url, StringComparison.OrdinalIgnoreCase) || url.StartsWith(page.Url, StringComparison.OrdinalIgnoreCase));
            if (match.Ws is not null) target = match;
        }
        var client = new CdpClient(target.Ws);
        if (url is not null)
        {
            client.Call("Page.navigate", new JsonObject { ["url"] = url });
            Thread.Sleep(300);
        }
        ownedClient = client;
        ownedKey = url ?? "default";
        return client;
    }

    internal static List<JsonObject> Snapshot(string url, bool interactiveOnly)
    {
        var client = EnsureSession(url);
        client.Call("Accessibility.enable");
        var tree = client.Call("Accessibility.getFullAXTree") as JsonObject ?? [];
        var nodes = tree["nodes"] as JsonArray ?? [];
        return Flatten(nodes, interactiveOnly, url);
    }

    internal static void Click(CdpClient client, int backendNodeId)
    {
        var resolved = client.Call("DOM.resolveNode", new JsonObject { ["backendNodeId"] = backendNodeId }) as JsonObject;
        var objectId = resolved?["object"]?["objectId"]?.GetValue<string>()
            ?? throw new InvalidOperationException("DOM.resolveNode did not return an objectId");
        client.Call("Runtime.callFunctionOn", new JsonObject
        {
            ["objectId"] = objectId,
            ["functionDeclaration"] = "function(){ this.click(); if (this.focus) this.focus(); }",
            ["returnByValue"] = true
        });
    }

    internal static void TypeText(CdpClient client, int backendNodeId, string text)
    {
        var resolved = client.Call("DOM.resolveNode", new JsonObject { ["backendNodeId"] = backendNodeId }) as JsonObject;
        var objectId = resolved?["object"]?["objectId"]?.GetValue<string>()
            ?? throw new InvalidOperationException("DOM.resolveNode did not return an objectId");
        client.Call("Runtime.callFunctionOn", new JsonObject
        {
            ["objectId"] = objectId,
            ["functionDeclaration"] = "function(t){ this.focus(); if ('value' in this){ this.value=t; this.dispatchEvent(new Event('input',{bubbles:true})); this.dispatchEvent(new Event('change',{bubbles:true})); } }",
            ["arguments"] = new JsonArray(new JsonObject { ["value"] = text }),
            ["returnByValue"] = true
        });
    }

    internal static JsonNode Evaluate(string url, string expression)
    {
        var client = EnsureSession(url);
        return client.Call("Runtime.evaluate", new JsonObject
        {
            ["expression"] = expression,
            ["returnByValue"] = true,
            ["awaitPromise"] = true
        }) ?? new JsonObject();
    }

    internal static byte[] Screenshot(string url)
    {
        var client = EnsureSession(url);
        var result = client.Call("Page.captureScreenshot", new JsonObject { ["format"] = "jpeg", ["quality"] = 70 }) as JsonObject;
        var data = result?["data"]?.GetValue<string>() ?? throw new InvalidOperationException("no screenshot data");
        return Convert.FromBase64String(data);
    }

    private static int Launch(string binary, bool headless)
    {
        var port = FreePort();
        var profile = Path.Combine(Path.GetTempPath(), "agentcontroller-cdp-profile");
        Directory.CreateDirectory(profile);
        var args = new List<string>
        {
            $"--remote-debugging-port={port}",
            $"--user-data-dir={profile}",
            "--no-first-run",
            "--no-default-browser-check",
            "about:blank"
        };
        if (headless) args.Insert(0, "--headless=new");
        ownedProcess = Process.Start(new ProcessStartInfo(binary, string.Join(" ", args.Select(Quote)))
        {
            UseShellExecute = false,
            CreateNoWindow = true
        });
        for (var i = 0; i < 100 && ListPages(port).Count == 0; i++) Thread.Sleep(50);
        return port;
    }

    private static string Quote(string value) => value.Contains(' ') ? $"\"{value}\"" : value;

    private static int FreePort()
    {
        var listener = new TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static string? AxAtom(JsonNode? value) =>
        value?.GetValue<string>() ?? value?["value"]?.GetValue<string>();
}

internal sealed class CdpClient : IDisposable
{
    private readonly ClientWebSocket ws = new();
    private int nextId = 1;

    internal CdpClient(string url)
    {
        ws.ConnectAsync(new Uri(url), CancellationToken.None).GetAwaiter().GetResult();
        Call("Runtime.enable");
        Call("Page.enable");
    }

    internal JsonNode? Call(string method, JsonObject? parameters = null)
    {
        var id = nextId++;
        var envelope = new JsonObject { ["id"] = id, ["method"] = method, ["params"] = parameters ?? [] };
        var bytes = Encoding.UTF8.GetBytes(envelope.ToJsonString());
        ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None).GetAwaiter().GetResult();
        var deadline = DateTime.UtcNow.AddSeconds(15);
        var buffer = new byte[1 << 20];
        while (DateTime.UtcNow < deadline)
        {
            var result = ws.ReceiveAsync(buffer, CancellationToken.None).GetAwaiter().GetResult();
            var json = JsonNode.Parse(Encoding.UTF8.GetString(buffer, 0, result.Count)) as JsonObject;
            if (json?["id"]?.GetValue<int>() != id) continue;
            if (json["error"] is JsonObject error)
                throw new InvalidOperationException(error["message"]?.GetValue<string>() ?? "CDP error");
            return json["result"];
        }
        throw new TimeoutException(method);
    }

    public void Dispose() => ws.Dispose();
}
