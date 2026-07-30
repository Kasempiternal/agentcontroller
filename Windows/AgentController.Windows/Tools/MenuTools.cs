using System.Text.Json.Nodes;
using System.Windows.Automation;
using AgentController.Windows.Protocol;

namespace AgentController.Windows.Tools;

internal static class MenuTools
{
    internal static void Register(ToolRegistry registry)
    {
        var structureProperties = ToolSchema.AppProperties();
        structureProperties["maxDepth"] = ToolSchema.Integer("Maximum UIA depth inspected.", 12, 1, 30);
        structureProperties["maxItems"] = ToolSchema.Integer("Maximum menu entries returned.", 250, 1, 1000);
        registry.Register("get_menu_structure", "Read accessible MenuBar and MenuItem elements without clicking them.", ToolSchema.Object(structureProperties, "app"), args =>
        {
            var root = Root(args);
            var items = MenuStructure(root,
                UiAutomationService.Int(args, "maxDepth", 12, 1, 30),
                UiAutomationService.Int(args, "maxItems", 250, 1, 1000));
            return ToolResult.Json(new JsonObject { ["count"] = items.Count, ["items"] = items });
        }, readOnly: true);

        var navigateProperties = ToolSchema.AppProperties();
        navigateProperties["menuPath"] = new JsonObject
        {
            ["type"] = "array",
            ["items"] = new JsonObject { ["type"] = "string" },
            ["minItems"] = 1,
            ["description"] = "Accessible menu names from outermost to target item."
        };
        registry.Register("navigate_menu", "Expand and invoke a Windows menu path through UI Automation patterns.", ToolSchema.Object(navigateProperties, "app", "menuPath"), args =>
        {
            var path = args["menuPath"] as JsonArray ?? throw new InvalidOperationException("menuPath must be an array.");
            if (path.Count == 0) throw new InvalidOperationException("menuPath must not be empty.");
            var current = Root(args);
            for (var index = 0; index < path.Count; index++)
            {
                var label = path[index]?.GetValue<string>() ?? throw new InvalidOperationException("menuPath entries must be strings.");
                var condition = new AndCondition(
                    new PropertyCondition(AutomationElement.NameProperty, label, PropertyConditionFlags.IgnoreCase),
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem));
                var item = current.FindFirst(TreeScope.Descendants, condition)
                    ?? throw new InvalidOperationException($"Menu item not found: {label}");
                var isLast = index == path.Count - 1;
                if (!isLast)
                {
                    if (item.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var expandObject) && expandObject is ExpandCollapsePattern expand)
                    {
                        if (expand.Current.ExpandCollapseState != ExpandCollapseState.Expanded) expand.Expand();
                    }
                    else if (item.TryGetCurrentPattern(InvokePattern.Pattern, out var invokeObject) && invokeObject is InvokePattern invoke)
                    {
                        invoke.Invoke();
                    }
                    else throw new InvalidOperationException($"Menu item cannot expand: {label}");
                    Thread.Sleep(100);
                    current = item;
                    continue;
                }

                if (item.TryGetCurrentPattern(InvokePattern.Pattern, out var finalInvoke) && finalInvoke is InvokePattern finalInvoker)
                    finalInvoker.Invoke();
                else if (item.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var selectObject) && selectObject is SelectionItemPattern selection)
                    selection.Select();
                else if (item.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var finalExpand) && finalExpand is ExpandCollapsePattern expander)
                    expander.Expand();
                else throw new InvalidOperationException($"Menu item exposes no actionable pattern: {label}");
            }
            return ToolResult.Json(new JsonObject { ["success"] = true, ["path"] = path.DeepClone(), ["method"] = "uia-menu" });
        });
    }

    private static AutomationElement Root(JsonObject args)
    {
        var automation = new UiAutomationService();
        return automation.RootFor(AppTools.Required(args, "app"), UiAutomationService.Int(args, "windowIndex", 0, 0, 100));
    }

    private static JsonArray MenuStructure(AutomationElement root, int maxDepth, int maxItems)
    {
        var result = new JsonArray();
        var walker = TreeWalker.ControlViewWalker;
        var queue = new Queue<(AutomationElement Element, int Depth, string Path)>();
        queue.Enqueue((root, 0, string.Empty));
        while (queue.Count > 0 && result.Count < maxItems)
        {
            var (element, depth, parentPath) = queue.Dequeue();
            try
            {
                var current = element.Current;
                var role = UiAutomationService.RoleName(current.ControlType);
                var path = string.IsNullOrWhiteSpace(current.Name) ? parentPath :
                    string.IsNullOrWhiteSpace(parentPath) ? current.Name : parentPath + " > " + current.Name;
                if (current.ControlType == ControlType.MenuBar || current.ControlType == ControlType.MenuItem)
                {
                    result.Add(new JsonObject
                    {
                        ["role"] = role,
                        ["title"] = current.Name,
                        ["path"] = path,
                        ["depth"] = depth,
                        ["enabled"] = current.IsEnabled,
                        ["offscreen"] = current.IsOffscreen
                    });
                }
                if (depth >= maxDepth) continue;
                var child = walker.GetFirstChild(element);
                while (child is not null)
                {
                    queue.Enqueue((child, depth + 1, path));
                    child = walker.GetNextSibling(child);
                }
            }
            catch (ElementNotAvailableException) { }
        }
        return result;
    }
}
