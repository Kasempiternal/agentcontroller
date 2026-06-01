import AppKit
import Foundation
import MCPServer
import AccessibilityEngine

struct WaitTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "wait_for_element",
            description: "Wait for a UI element to appear matching the given criteria. Polls until found or timeout.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role to match")]),
                    "title": .object(["type": .string("string"), "description": .string("Title to match")]),
                    "titleContains": .object(["type": .string("string"), "description": .string("Partial title match")]),
                    "identifier": .object(["type": .string("string"), "description": .string("Accessibility identifier")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Timeout in seconds (default 10)")]),
                    "pollInterval": .object(["type": .string("number"), "description": .string("Poll interval in seconds (default 0.5)")]),
                ]),
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
                    let found = await AXExecutor.shared.run { () -> AXElementSearchResult? in
                        let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                        return AXElementSearch.find(root: appElement, criteria: criteria).first
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
