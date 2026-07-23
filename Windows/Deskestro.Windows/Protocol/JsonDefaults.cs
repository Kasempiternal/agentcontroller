using System.Text.Json;

namespace Deskestro.Windows.Protocol;

internal static class JsonDefaults
{
    public static readonly JsonSerializerOptions Compact = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };
}
