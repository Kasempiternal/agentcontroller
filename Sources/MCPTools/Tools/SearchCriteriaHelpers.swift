import Foundation
import MCPServer
import AccessibilityEngine

extension AXElementSearchCriteria {
    /// Build search criteria from a tool-handler `args` object. Honors all matcher
    /// fields plus `maxResults` and an optional `index`/`nth` (0-based) to disambiguate
    /// several identical controls. Callers pass a single max (usually 1 for interaction
    /// tools, 20 for inspection tools).
    init(from args: JSONValue?, maxResults: Int) {
        self.init(
            role: args?["role"]?.stringValue,
            title: args?["title"]?.stringValue,
            titleContains: args?["titleContains"]?.stringValue,
            identifier: args?["identifier"]?.stringValue,
            value: args?["value"]?.stringValue,
            description: args?["description"]?.stringValue,
            descriptionContains: args?["descriptionContains"]?.stringValue,
            labelContains: args?["labelContains"]?.stringValue,
            maxResults: maxResults
        )
        // `index` is a property on the criteria struct (AccessibilityEngine). When set,
        // the search returns the Nth match instead of the first.
        if let n = args?["index"]?.intValue ?? args?["nth"]?.intValue {
            self.index = n
        }
    }
}

/// Shared JSON-Schema fragments so every tool advertises the SAME selector vocabulary to
/// the agent (previously `labelContains`/`descriptionContains` worked in the engine but
/// were hidden from most tools' inputSchema). Spread these into a tool's `properties`.
public enum SelectorSchema {
    /// The full set of element-matcher properties.
    public static var properties: [String: JSONValue] {
        [
            "role": .object(["type": .string("string"), "description": .string("AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText')")]),
            "title": .object(["type": .string("string"), "description": .string("Exact AXTitle match")]),
            "titleContains": .object(["type": .string("string"), "description": .string("Partial AXTitle match (case-insensitive)")]),
            "identifier": .object(["type": .string("string"), "description": .string("Accessibility identifier (.accessibilityIdentifier in SwiftUI)")]),
            "value": .object(["type": .string("string"), "description": .string("Element AXValue")]),
            "description": .object(["type": .string("string"), "description": .string("Exact AXDescription match (SwiftUI Button labels often land here)")]),
            "descriptionContains": .object(["type": .string("string"), "description": .string("Partial AXDescription match (case-insensitive)")]),
            "labelContains": .object(["type": .string("string"), "description": .string("Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it")]),
            "index": .object(["type": .string("integer"), "description": .string("0-based index to pick the Nth of several identical matches (default first)")]),
        ]
    }

    /// Merge the selector properties into an existing properties dictionary.
    public static func merged(into base: [String: JSONValue]) -> [String: JSONValue] {
        var out = base
        for (key, value) in properties { out[key] = value }
        return out
    }

    /// Schema fragment for the shared `scope` param. Interaction tools default to
    /// 'window'; assertion/inspection tools default to 'app' (a QA check should see the
    /// whole app unless deliberately narrowed).
    public static func scopeProperty(default def: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array([.string("window"), .string("app")]),
            "description": .string("Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default '\(def)'."),
        ])
    }
}

/// Shared scope handling for every tool that searches the AX tree.
enum SearchScope {
    /// Resolve the BFS root honoring the `scope` arg: 'app' searches from the app root
    /// (all windows + menu bar), 'window' from the app's focused window. Each app keeps
    /// its own focused window even while in the background, so 'window' works without
    /// the app being frontmost.
    static func root(pid: pid_t, args: JSONValue?, defaultScope: String) -> AXElement {
        let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
        let scope = args?["scope"]?.stringValue ?? defaultScope
        if scope == "app" { return appElement }
        return appElement.focusedWindow ?? appElement
    }
}

/// Background (PID-targeted) pointer events route by location INSIDE the target app — a
/// point outside every window of that app is silently dropped by its event handling,
/// while the tool would otherwise report success. This pre-checks the point against the
/// app's AX window frames and returns a warning string for the result payload.
/// Transient surfaces (open menus, popovers) may not appear under kAXWindows, so an
/// outside point is a WARNING, not an error.
func offTargetWarning(pid: pid_t, x: Double, y: Double) async -> String? {
    let point = CGPoint(x: x, y: y)
    let inside = await AXExecutor.shared.run { () -> Bool in
        let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
        return app.windows.contains { $0.frame?.contains(point) == true }
    }
    if inside { return nil }
    return "Point (\(Int(x)), \(Int(y))) is outside every window of the target app — the PID-targeted event was delivered but likely hit nothing. Check frames with list_windows (ignore this if the target is an open menu/popover)."
}
