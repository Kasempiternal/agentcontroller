using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Windows.Automation;

namespace AgentController.Windows.Automation;

internal sealed class UiAutomationService
{
    private readonly ConcurrentDictionary<string, AutomationElement> handles = new();
    private int nextHandle;

    internal AutomationElement RootFor(string app, int windowIndex = 0)
    {
        using var process = AppService.Resolve(app);
        var window = AppService.ResolveWindow(process, windowIndex);
        return AutomationElement.FromHandle(window.Handle)
            ?? throw new InvalidOperationException("Windows UI Automation could not attach to the target window.");
    }

    internal JsonObject Snapshot(string app, int maxDepth = 12, int maxElements = 250, int windowIndex = 0)
    {
        handles.Clear();
        nextHandle = 0;
        var root = RootFor(app, windowIndex);
        var elements = new JsonArray();
        foreach (var item in Walk(root, maxDepth, maxElements))
        {
            var id = $"e{Interlocked.Increment(ref nextHandle)}";
            handles[id] = item.Element;
            var json = Describe(item.Element, id);
            json["depth"] = item.Depth;
            elements.Add(json);
        }
        return new JsonObject
        {
            ["app"] = app,
            ["windowIndex"] = windowIndex,
            ["elementCount"] = elements.Count,
            ["elements"] = elements
        };
    }

    internal JsonArray Find(string app, JsonObject criteria, int windowIndex = 0)
    {
        var maxDepth = Int(criteria, "maxDepth", 12, 0, 30);
        var maxResults = Int(criteria, "maxResults", 20, 1, 500);
        var index = NullableInt(criteria, "index");
        if (!HasSelector(criteria))
            throw new InvalidOperationException("At least one selector is required.");

        var root = RootFor(app, windowIndex);
        var matches = new List<AutomationElement>();
        foreach (var item in Walk(root, maxDepth, 10_000))
        {
            if (!Matches(item.Element, criteria)) continue;
            matches.Add(item.Element);
            if (index is null && matches.Count >= maxResults) break;
            if (index is not null && matches.Count > index.Value) break;
        }

        if (index is not null)
            matches = index.Value >= 0 && index.Value < matches.Count ? [matches[index.Value]] : [];

        var result = new JsonArray();
        foreach (var element in matches)
        {
            var id = ExistingOrNewHandle(element);
            result.Add(Describe(element, id));
        }
        return result;
    }

    internal AutomationElement ResolveElement(string app, JsonObject arguments)
    {
        if (arguments["elementId"]?.GetValue<string>() is { Length: > 0 } id && handles.TryGetValue(id, out var stored))
        {
            try { _ = stored.Current.ProcessId; return stored; }
            catch (ElementNotAvailableException) { handles.TryRemove(id, out _); }
        }

        if (!HasSelector(arguments))
            throw new InvalidOperationException("Provide a fresh elementId or at least one selector.");
        var appWindow = Int(arguments, "windowIndex", 0, 0, 100);
        var found = Find(app, arguments, appWindow);
        if (found.Count == 0) throw new InvalidOperationException("Element not found.");
        var foundId = found[0]?["id"]?.GetValue<string>() ?? throw new InvalidOperationException("Element handle missing.");
        return handles[foundId];
    }

    internal JsonObject Describe(AutomationElement element, string? id = null)
    {
        var current = element.Current;
        var rect = current.BoundingRectangle;
        var value = ValueOf(element);
        var role = RoleName(current.ControlType);
        return new JsonObject
        {
            ["id"] = id,
            ["role"] = role,
            ["title"] = EmptyToNull(current.Name),
            ["label"] = EmptyToNull(current.Name) ?? EmptyToNull(current.HelpText),
            ["identifier"] = EmptyToNull(current.AutomationId),
            ["description"] = EmptyToNull(current.HelpText),
            ["className"] = EmptyToNull(current.ClassName),
            ["framework"] = EmptyToNull(current.FrameworkId),
            ["value"] = value,
            ["enabled"] = current.IsEnabled,
            ["focused"] = current.HasKeyboardFocus,
            ["offscreen"] = current.IsOffscreen,
            ["frame"] = RectJson(rect),
            ["patterns"] = new JsonArray(element.GetSupportedPatterns().Select(p => (JsonNode?)p.ProgrammaticName).ToArray())
        };
    }

    internal JsonObject Focused(string app)
    {
        using var process = AppService.Resolve(app);
        var element = AutomationElement.FocusedElement
            ?? throw new InvalidOperationException("No focused UI Automation element.");
        if (element.Current.ProcessId != process.Id)
            throw new InvalidOperationException("The target application does not own the focused element.");
        return Describe(element, ExistingOrNewHandle(element));
    }

    internal string? ReadText(AutomationElement element)
    {
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var textObject) && textObject is TextPattern text)
            return text.DocumentRange.GetText(-1).TrimEnd('\r', '\n');
        var value = ValueOf(element);
        if (value is JsonValue jsonValue && jsonValue.TryGetValue<string>(out var stringValue))
            return stringValue;
        return EmptyToNull(element.Current.Name);
    }

    internal JsonArray ReadAllText(string app, int windowIndex = 0, int maxElements = 500)
    {
        var root = RootFor(app, windowIndex);
        var result = new JsonArray();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in Walk(root, 20, maxElements))
        {
            try
            {
                if (item.Element.Current.IsOffscreen) continue;
                var text = ReadText(item.Element);
                if (string.IsNullOrWhiteSpace(text) || !seen.Add(text)) continue;
                result.Add(new JsonObject
                {
                    ["text"] = text,
                    ["role"] = RoleName(item.Element.Current.ControlType),
                    ["depth"] = item.Depth
                });
            }
            catch (ElementNotAvailableException) { }
        }
        return result;
    }

    internal string Invoke(AutomationElement element, bool foreground)
    {
        if (element.TryGetCurrentPattern(InvokePattern.Pattern, out var invokeObject) && invokeObject is InvokePattern invoke)
        {
            invoke.Invoke();
            return "uia-invoke";
        }
        if (element.TryGetCurrentPattern(TogglePattern.Pattern, out var toggleObject) && toggleObject is TogglePattern toggle)
        {
            toggle.Toggle();
            return "uia-toggle";
        }
        if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var selectionObject) && selectionObject is SelectionItemPattern selection)
        {
            selection.Select();
            return "uia-selection";
        }
        if (element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var expandObject) && expandObject is ExpandCollapsePattern expand)
        {
            if (expand.Current.ExpandCollapseState == ExpandCollapseState.Expanded) expand.Collapse();
            else expand.Expand();
            return "uia-expand-collapse";
        }
        if (!foreground)
            throw new InvalidOperationException("Control exposes no background-safe action. Retry with foreground:true for a coordinate click.");

        var rect = element.Current.BoundingRectangle;
        if (rect.IsEmpty) throw new InvalidOperationException("Element has no clickable bounds.");
        ForegroundAction(element.Current.ProcessId, () => NativeMethods.ClickAt((int)rect.X + (int)rect.Width / 2, (int)rect.Y + (int)rect.Height / 2));
        return "foreground-coordinate";
    }

    internal string TypeText(AutomationElement element, string text, bool foreground)
    {
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valueObject) && valueObject is ValuePattern value && !value.Current.IsReadOnly)
        {
            value.SetValue(text);
            return "uia-value";
        }
        if (!foreground)
            throw new InvalidOperationException("Control exposes no writable ValuePattern. Retry with foreground:true for keyboard input.");
        ForegroundAction(element.Current.ProcessId, () =>
        {
            element.SetFocus();
            return NativeMethods.SendUnicode(text);
        });
        return "foreground-keyboard";
    }

    internal static JsonNode? ValueOf(AutomationElement element)
    {
        try
        {
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && value is ValuePattern vp)
                return JsonValue.Create(vp.Current.Value);
            if (element.TryGetCurrentPattern(TogglePattern.Pattern, out var toggle) && toggle is TogglePattern tp)
                return JsonValue.Create(tp.Current.ToggleState == ToggleState.On);
            if (element.TryGetCurrentPattern(RangeValuePattern.Pattern, out var range) && range is RangeValuePattern rp)
                return JsonValue.Create(rp.Current.Value);
        }
        catch (ElementNotAvailableException) { }
        return null;
    }

    private static void ForegroundAction(int pid, Func<bool> action)
    {
        var previousWindow = NativeMethods.GetForegroundWindow();
        _ = NativeMethods.GetCursorPos(out var previousCursor);
        using var process = Process.GetProcessById(pid);
        var hwnd = process.MainWindowHandle;
        if (hwnd == nint.Zero) throw new InvalidOperationException("Target has no main window.");
        _ = NativeMethods.ShowWindow(hwnd, NativeMethods.SwRestore);
        if (!NativeMethods.SetForegroundWindow(hwnd)) throw new InvalidOperationException("Windows refused to focus the target app.");
        Thread.Sleep(80);
        try
        {
            if (!action()) throw new InvalidOperationException("Windows rejected simulated input, possibly because the target is elevated (UIPI).");
        }
        finally
        {
            _ = NativeMethods.SetCursorPos(previousCursor.X, previousCursor.Y);
            if (previousWindow != nint.Zero) _ = NativeMethods.SetForegroundWindow(previousWindow);
        }
    }

    private string ExistingOrNewHandle(AutomationElement element)
    {
        foreach (var pair in handles)
        {
            try { if (System.Windows.Automation.Automation.Compare(pair.Value, element)) return pair.Key; }
            catch (ElementNotAvailableException) { }
        }
        var id = $"e{Interlocked.Increment(ref nextHandle)}";
        handles[id] = element;
        return id;
    }

    private static IEnumerable<(AutomationElement Element, int Depth)> Walk(AutomationElement root, int maxDepth, int maxElements)
    {
        var walker = TreeWalker.ControlViewWalker;
        var queue = new Queue<(AutomationElement Element, int Depth)>();
        var visited = new HashSet<string>();
        queue.Enqueue((root, 0));
        var count = 0;
        while (queue.Count > 0 && count < maxElements)
        {
            var item = queue.Dequeue();
            string identity;
            try { identity = string.Join('.', item.Element.GetRuntimeId()); }
            catch (ElementNotAvailableException) { continue; }
            if (!visited.Add(identity)) continue;
            count++;
            yield return item;
            if (item.Depth >= maxDepth) continue;
            AutomationElement? child;
            try { child = walker.GetFirstChild(item.Element); }
            catch (ElementNotAvailableException) { continue; }
            while (child is not null)
            {
                queue.Enqueue((child, item.Depth + 1));
                try { child = walker.GetNextSibling(child); }
                catch (ElementNotAvailableException) { break; }
            }
        }
    }

    private static bool Matches(AutomationElement element, JsonObject criteria)
    {
        try
        {
            var current = element.Current;
            var role = RoleName(current.ControlType);
            if (String(criteria, "role") is { } wantedRole && !RoleMatches(role, wantedRole)) return false;
            if (String(criteria, "title") is { } title && current.Name != title) return false;
            if (String(criteria, "titleContains") is { } titleContains && !Contains(current.Name, titleContains)) return false;
            if (String(criteria, "identifier") is { } identifier && current.AutomationId != identifier) return false;
            if (String(criteria, "description") is { } description && current.HelpText != description) return false;
            if (String(criteria, "descriptionContains") is { } descriptionContains && !Contains(current.HelpText, descriptionContains)) return false;
            var value = ValueOf(element)?.ToString();
            if (String(criteria, "value") is { } wantedValue && value != wantedValue) return false;
            if (String(criteria, "labelContains") is { } label &&
                !new[] { current.Name, current.HelpText, current.AutomationId, value }.Any(v => Contains(v, label))) return false;
            return true;
        }
        catch (ElementNotAvailableException) { return false; }
    }

    internal static bool HasSelector(JsonObject arguments) =>
        new[] { "role", "title", "titleContains", "identifier", "value", "description", "descriptionContains", "labelContains" }
            .Any(name => !string.IsNullOrWhiteSpace(String(arguments, name)));

    private static bool RoleMatches(string actual, string wanted)
    {
        var normalized = wanted.StartsWith("AX", StringComparison.OrdinalIgnoreCase) ? wanted[2..] : wanted;
        normalized = normalized switch
        {
            "TextField" or "TextArea" => "Edit",
            "StaticText" => "Text",
            "CheckBox" => "CheckBox",
            _ => normalized
        };
        return actual.Equals(normalized, StringComparison.OrdinalIgnoreCase);
    }

    internal static string RoleName(ControlType type) => type.ProgrammaticName.Replace("ControlType.", string.Empty);
    private static bool Contains(string? value, string part) => value?.Contains(part, StringComparison.OrdinalIgnoreCase) == true;
    private static string? EmptyToNull(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
    internal static string? String(JsonObject value, string name) => value[name]?.GetValue<string>();
    internal static bool Bool(JsonObject value, string name, bool fallback = false) => value[name]?.GetValue<bool>() ?? fallback;
    internal static int Int(JsonObject value, string name, int fallback, int min, int max) => Math.Clamp(value[name]?.GetValue<int>() ?? fallback, min, max);
    internal static int? NullableInt(JsonObject value, string name) => value[name]?.GetValue<int>();

    internal static JsonObject RectJson(System.Windows.Rect rect) => new()
    {
        ["x"] = double.IsInfinity(rect.X) ? 0 : rect.X,
        ["y"] = double.IsInfinity(rect.Y) ? 0 : rect.Y,
        ["width"] = double.IsInfinity(rect.Width) ? 0 : rect.Width,
        ["height"] = double.IsInfinity(rect.Height) ? 0 : rect.Height
    };
}
