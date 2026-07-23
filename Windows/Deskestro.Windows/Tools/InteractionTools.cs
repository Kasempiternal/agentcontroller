using System.Text.Json.Nodes;
using System.Windows.Automation;
using Deskestro.Windows.Automation;
using Deskestro.Windows.Protocol;

namespace Deskestro.Windows.Tools;

internal static class InteractionTools
{
    internal static void Register(ToolRegistry registry, UiAutomationService automation)
    {
        var clickProperties = ToolSchema.SelectorProperties();
        clickProperties["foreground"] = ToolSchema.Boolean("Allow a focus-changing coordinate fallback when no UIA action pattern exists.", false);
        registry.Register("click", "Activate a control with UI Automation patterns; coordinate fallback requires foreground:true.", ToolSchema.Object(clickProperties, "app"), args =>
        {
            var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
            var method = automation.Invoke(element, UiAutomationService.Bool(args, "foreground"));
            return ToolResult.Json(new JsonObject { ["success"] = true, ["method"] = method });
        });

        var typeProperties = ToolSchema.SelectorProperties();
        typeProperties["text"] = ToolSchema.String("Replacement text for ValuePattern, or typed text for foreground fallback.");
        typeProperties["foreground"] = ToolSchema.Boolean("Allow a focus-changing keyboard fallback when ValuePattern is unavailable.", false);
        registry.Register("type_text", "Set a control's ValuePattern in the background; keyboard fallback requires foreground:true.", ToolSchema.Object(typeProperties, "app", "text"), args =>
        {
            var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
            var method = automation.TypeText(element, AppTools.Required(args, "text"), UiAutomationService.Bool(args, "foreground"));
            return ToolResult.Json(new JsonObject { ["success"] = true, ["method"] = method });
        });

        var scrollProperties = ToolSchema.SelectorProperties();
        scrollProperties["deltaY"] = ToolSchema.Number("Positive scrolls down; negative scrolls up.");
        scrollProperties["amount"] = ToolSchema.Integer("Number of small UIA scroll increments.", 1, 1, 50);
        registry.Register("scroll", "Scroll an accessible container with ScrollPattern without moving the pointer.", ToolSchema.Object(scrollProperties, "app", "deltaY"), args =>
        {
            var app = AppTools.Required(args, "app");
            var element = UiAutomationService.HasSelector(args)
                ? automation.ResolveElement(app, args)
                : automation.RootFor(app, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
            var scrollable = FindScrollable(element) ?? throw new InvalidOperationException("No ScrollPattern container found.");
            var delta = Number(args, "deltaY");
            var amount = UiAutomationService.Int(args, "amount", 1, 1, 50);
            var vertical = delta >= 0 ? ScrollAmount.SmallIncrement : ScrollAmount.SmallDecrement;
            for (var i = 0; i < amount; i++) scrollable.Scroll(ScrollAmount.NoAmount, vertical);
            return ToolResult.Json(new JsonObject { ["success"] = true, ["method"] = "uia-scroll" });
        });

        var scrollUntil = ToolSchema.SelectorProperties();
        scrollUntil["maxScrolls"] = ToolSchema.Integer("Maximum small scroll increments.", 20, 1, 100);
        scrollUntil["direction"] = new JsonObject
        {
            ["type"] = "string",
            ["enum"] = new JsonArray("down", "up"),
            ["default"] = "down"
        };
        registry.Register("scroll_until_visible", "Scroll the target window until a matching element is onscreen.", ToolSchema.Object(scrollUntil, "app"), args =>
        {
            var app = AppTools.Required(args, "app");
            var root = automation.RootFor(app, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
            var scrollable = FindScrollable(root) ?? throw new InvalidOperationException("No ScrollPattern container found.");
            var max = UiAutomationService.Int(args, "maxScrolls", 20, 1, 100);
            var direction = UiAutomationService.String(args, "direction") == "up" ? ScrollAmount.SmallDecrement : ScrollAmount.SmallIncrement;
            for (var i = 0; i <= max; i++)
            {
                var matches = automation.Find(app, args, UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
                if (matches.Count > 0 && matches[0]?["offscreen"]?.GetValue<bool>() == false)
                    return ToolResult.Json(new JsonObject { ["success"] = true, ["scrolls"] = i, ["element"] = matches[0]?.DeepClone() });
                if (i < max) scrollable.Scroll(ScrollAmount.NoAmount, direction);
            }
            return ToolResult.Error($"Element did not become visible after {max} scrolls.");
        });
    }

    private static ScrollPattern? FindScrollable(AutomationElement start)
    {
        if (start.TryGetCurrentPattern(ScrollPattern.Pattern, out var own) && own is ScrollPattern ownPattern)
            return ownPattern;
        var found = start.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.IsScrollPatternAvailableProperty, true));
        if (found is not null && found.TryGetCurrentPattern(ScrollPattern.Pattern, out var nested) && nested is ScrollPattern nestedPattern)
            return nestedPattern;
        return null;
    }

    private static double Number(JsonObject args, string name)
    {
        if (args[name] is JsonValue value)
        {
            if (value.TryGetValue<double>(out var number)) return number;
            if (value.TryGetValue<int>(out var integer)) return integer;
        }
        throw new InvalidOperationException($"Missing {name}.");
    }
}
