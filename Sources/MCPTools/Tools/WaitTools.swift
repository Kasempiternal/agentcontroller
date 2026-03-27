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
                let criteria = AXElementSearchCriteria(
                    role: args?["role"]?.stringValue,
                    title: args?["title"]?.stringValue,
                    titleContains: args?["titleContains"]?.stringValue,
                    identifier: args?["identifier"]?.stringValue,
                    maxResults: 1
                )

                let start = Date()
                while Date().timeIntervalSince(start) < timeout {
                    let found = await MainActor.run {
                        let appElement = AXElement.application(pid: pid)
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
