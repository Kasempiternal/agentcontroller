import Foundation
import MCPServer
import AccessibilityEngine

/// Assertion tools — the core of QA. Each polls the live AX tree until its condition is
/// satisfied (or the timeout elapses) and returns an UNAMBIGUOUS pass/fail:
/// `ToolResult.error(...)` (with `isError: true`) on failure, and a `{passed:true,...}`
/// JSON object on success. That distinction is what lets an agent's control loop — or a
/// recorded flow — branch on a real PASS vs FAIL instead of parsing prose.
struct AssertTools {
    private static let defaultTimeout = 7.0
    private static let pollInterval = 0.4
    /// Gap between the two walks that must both come back empty before assert_not_visible
    /// passes. Short on purpose: it exists to ride out a tree mid-rebuild, not to wait.
    private static let confirmationGap = 0.15

    static func register(in registry: ToolRegistry) {
        registerAssertVisible(in: registry)
        registerAssertNotVisible(in: registry)
        registerAssertValue(in: registry)
    }

    // MARK: - assert_visible

    private static func registerAssertVisible(in registry: ToolRegistry) {
        registry.register(.init(
            name: "assert_visible",
            description: "Assert that an element matching the selector is present. Polls until it appears or the timeout elapses. PASS → {passed:true}; FAIL → isError result naming the selector. Use for QA checkpoints (e.g. confirm a dialog/label showed up). Searches the whole app by default; pass scope:'window' to check only the focused window (faster).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to poll before failing (default 7)")]),
                    "scope": SelectorSchema.scopeProperty(default: "app"),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let timeout = args?["timeout"]?.doubleValue ?? defaultTimeout
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                if let problem = selectorProblem(tool: "assert_visible", args: args, criteria: criteria) {
                    return ToolResult.error(problem)
                }

                let start = Date()
                repeat {
                    let found = await AXExecutor.app(pid).run { () -> AXElementSearchResult? in
                        let root = SearchScope.root(pid: pid, args: args, defaultScope: "app")
                        return AXElementSearch.find(root: root, criteria: criteria).first
                    }
                    if let r = found {
                        return ToolResult.json(.object([
                            "passed": .bool(true),
                            "elapsed": .double(Date().timeIntervalSince(start)),
                            "role": .string(r.element.role ?? "unknown"),
                            "path": .string(r.path),
                        ]))
                    }
                    if Date().timeIntervalSince(start) >= timeout { break }
                    try await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
                } while Date().timeIntervalSince(start) < timeout

                return ToolResult.error("assert_visible FAILED: no element matched \(selectorDescription(args)) within \(timeout)s")
            }
        ))
    }

    // MARK: - assert_not_visible

    private static func registerAssertNotVisible(in registry: ToolRegistry) {
        registry.register(.init(
            name: "assert_not_visible",
            description: "Assert that NO element matches the selector. Polls for the whole window: passes once two consecutive searches of the UI both find nothing; fails if the element stays present the entire time. A search that could not actually read the UI (app hung or quit, no accessibility tree) is an ERROR, never a pass. Use to confirm something dismissed (spinner gone, dialog closed). Needs at least one selector field. Searches the whole app (windows, not the menu bar unless includeMenus) by default; pass scope:'window' to check only the focused window.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to poll waiting for absence before failing (default 7)")]),
                    "scope": SelectorSchema.scopeProperty(default: "app"),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let timeout = args?["timeout"]?.doubleValue ?? defaultTimeout
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                if let problem = selectorProblem(tool: "assert_not_visible", args: args, criteria: criteria) {
                    return ToolResult.error(problem)
                }

                let start = Date()
                var judge = NotVisibleJudge()
                while true {
                    let walk = await AXExecutor.app(pid).run { () -> (found: Bool, probe: AXSearchProbe, alive: Bool) in
                        guard AXElement.isProcessAlive(pid) else { return (false, .empty, false) }
                        let root = SearchScope.root(pid: pid, args: args, defaultScope: "app")
                        let (results, probe) = AXElementSearch.findProbing(root: root, criteria: criteria)
                        return (!results.isEmpty, probe, true)
                    }
                    let observation = NotVisibleJudge.observe(found: walk.found, probe: walk.probe, processAlive: walk.alive)
                    if judge.record(observation) {
                        return ToolResult.json(.object([
                            "passed": .bool(true),
                            "elapsed": .double(Date().timeIntervalSince(start)),
                            "nodesVisited": .int(walk.probe.nodesVisited),
                        ]))
                    }
                    // Never give up between the two confirming walks: one empty walk that
                    // is about to be re-checked is not yet a verdict either way.
                    if judge.consecutiveAbsent == 0 && Date().timeIntervalSince(start) >= timeout { break }
                    let gap = judge.consecutiveAbsent > 0 ? confirmationGap : pollInterval
                    try await Task.sleep(for: .milliseconds(Int(gap * 1000)))
                }

                if case .inconclusive(let reason)? = judge.last {
                    return ToolResult.error("assert_not_visible could NOT verify \(selectorDescription(args)): \(reason). This is not a pass — the element may still be there.")
                }
                return ToolResult.error("assert_not_visible FAILED: element matching \(selectorDescription(args)) was still present after \(timeout)s")
            }
        ))
    }

    // MARK: - assert_value

    private static func registerAssertValue(in registry: ToolRegistry) {
        registry.register(.init(
            name: "assert_value",
            description: "Find an element by selector and assert its value/state. Provide one or more of: equals, contains (vs the element's value/title), enabled, focused, checked (toggle/checkbox/radio state). Polls until all provided checks pass or timeout. PASS → {passed:true}; FAIL → isError with expected vs actual.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "equals": .object(["type": .string("string"), "description": .string("Exact expected value (matched against valueJSON / stringValue / title)")]),
                    "contains": .object(["type": .string("string"), "description": .string("Substring the value/title must contain (case-insensitive)")]),
                    "enabled": .object(["type": .string("boolean"), "description": .string("Expected enabled state")]),
                    "focused": .object(["type": .string("boolean"), "description": .string("Expected focused state")]),
                    "checked": .object(["type": .string("boolean"), "description": .string("Expected checkbox/radio/toggle state (AX value 1/true); fails on elements that expose no checked state")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to poll before failing (default 7)")]),
                    "scope": SelectorSchema.scopeProperty(default: "app"),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let timeout = args?["timeout"]?.doubleValue ?? defaultTimeout
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                if let problem = selectorProblem(tool: "assert_value", args: args, criteria: criteria) {
                    return ToolResult.error(problem)
                }

                let expectEquals = args?["equals"]?.stringValue
                let expectContains = args?["contains"]?.stringValue
                let expectEnabled = args?["enabled"]?.boolValue
                let expectFocused = args?["focused"]?.boolValue
                let expectChecked = args?["checked"]?.boolValue

                let start = Date()
                var last = AssertValueSnapshot(found: false, valueString: nil, title: nil, label: nil,
                                               isEnabled: false, isFocused: false, checked: nil)

                repeat {
                    last = await AXExecutor.app(pid).run { () -> AssertValueSnapshot in
                        let root = SearchScope.root(pid: pid, args: args, defaultScope: "app")
                        guard let r = AXElementSearch.find(root: root, criteria: criteria).first else {
                            return AssertValueSnapshot(found: false, valueString: nil, title: nil, label: nil,
                                                       isEnabled: false, isFocused: false, checked: nil)
                        }
                        let el = r.element
                        return AssertValueSnapshot(
                            found: true,
                            valueString: stringFor(el.valueJSON) ?? el.stringValue,
                            title: el.title,
                            label: el.label,
                            isEnabled: el.isEnabled,
                            isFocused: el.isFocused,
                            checked: boolFromValue(el.valueJSON)
                        )
                    }

                    if last.found {
                        let failure = evaluate(
                            snap: last,
                            equals: expectEquals, contains: expectContains,
                            enabled: expectEnabled, focused: expectFocused, checked: expectChecked
                        )
                        if failure == nil {
                            return ToolResult.json(.object([
                                "passed": .bool(true),
                                "elapsed": .double(Date().timeIntervalSince(start)),
                                "value": last.valueString.map { JSONValue.string($0) } ?? .null,
                                "enabled": .bool(last.isEnabled),
                                "focused": .bool(last.isFocused),
                            ]))
                        }
                    }

                    if Date().timeIntervalSince(start) >= timeout { break }
                    try await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
                } while Date().timeIntervalSince(start) < timeout

                if !last.found {
                    return ToolResult.error("assert_value FAILED: no element matched \(selectorDescription(args)) within \(timeout)s")
                }
                let reason = evaluate(
                    snap: last,
                    equals: expectEquals, contains: expectContains,
                    enabled: expectEnabled, focused: expectFocused, checked: expectChecked
                ) ?? "condition not met"
                return ToolResult.error("assert_value FAILED for \(selectorDescription(args)): \(reason)")
            }
        ))
    }

    // MARK: - Evaluation

    /// Returns nil when every requested expectation holds, else a human description of the
    /// FIRST mismatch (expected vs actual).
    static func evaluate(
        snap: AssertValueSnapshot,
        equals: String?, contains: String?,
        enabled: Bool?, focused: Bool?, checked: Bool?
    ) -> String? {
        let actualText = snap.valueString ?? snap.title ?? snap.label ?? ""
        if let eq = equals, actualText != eq {
            return "expected value == \"\(eq)\" but got \"\(actualText)\""
        }
        if let sub = contains, !actualText.localizedCaseInsensitiveContains(sub) {
            return "expected value to contain \"\(sub)\" but got \"\(actualText)\""
        }
        if let en = enabled, snap.isEnabled != en {
            return "expected enabled == \(en) but got \(snap.isEnabled)"
        }
        if let fo = focused, snap.isFocused != fo {
            return "expected focused == \(fo) but got \(snap.isFocused)"
        }
        if let ck = checked {
            // An element with no checked state is not "unchecked": a text field or a
            // label has none, and treating that as false made `checked:false` pass on
            // any element at all.
            guard let actual = snap.checked else {
                return "expected checked == \(ck) but the element exposes no checked state (its AXValue is not a boolean/number)"
            }
            if actual != ck {
                return "expected checked == \(ck) but got \(actual)"
            }
        }
        return nil
    }

    // MARK: - Value helpers

    /// Best-effort String rendering of a classified AX value for equals/contains.
    static func stringFor(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }

    /// Interpret an AX value as a checkbox/radio/toggle boolean: CFBoolean directly, or a
    /// number where != 0 means checked. Strings "1"/"true" also count as checked.
    static func boolFromValue(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s):
            let l = s.lowercased()
            if l == "1" || l == "true" { return true }
            if l == "0" || l == "false" { return false }
            return nil
        default: return nil
        }
    }

    private static let matcherKeys = ["role", "title", "titleContains", "identifier", "value",
                                      "description", "descriptionContains", "labelContains"]

    /// Every argument the assertion tools understand; anything else is a typo or a tool
    /// from another server's vocabulary.
    private static let recognizedKeys: Set<String> = Set(matcherKeys).union([
        "app", "timeout", "scope", "index", "nth", "includeMenus",
        "equals", "contains", "enabled", "focused", "checked",
    ])

    /// Error text when the call carries no usable matcher, else nil.
    ///
    /// With no matcher `find` returns nothing, so assert_not_visible "passed" on any
    /// call whose selector keys were misspelled (`titel`, `label`) or typed wrongly
    /// (`value: 3`, which only matches strings). Failing fast also spares assert_visible
    /// and assert_value a full timeout of polling for something that cannot match.
    static func selectorProblem(tool: String, args: JSONValue?, criteria: AXElementSearchCriteria) -> String? {
        guard !criteria.hasAnyMatcher else { return nil }
        var details: [String] = []
        if case .object(let dict)? = args {
            let unknown = dict.keys.filter { !recognizedKeys.contains($0) }.sorted()
            if !unknown.isEmpty { details.append("unrecognized argument(s): \(unknown.joined(separator: ", "))") }
            let wrongType = matcherKeys.filter { dict[$0] != nil && dict[$0]?.stringValue == nil }
            if !wrongType.isEmpty { details.append("matcher(s) ignored because they are not strings: \(wrongType.joined(separator: ", "))") }
        }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
        return "\(tool): no usable selector\(suffix). An empty selector matches nothing, so the result would say nothing about the UI. Pass at least one of: \(matcherKeys.joined(separator: ", "))."
    }

    /// Compact, human-readable rendering of the selector the agent passed, for failure text.
    static func selectorDescription(_ args: JSONValue?) -> String {
        var parts: [String] = []
        for key in matcherKeys + ["index"] {
            if let v = args?[key] {
                if let s = v.stringValue { parts.append("\(key)=\"\(s)\"") }
                else if let i = v.intValue { parts.append("\(key)=\(i)") }
            }
        }
        return parts.isEmpty ? "<no selector>" : parts.joined(separator: ", ")
    }
}

/// Plain snapshot of the asserted element's state at one poll tick. Declared at file scope
/// so the `evaluate` helper can take it without re-declaring the nested type.
struct AssertValueSnapshot: Sendable {
    let found: Bool
    let valueString: String?
    let title: String?
    let label: String?
    let isEnabled: Bool
    let isFocused: Bool
    let checked: Bool?
}

/// Decides when assert_not_visible may pass.
///
/// "No match" is what a walk returns both when the element is gone and when the walk
/// could not see anything (dead pid, hung app, no accessibility permission, an app that
/// exposes no tree). The first is a pass; the second used to be one too, so a QA run
/// against a crashed app reported every "dialog dismissed" check green. Only a walk that
/// actually read the tree counts as absence, and two in a row must agree, which also rides
/// out a tree caught mid-rebuild.
struct NotVisibleJudge {
    static let confirmationsRequired = 2

    enum Observation: Equatable {
        case present
        case absent
        case inconclusive(String)
    }

    private(set) var consecutiveAbsent = 0
    private(set) var last: Observation?

    static func observe(found: Bool, probe: AXSearchProbe, processAlive: Bool) -> Observation {
        guard processAlive else { return .inconclusive("the target process has exited") }
        // A hit is a hit however poorly the rest of the walk went.
        if found { return .present }
        if probe.isConclusive { return .absent }
        if probe.rootUnreadable {
            return .inconclusive("the app did not answer accessibility reads (hung, busy, or Accessibility permission missing)")
        }
        if probe.nodesVisited <= 1 {
            return .inconclusive("the search saw only \(probe.nodesVisited) element(s); the app exposes no accessibility tree there")
        }
        return .inconclusive("\(probe.unreadableNodes) of \(probe.nodesVisited) elements could not be read, so parts of the tree were never searched")
    }

    /// Records one walk; true once enough consecutive empty walks have confirmed absence.
    mutating func record(_ observation: Observation) -> Bool {
        last = observation
        if observation == .absent { consecutiveAbsent += 1 } else { consecutiveAbsent = 0 }
        return consecutiveAbsent >= Self.confirmationsRequired
    }
}
