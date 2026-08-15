import AppKit
import Foundation
import MCPServer
import AccessibilityEngine

struct WaitTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "wait_for_element",
            description: "Wait for a UI element to appear matching the given criteria (all the standard selectors: role/title/titleContains/identifier/value/description/descriptionContains/labelContains/index). Polls until found or timeout. Searches the whole app by default; pass scope:'window' for just the focused window.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Timeout in seconds (default 10)")]),
                    "pollInterval": .object(["type": .string("number"), "description": .string("Poll interval in seconds (default 0.5)")]),
                    "scope": SelectorSchema.scopeProperty(default: "app"),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let timeout = args?["timeout"]?.doubleValue ?? 10.0
                let pollInterval = args?["pollInterval"]?.doubleValue ?? 0.5
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let start = Date()
                while Date().timeIntervalSince(start) < timeout {
                    // Liveness: a target that quits/crashes mid-wait would otherwise have us
                    // poll a dead PID until the generic timeout. Bail immediately instead.
                    if NSRunningApplication(processIdentifier: pid) == nil {
                        return ToolResult.error("App is no longer running (pid \(pid))")
                    }
                    let found = await AXExecutor.app(pid).run { () -> AXElementSearchResult? in
                        let root = SearchScope.root(pid: pid, args: args, defaultScope: "app")
                        return AXElementSearch.find(root: root, criteria: criteria).first
                    }
                    if let r = found {
                        let elapsed = Date().timeIntervalSince(start)
                        var fields: [String: JSONValue] = [
                            "found": .bool(true),
                            "elapsed": .double(elapsed),
                            "path": .string(r.path),
                            "role": .string(r.element.role ?? "unknown"),
                        ]
                        if let t = r.element.title { fields["title"] = .string(t) }
                        return ToolResult.json(.object(fields))
                    }
                    try await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
                }

                return ToolResult.json(.object([
                    "found": .bool(false),
                    "elapsed": .double(timeout),
                    "message": .string("Element not found within \(timeout)s timeout"),
                ]))
            }
        ))
    }
}
