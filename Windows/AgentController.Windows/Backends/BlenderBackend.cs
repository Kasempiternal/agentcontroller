using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace AgentController.Windows.Backends;

internal sealed record BlenderEndpoint(string Host, int Port, string Kind, string Detail);

internal static class BlenderBackend
{
    private const string PingCode = "result={'agentcontroller': True, 'objects': len(__import__('bpy').data.objects)}";

    internal static byte[] EncodeLab(string code)
    {
        var json = new JsonObject { ["type"] = "execute", ["code"] = code, ["strict_json"] = true }.ToJsonString();
        var bytes = Encoding.UTF8.GetBytes(json);
        var framed = new byte[bytes.Length + 1];
        Buffer.BlockCopy(bytes, 0, framed, 0, bytes.Length);
        return framed;
    }

    internal static JsonObject DecodeLab(byte[] data)
    {
        var end = Array.IndexOf(data, (byte)0);
        var slice = end >= 0 ? data.AsSpan(0, end) : data.AsSpan();
        return JsonNode.Parse(Encoding.UTF8.GetString(slice)) as JsonObject ?? [];
    }

    internal static bool IsLabSuccess(JsonObject value)
    {
        var status = value["status"]?.GetValue<string>()?.ToLowerInvariant();
        return status is "ok" or "success" || value["result"] is not null;
    }

    internal static List<BlenderEndpoint> Handshake()
    {
        var found = new List<BlenderEndpoint>();
        for (var port = 9876; port <= 9896; port++)
        {
            if (ProbeLab(port) is { } lab) { found.Add(lab); continue; }
            if (ProbeWs(port) is { } ws) found.Add(ws);
        }
        return found;
    }

    internal static JsonNode Execute(BlenderEndpoint endpoint, string code)
    {
        if (endpoint.Kind == "bpy-lab")
        {
            var data = RoundTrip(endpoint.Host, endpoint.Port, EncodeLab(code), 8000, untilNull: true);
            return DecodeLab(data);
        }
        using var ws = new ClientWebSocket();
        ws.ConnectAsync(new Uri($"ws://{endpoint.Host}:{endpoint.Port}"), CancellationToken.None).GetAwaiter().GetResult();
        var payload = Encoding.UTF8.GetBytes(new JsonObject
        {
            ["type"] = "execute_code",
            ["params"] = new JsonObject { ["code"] = code }
        }.ToJsonString());
        ws.SendAsync(payload, WebSocketMessageType.Text, true, CancellationToken.None).GetAwaiter().GetResult();
        var buffer = new byte[1 << 16];
        var result = ws.ReceiveAsync(buffer, CancellationToken.None).GetAwaiter().GetResult();
        return JsonNode.Parse(Encoding.UTF8.GetString(buffer, 0, result.Count)) ?? new JsonObject();
    }

    internal static List<JsonObject> SceneObjects(BlenderEndpoint endpoint)
    {
        var raw = Execute(endpoint, "import bpy\nresult=[{'name': o.name, 'type': o.type} for o in bpy.data.objects]");
        var result = raw["result"] ?? raw;
        if (result is JsonArray array)
            return array.OfType<JsonObject>().Where(item => item["name"] is not null).ToList();
        return [];
    }

    private static BlenderEndpoint? ProbeLab(int port)
    {
        try
        {
            var data = RoundTrip("127.0.0.1", port, EncodeLab(PingCode), 250, untilNull: true);
            var decoded = DecodeLab(data);
            return IsLabSuccess(decoded)
                ? new("127.0.0.1", port, "bpy-lab", "Blender Lab MCP (null-terminated JSON)")
                : null;
        }
        catch { return null; }
    }

    private static BlenderEndpoint? ProbeWs(int port)
    {
        try
        {
            using var ws = new ClientWebSocket();
            using var cts = new CancellationTokenSource(250);
            ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}"), cts.Token).GetAwaiter().GetResult();
            var payload = Encoding.UTF8.GetBytes("""{"type":"get_scene_info"}""");
            ws.SendAsync(payload, WebSocketMessageType.Text, true, cts.Token).GetAwaiter().GetResult();
            var buffer = new byte[4096];
            var result = ws.ReceiveAsync(buffer, cts.Token).GetAwaiter().GetResult();
            var text = Encoding.UTF8.GetString(buffer, 0, result.Count);
            if (!text.Contains('{')) return null;
            return new("127.0.0.1", port, "bpy-ws", "Blender community WebSocket");
        }
        catch { return null; }
    }

    private static byte[] RoundTrip(string host, int port, byte[] payload, int timeoutMs, bool untilNull)
    {
        using var client = new System.Net.Sockets.TcpClient();
        var connect = client.ConnectAsync(host, port);
        if (!connect.Wait(timeoutMs) || !client.Connected) throw new TimeoutException();
        using var stream = client.GetStream();
        stream.ReadTimeout = timeoutMs;
        stream.WriteTimeout = timeoutMs;
        stream.Write(payload);
        var buffer = new MemoryStream();
        var chunk = new byte[16384];
        while (true)
        {
            var n = stream.Read(chunk, 0, chunk.Length);
            if (n <= 0) break;
            buffer.Write(chunk, 0, n);
            if (untilNull && buffer.ToArray().Contains((byte)0)) break;
            if (!untilNull) break;
        }
        if (buffer.Length == 0) throw new TimeoutException();
        return buffer.ToArray();
    }
}
