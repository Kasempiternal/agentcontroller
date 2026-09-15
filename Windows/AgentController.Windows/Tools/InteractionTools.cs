using System.Text.Json.Nodes;
using System.Windows.Automation;
using AgentController.Windows.Automation;
using AgentController.Windows.Protocol;

namespace AgentController.Windows.Tools;

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

        // The escape hatch. Deliberately speaks UI Automation's own vocabulary rather
        // than a portable one invented on top: the whole value of an escape hatch is
        // reaching what the platform actually exposes, and a translation layer would put
        // back exactly the ceiling it exists to remove. Discovery mode is what keeps it
        // usable — ask the element what it supports, then ask for one of those.
        var actionProperties = ToolSchema.SelectorProperties();
        actionProperties["action"] = ToolSchema.String("UI Automation pattern action (e.g. 'Invoke', 'Toggle', 'Expand', 'Collapse', 'Select', 'Increment', 'Decrement'). Omit to list what this element supports.");
        registry.Register("perform_action", "Escape hatch: perform ANY UI Automation pattern action a control exposes, not just the ones with a dedicated tool. Call it WITHOUT `action` first to discover what the element supports — it returns the action list with a short gloss for each, plus the element's control type and current value. The action vocabulary is the platform's own and is NOT portable across backends. Runs through UI Automation, so it does not move the pointer or change focus.", ToolSchema.Object(actionProperties, "app"), args =>
        {
            var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
            var available = SupportedActions(element);
            var controlType = element.Current.ControlType.ProgrammaticName;

            if (args["action"] is null)
            {
                var listed = new JsonArray();
                foreach (var name in available)
                    listed.Add(new JsonObject { ["name"] = name, ["does"] = ActionGloss(name) });
                var discovery = new JsonObject
                {
                    ["controlType"] = controlType,
                    ["enabled"] = element.Current.IsEnabled,
                    ["actions"] = listed
                };
                if (available.Count == 0)
                    discovery["note"] = "This element exposes no actionable UI Automation patterns. Try its parent, which often carries the patterns its children do not.";
                return ToolResult.Json(discovery);
            }

            var action = AppTools.Required(args, "action");
            if (!available.Contains(action))
            {
                var hint = available.Count == 0
                    ? "it exposes none at all"
                    : $"it exposes: {string.Join(", ", available)}";
                throw new InvalidOperationException(
                    $"{controlType} does not support '{action}' — {hint}. Call perform_action without `action` for the full list with descriptions.");
            }
            if (!element.Current.IsEnabled)
            {
                throw new InvalidOperationException(
                    $"{controlType} is disabled, so '{action}' would have been a no-op. Satisfy whatever the control requires first, then retry.");
            }

            PerformAction(element, action);
            return ToolResult.Json(new JsonObject
            {
                ["success"] = true,
                ["method"] = "uia-pattern",
                ["action"] = action,
                ["controlType"] = controlType
            });
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

    /// The pattern actions this element can actually perform right now. Read off the
    /// element's own IsXxxPatternAvailable properties rather than a fixed list, so a
    /// control that supports something unusual still shows it.
    private static List<string> SupportedActions(AutomationElement element)
    {
        var actions = new List<string>();
        if (element.TryGetCurrentPattern(InvokePattern.Pattern, out _)) actions.Add("Invoke");
        if (element.TryGetCurrentPattern(TogglePattern.Pattern, out _)) actions.Add("Toggle");
        if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out _))
        {
            actions.Add("Select");
            actions.Add("AddToSelection");
            actions.Add("RemoveFromSelection");
        }
        if (element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out _))
        {
            actions.Add("Expand");
            actions.Add("Collapse");
        }
        if (element.TryGetCurrentPattern(RangeValuePattern.Pattern, out _))
        {
            actions.Add("Increment");
            actions.Add("Decrement");
        }
        if (element.TryGetCurrentPattern(ScrollItemPattern.Pattern, out _)) actions.Add("ScrollIntoView");
        if (element.TryGetCurrentPattern(WindowPattern.Pattern, out _)) actions.Add("Close");
        return actions;
    }

    /// Plain language for a pattern name, so discovery is usable without already knowing
    /// UI Automation. Unknown names never reach here — `SupportedActions` is the only
    /// source of the strings this switch sees.
    private static string ActionGloss(string action) => action switch
    {
        "Invoke" => "activate it, the way a click would",
        "Toggle" => "flip its checked state",
        "Select" => "select this item, replacing the current selection",
        "AddToSelection" => "add this item to the current selection",
        "RemoveFromSelection" => "remove this item from the current selection",
        "Expand" => "open it (tree nodes, combo boxes, menus)",
        "Collapse" => "close it",
        "Increment" => "step the value up (sliders, spinners)",
        "Decrement" => "step the value down (sliders, spinners)",
        "ScrollIntoView" => "scroll its container until it is on screen",
        "Close" => "close the window",
        _ => "app-defined action"
    };

    private static void PerformAction(AutomationElement element, string action)
    {
        switch (action)
        {
            case "Invoke":
                ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
                break;
            case "Toggle":
                ((TogglePattern)element.GetCurrentPattern(TogglePattern.Pattern)).Toggle();
                break;
            case "Select":
                ((SelectionItemPattern)element.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
                break;
            case "AddToSelection":
                ((SelectionItemPattern)element.GetCurrentPattern(SelectionItemPattern.Pattern)).AddToSelection();
                break;
            case "RemoveFromSelection":
                ((SelectionItemPattern)element.GetCurrentPattern(SelectionItemPattern.Pattern)).RemoveFromSelection();
                break;
            case "Expand":
                ((ExpandCollapsePattern)element.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
                break;
            case "Collapse":
                ((ExpandCollapsePattern)element.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Collapse();
                break;
            case "Increment":
            case "Decrement":
            {
                // RangeValuePattern has no step action, so a step is a bounded write:
                // move by SmallChange (falling back to 1% of the range when the provider
                // reports no step) and clamp, which is what the arrow keys do.
                var range = (RangeValuePattern)element.GetCurrentPattern(RangeValuePattern.Pattern);
                var info = range.Current;
                var step = info.SmallChange > 0 ? info.SmallChange : (info.Maximum - info.Minimum) / 100.0;
                var target = action == "Increment" ? info.Value + step : info.Value - step;
                range.SetValue(Math.Clamp(target, info.Minimum, info.Maximum));
                break;
            }
            case "ScrollIntoView":
                ((ScrollItemPattern)element.GetCurrentPattern(ScrollItemPattern.Pattern)).ScrollIntoView();
                break;
            case "Close":
                ((WindowPattern)element.GetCurrentPattern(WindowPattern.Pattern)).Close();
                break;
            default:
                throw new InvalidOperationException($"Unhandled action '{action}'.");
        }
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
