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

    static func register(in registry: ToolRegistry) {
        registerAssertVisible(in: registry)
        registerAssertNotVisible(in: registry)
        registerAssertValue(in: registry)
    }

    // MARK: - assert_visible

    private static func registerAssertVisible(in registry: ToolRegistry) {
        registry.register(.init(
            name: "assert_visible",
            description: "Assert that an element matching the selector is present. Polls until it appears or the timeout elapses. PASS → {passed:true}; FAIL → isError result naming the selector. Use for QA checkpoints (e.g. confirm a dialog/label showed up).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to poll before failing (default 7)")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let timeout = args?["timeout"]?.doubleValue ?? defaultTimeout
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let start = Date()
                repeat {
                    let found = await AXExecutor.shared.run { () -> AXElementSearchResult? in
                        let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                        return AXElementSearch.find(root: app, criteria: criteria).first
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
            description: "Assert that NO element matches the selector. Polls for the whole window: passes as soon as the element is absent; fails only if it stays present the entire time. Use to confirm something dismissed (spinner gone, dialog closed).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to poll waiting for absence before failing (default 7)")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let timeout = args?["timeout"]?.doubleValue ?? defaultTimeout
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let start = Date()
                repeat {
                    let found = await AXExecutor.shared.run { () -> AXElementSearchResult? in
                        let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                        return AXElementSearch.find(root: app, criteria: criteria).first
                    }
                    if found == nil {
                        return ToolResult.json(.object([
                            "passed": .bool(true),
                            "elapsed": .double(Date().timeIntervalSince(start)),
                        ]))
                    }
                    if Date().timeIntervalSince(start) >= timeout { break }
                    try await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
                } while Date().timeIntervalSince(start) < timeout

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
                    "checked": .object(["type": .string("boolean"), "description": .string("Expected checkbox/radio/toggle state (AX value 1/true)")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to poll before failing (default 7)")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let timeout = args?["timeout"]?.doubleValue ?? defaultTimeout
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let expectEquals = args?["equals"]?.stringValue
                let expectContains = args?["contains"]?.stringValue
                let expectEnabled = args?["enabled"]?.boolValue
                let expectFocused = args?["focused"]?.boolValue
                let expectChecked = args?["checked"]?.boolValue

                let start = Date()
                var last = AssertValueSnapshot(found: false, valueString: nil, title: nil, label: nil,
                                               isEnabled: false, isFocused: false, checked: nil)

                repeat {
                    last = await AXExecutor.shared.run { () -> AssertValueSnapshot in
                        let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                        guard let r = AXElementSearch.find(root: app, criteria: criteria).first else {
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
    private static func evaluate(
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
            let actual = snap.checked ?? false
            if actual != ck {
                return "expected checked == \(ck) but got \(snap.checked.map(String.init(describing:)) ?? "<no state>")"
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

    /// Compact, human-readable rendering of the selector the agent passed, for failure text.
    static func selectorDescription(_ args: JSONValue?) -> String {
        var parts: [String] = []
        for key in ["role", "title", "titleContains", "identifier", "value",
                    "description", "descriptionContains", "labelContains", "index"] {
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
