using System.Diagnostics;
using System.Text.Json.Nodes;
using Deskestro.Windows.Automation;
using Deskestro.Windows.Protocol;

namespace Deskestro.Windows.Tools;

internal static class ElementTools
{
    internal static void Register(ToolRegistry registry, UiAutomationService automation)
    {
        var snapshotProperties = ToolSchema.AppProperties();
        snapshotProperties["maxDepth"] = ToolSchema.Integer("Maximum UI Automation tree depth.", 12, 0, 30);
        snapshotProperties["maxElements"] = ToolSchema.Integer("Maximum elements returned.", 250, 1, 2000);
        var snapshotSchema = ToolSchema.Object(snapshotProperties, "app");
        registry.Register("snapshot", "Return a compact Windows UI Automation snapshot with stable element IDs.", snapshotSchema,
            args => ToolResult.Json(automation.Snapshot(AppTools.Required(args, "app"), Depth(args), MaxElements(args), Window(args))), readOnly: true);
        registry.Register("describe_screen", "Alias of snapshot for cross-platform Deskestro compatibility.", snapshotSchema,
            args => ToolResult.Json(automation.Snapshot(AppTools.Required(args, "app"), Depth(args), MaxElements(args), Window(args))), readOnly: true);

        var treeProperties = ToolSchema.AppProperties();
        treeProperties["maxDepth"] = ToolSchema.Integer("Maximum UI Automation tree depth.", 12, 0, 30);
        treeProperties["maxElements"] = ToolSchema.Integer("Maximum elements returned.", 1000, 1, 5000);
        registry.Register("get_element_tree", "Return the target window's UI Automation tree as a flat depth-annotated list.", ToolSchema.Object(treeProperties, "app"),
            args => ToolResult.Json(automation.Snapshot(AppTools.Required(args, "app"), Depth(args), UiAutomationService.Int(args, "maxElements", 1000, 1, 5000), Window(args))), readOnly: true);

        registry.Register("find_elements", "Find UI Automation elements using Deskestro-compatible selectors.", ToolSchema.Object(ToolSchema.SelectorProperties(), "app"), args =>
        {
            var matches = automation.Find(AppTools.Required(args, "app"), args, Window(args));
            return ToolResult.Json(new JsonObject { ["count"] = matches.Count, ["elements"] = matches });
        }, readOnly: true);

        registry.Register("get_element_attributes", "Return current properties and supported patterns for one UI element.", ToolSchema.Object(ToolSchema.SelectorProperties(), "app"), args =>
        {
            var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
            return ToolResult.Json(automation.Describe(element, UiAutomationService.String(args, "elementId")));
        }, readOnly: true);

        registry.Register("get_focused_element", "Return the focused UI Automation element when it belongs to the target app.", ToolSchema.Object(ToolSchema.AppProperties(), "app"),
            args => ToolResult.Json(automation.Focused(AppTools.Required(args, "app"))), readOnly: true);

        var waitProperties = ToolSchema.SelectorProperties();
        waitProperties["timeoutMs"] = ToolSchema.Integer("Maximum wait in milliseconds.", 5000, 0, 60000);
        registry.Register("wait_for_element", "Poll until a matching element exists or the timeout expires.", ToolSchema.Object(waitProperties, "app"), args =>
        {
            var element = WaitFor(automation, args, shouldExist: true);
            return element is null
                ? ToolResult.Error("wait_for_element timed out before a match appeared.")
                : ToolResult.Json(new JsonObject { ["found"] = true, ["element"] = automation.Describe(element) });
        }, readOnly: true);

        registry.Register("assert_visible", "Pass when a matching element becomes available; return MCP isError on timeout.", ToolSchema.Object(waitProperties, "app"), args =>
        {
            var element = WaitFor(automation, args, shouldExist: true);
            return element is null ? ToolResult.Error("assert_visible failed: element did not become visible.") : ToolResult.Json(new JsonObject { ["passed"] = true });
        }, readOnly: true);

        registry.Register("assert_not_visible", "Pass when no matching element is available; return MCP isError on timeout.", ToolSchema.Object(waitProperties, "app"), args =>
        {
            var element = WaitFor(automation, args, shouldExist: false);
            return element is null ? ToolResult.Json(new JsonObject { ["passed"] = true }) : ToolResult.Error("assert_not_visible failed: element remained visible.");
        }, readOnly: true);

        var valueProperties = ToolSchema.SelectorProperties();
        valueProperties["expected"] = ToolSchema.String("Expected value converted to text.");
        valueProperties["timeoutMs"] = ToolSchema.Integer("Maximum wait in milliseconds.", 5000, 0, 60000);
        registry.Register("assert_value", "Poll until an element's Value/Toggle/RangeValue equals expected.", ToolSchema.Object(valueProperties, "app", "expected"), args =>
        {
            var timeout = UiAutomationService.Int(args, "timeoutMs", 5000, 0, 60000);
            var expected = AppTools.Required(args, "expected");
            var stopwatch = Stopwatch.StartNew();
            string? actual = null;
            do
            {
                try
                {
                    var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
                    actual = UiAutomationService.ValueOf(element)?.ToString();
                    if (string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
                        return ToolResult.Json(new JsonObject { ["passed"] = true, ["actual"] = actual });
                }
                catch (InvalidOperationException) { }
                if (stopwatch.ElapsedMilliseconds < timeout) Thread.Sleep(100);
            } while (stopwatch.ElapsedMilliseconds < timeout);
            return ToolResult.Error($"assert_value failed: expected '{expected}', actual '{actual ?? "<missing>"}'.");
        }, readOnly: true);

        registry.Register("read_text", "Read text from TextPattern, ValuePattern, or accessible Name.", ToolSchema.Object(ToolSchema.SelectorProperties(), "app"), args =>
        {
            var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
            var text = automation.ReadText(element);
            return text is null ? ToolResult.Error("Element exposes no readable text.") : ToolResult.Json(new JsonObject { ["text"] = text });
        }, readOnly: true);

        var readAll = ToolSchema.AppProperties();
        readAll["maxElements"] = ToolSchema.Integer("Maximum UI elements inspected.", 500, 1, 5000);
        registry.Register("read_all_text", "Extract unique visible accessible text from the target window.", ToolSchema.Object(readAll, "app"), args =>
        {
            var values = automation.ReadAllText(AppTools.Required(args, "app"), Window(args), UiAutomationService.Int(args, "maxElements", 500, 1, 5000));
            return ToolResult.Json(new JsonObject { ["count"] = values.Count, ["items"] = values });
        }, readOnly: true);
    }

    private static System.Windows.Automation.AutomationElement? WaitFor(UiAutomationService automation, JsonObject args, bool shouldExist)
    {
        var timeout = UiAutomationService.Int(args, "timeoutMs", 5000, 0, 60000);
        var stopwatch = Stopwatch.StartNew();
        do
        {
            try
            {
                var element = automation.ResolveElement(AppTools.Required(args, "app"), args);
                if (shouldExist) return element;
                if (stopwatch.ElapsedMilliseconds >= timeout) return element;
            }
            catch (InvalidOperationException)
            {
                if (!shouldExist) return null;
            }
            if (stopwatch.ElapsedMilliseconds < timeout) Thread.Sleep(100);
        } while (stopwatch.ElapsedMilliseconds < timeout);
        return null;
    }

    private static int Window(JsonObject args) => UiAutomationService.Int(args, "windowIndex", 0, 0, 100);
    private static int Depth(JsonObject args) => UiAutomationService.Int(args, "maxDepth", 12, 0, 30);
    private static int MaxElements(JsonObject args) => UiAutomationService.Int(args, "maxElements", 250, 1, 2000);
}
