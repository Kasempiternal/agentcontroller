import AppKit
import Foundation
import MCPServer
import AccessibilityEngine

struct SystemTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "check_permissions",
            description: "Check if Macoestro has the required macOS permissions (Accessibility and Screen Recording)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                let ax = PermissionChecker.isAccessibilityGranted
                let sr = PermissionChecker.isScreenRecordingGranted
                return ToolResult.json(.object([
                    "accessibility": .bool(ax),
                    "screenRecording": .bool(sr),
                    "allGranted": .bool(ax && sr),
                    "instructions": .string(
                        !ax ? "Grant Accessibility: System Settings > Privacy & Security > Accessibility > Enable Macoestro" :
                        !sr ? "Grant Screen Recording: System Settings > Privacy & Security > Screen Recording > Enable Macoestro" :
                        "All permissions granted"
                    ),
                ]))
            }
        ))

        registry.register(.init(
            name: "get_clipboard",
            description: "Read the system clipboard's plain-text contents — verify that a copy/export action in the tested app actually produced the right text. NOTE: the clipboard is SYSTEM-WIDE shared state (the one thing background QA can't isolate); the user may have their own content there.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                let (text, changeCount) = await MainActor.run { () -> (String?, Int) in
                    let pb = NSPasteboard.general
                    return (pb.string(forType: .string), pb.changeCount)
                }
                return ToolResult.json(.object([
                    "text": text.map { JSONValue.string($0) } ?? .null,
                    "hasText": .bool(text != nil),
                    "changeCount": .int(changeCount),
                ]))
            }
        ))

        registry.register(.init(
            name: "set_clipboard",
            description: "Replace the system clipboard with the given plain text — stage content for a paste step (e.g. set_clipboard then send_shortcut Cmd+V into the tested app). NOTE: this OVERWRITES the user's clipboard (system-wide shared state); use get_clipboard first if their content needs restoring afterwards.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("Text to place on the clipboard")]),
                ]),
                "required": .array([.string("text")]),
            ]),
            handler: { args in
                guard let text = args?["text"]?.stringValue else {
                    throw ToolError.missingParameter("text")
                }
                let ok = await MainActor.run { () -> Bool in
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    return pb.setString(text, forType: .string)
                }
                return ToolResult.action(success: ok, method: "pasteboard", extra: [
                    "length": .int(text.count),
                ])
            }
        ))

        registry.register(.init(
            name: "get_frontmost_app",
            description: "Get information about the currently frontmost (active) macOS application",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                guard let app = await MainActor.run(body: { AppManager.frontmostApp() }) else {
                    return ToolResult.error("No frontmost application found")
                }
                return ToolResult.json(.object([
                    "name": .string(app.name),
                    "bundleId": .string(app.bundleIdentifier ?? ""),
                    "pid": .int(Int(app.pid)),
                ]))
            }
        ))
    }
}
