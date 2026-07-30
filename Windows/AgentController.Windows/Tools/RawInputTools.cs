using System.Text.Json.Nodes;
using AgentController.Windows.Protocol;

namespace AgentController.Windows.Tools;

internal static class RawInputTools
{
    internal static void Register(ToolRegistry registry, UiAutomationService automation)
    {
        var doubleProperties = PointOrSelectorProperties("Allow a real global double-click and temporary focus change.");
        registry.Register("double_click", "Double-click an element or coordinates. Windows raw input requires explicit foreground:true; focus and cursor are restored afterward.", ToolSchema.Object(doubleProperties, "app"), args =>
        {
            RequireForeground(args, "double_click");
            var app = AppTools.Required(args, "app");
            using var process = AppService.Resolve(app);
            var (x, y) = ResolvePoint(automation, app, args);
            var activated = RawInputService.DoubleClick(process.Id, x, y);
            return Action("foreground-double-click", activated, x, y);
        });

        var rightProperties = PointOrSelectorProperties("Allow a real global right-click and temporary focus change.");
        registry.Register("right_click", "Right-click an element or coordinates. Windows raw input requires explicit foreground:true; focus and cursor are restored afterward.", ToolSchema.Object(rightProperties, "app"), args =>
        {
            RequireForeground(args, "right_click");
            var app = AppTools.Required(args, "app");
            using var process = AppService.Resolve(app);
            var (x, y) = ResolvePoint(automation, app, args);
            var activated = RawInputService.RightClick(process.Id, x, y);
            return Action("foreground-right-click", activated, x, y);
        });

        var shortcutProperties = ToolSchema.AppProperties();
        shortcutProperties["key"] = ToolSchema.String("Key name such as s, return, tab, delete, left, or f5.");
        shortcutProperties["modifiers"] = new JsonObject
        {
            ["type"] = "array",
            ["items"] = new JsonObject { ["type"] = "string" },
            ["description"] = "Modifier keys: ctrl, shift, alt/opt, or win/cmd."
        };
        shortcutProperties["foreground"] = ToolSchema.Boolean("Required on Windows because SendInput is global.", false);
        registry.Register("send_shortcut", "Send a Windows keyboard chord. Requires explicit foreground:true; the previous foreground window is restored afterward.", ToolSchema.Object(shortcutProperties, "app", "key"), args =>
        {
            RequireForeground(args, "send_shortcut");
            using var process = AppService.Resolve(AppTools.Required(args, "app"));
            var modifiers = (args["modifiers"] as JsonArray)?.Select(node => node?.GetValue<string>() ?? string.Empty).ToArray() ?? [];
            var key = AppTools.Required(args, "key");
            var activated = RawInputService.SendShortcut(process.Id, key, modifiers);
            return ToolResult.Json(new JsonObject
            {
                ["success"] = true,
                ["method"] = "foreground-keyboard",
                ["activated"] = activated,
                ["key"] = key,
                ["modifiers"] = new JsonArray(modifiers.Select(value => (JsonNode?)value).ToArray())
            });
        });

        var swipeProperties = ToolSchema.AppProperties();
        swipeProperties["startX"] = ToolSchema.Number("Start X coordinate.");
        swipeProperties["startY"] = ToolSchema.Number("Start Y coordinate.");
        swipeProperties["endX"] = ToolSchema.Number("End X coordinate.");
        swipeProperties["endY"] = ToolSchema.Number("End Y coordinate.");
        swipeProperties["duration"] = ToolSchema.Number("Duration in seconds, from 0.05 to 10. Default 0.3.");
        swipeProperties["foreground"] = ToolSchema.Boolean("Required on Windows because pointer input is global.", false);
        registry.Register("swipe", "Swipe from one screen coordinate to another as a mouse drag. Requires explicit foreground:true; focus and cursor are restored afterward.", ToolSchema.Object(swipeProperties, "app", "startX", "startY", "endX", "endY"), args =>
        {
            RequireForeground(args, "swipe");
            using var process = AppService.Resolve(AppTools.Required(args, "app"));
            var sx = Coordinate(args, "startX");
            var sy = Coordinate(args, "startY");
            var ex = Coordinate(args, "endX");
            var ey = Coordinate(args, "endY");
            var duration = OptionalNumber(args, "duration", 0.3);
            var activated = RawInputService.Drag(process.Id, sx, sy, ex, ey, duration);
            return Gesture("foreground-swipe", activated, sx, sy, ex, ey, duration);
        });

        var dragProperties = ToolSchema.AppProperties();
        dragProperties["fromX"] = ToolSchema.Number("Source X coordinate.");
        dragProperties["fromY"] = ToolSchema.Number("Source Y coordinate.");
        dragProperties["toX"] = ToolSchema.Number("Target X coordinate.");
        dragProperties["toY"] = ToolSchema.Number("Target Y coordinate.");
        dragProperties["duration"] = ToolSchema.Number("Duration in seconds, from 0.05 to 10. Default 0.5.");
        dragProperties["foreground"] = ToolSchema.Boolean("Required on Windows because pointer input is global.", false);
        registry.Register("drag_drop", "Drag from one screen coordinate and drop at another. Requires explicit foreground:true; focus and cursor are restored afterward.", ToolSchema.Object(dragProperties, "app", "fromX", "fromY", "toX", "toY"), args =>
        {
            RequireForeground(args, "drag_drop");
            using var process = AppService.Resolve(AppTools.Required(args, "app"));
            var sx = Coordinate(args, "fromX");
            var sy = Coordinate(args, "fromY");
            var ex = Coordinate(args, "toX");
            var ey = Coordinate(args, "toY");
            var duration = OptionalNumber(args, "duration", 0.5);
            var activated = RawInputService.Drag(process.Id, sx, sy, ex, ey, duration);
            return Gesture("foreground-drag-drop", activated, sx, sy, ex, ey, duration);
        });
    }

    private static JsonObject PointOrSelectorProperties(string foregroundDescription)
    {
        var properties = ToolSchema.SelectorProperties();
        properties["x"] = ToolSchema.Number("Optional screen X coordinate; provide with y instead of an element selector.");
        properties["y"] = ToolSchema.Number("Optional screen Y coordinate; provide with x instead of an element selector.");
        properties["foreground"] = ToolSchema.Boolean(foregroundDescription, false);
        return properties;
    }

    private static (int X, int Y) ResolvePoint(UiAutomationService automation, string app, JsonObject args)
    {
        var hasX = args["x"] is not null;
        var hasY = args["y"] is not null;
        if (hasX != hasY) throw new InvalidOperationException("Provide both x and y, or neither.");
        if (hasX) return (Coordinate(args, "x"), Coordinate(args, "y"));
        var element = automation.ResolveElement(app, args);
        var rect = element.Current.BoundingRectangle;
        if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0) throw new InvalidOperationException("Element has no clickable bounds.");
        return ((int)Math.Round(rect.X + rect.Width / 2), (int)Math.Round(rect.Y + rect.Height / 2));
    }

    private static void RequireForeground(JsonObject args, string tool)
    {
        if (!UiAutomationService.Bool(args, "foreground"))
            throw new InvalidOperationException($"{tool} uses global Windows input and cannot be background-safe. Retry with foreground:true to authorize a temporary focus/cursor change.");
    }

    private static int Coordinate(JsonObject args, string name) => (int)Math.Round(RequiredNumber(args, name));

    private static double RequiredNumber(JsonObject args, string name)
    {
        if (args[name] is JsonValue value)
        {
            if (value.TryGetValue<double>(out var number)) return number;
            if (value.TryGetValue<int>(out var integer)) return integer;
        }
        throw new InvalidOperationException($"Missing {name}.");
    }

    private static double OptionalNumber(JsonObject args, string name, double fallback)
        => args[name] is null ? fallback : RequiredNumber(args, name);

    private static JsonObject Action(string method, bool activated, int x, int y) => ToolResult.Json(new JsonObject
    {
        ["success"] = true,
        ["method"] = method,
        ["activated"] = activated,
        ["x"] = x,
        ["y"] = y
    });

    private static JsonObject Gesture(string method, bool activated, int sx, int sy, int ex, int ey, double duration)
        => ToolResult.Json(new JsonObject
        {
            ["success"] = true,
            ["method"] = method,
            ["activated"] = activated,
            ["from"] = new JsonObject { ["x"] = sx, ["y"] = sy },
            ["to"] = new JsonObject { ["x"] = ex, ["y"] = ey },
            ["duration"] = duration
        });
}
