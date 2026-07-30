using System.Text.Json;

namespace AgentController.Windows.Protocol;

internal static class JsonDefaults
{
    public static readonly JsonSerializerOptions Compact = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };
}
