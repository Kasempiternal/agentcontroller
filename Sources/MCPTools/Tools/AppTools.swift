import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

struct AppTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "list_apps",
            description: "List running macOS applications with their name, bundle ID, and PID",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                let apps = await MainActor.run { AppManager.listRunningApps() }
                let appList: [JSONValue] = apps.map { app in
                    .object([
                        "name": .string(app.name),
                        "bundleId": .string(app.bundleIdentifier ?? ""),
                        "pid": .int(Int(app.pid)),
                        "isActive": .bool(app.isActive),
                        "isHidden": .bool(app.isHidden),
                    ])
                }
                return ToolResult.json(.array(appList))
            }
        ))

        registry.register(.init(
            name: "launch_app",
            description: "Launch a macOS application by bundle identifier (e.g. 'com.apple.TextEdit')",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundleId": .object([
                        "type": .string("string"),
                        "description": .string("Bundle identifier (e.g. 'com.apple.TextEdit')"),
                    ]),
                ]),
                "required": .array([.string("bundleId")]),
            ]),
            handler: { args in
                guard let bundleId = args?["bundleId"]?.stringValue else {
                    throw ToolError.missingParameter("bundleId")
                }
                let app = try await AppManager.launch(bundleIdentifier: bundleId)
                await ShareableContentCache.shared.invalidate()
                return ToolResult.json(.object([
                    "name": .string(app.name),
                    "bundleId": .string(app.bundleIdentifier ?? bundleId),
                    "pid": .int(Int(app.pid)),
                ]))
            }
        ))

        registry.register(.init(
            name: "quit_app",
            description: "Quit a running macOS application",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, or PID"),
                    ]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                guard let appStr = args?["app"]?.stringValue else {
                    throw ToolError.missingParameter("app")
                }
                let success: Bool
                if let pid = AppManager.resolvePID(from: appStr) {
                    success = await MainActor.run { AppManager.quit(pid: pid) }
                    await ShareableContentCache.shared.invalidate()
                } else {
                    success = false
                }
                return ToolResult.json(.object(["success": .bool(success)]))
            }
        ))

        registry.register(.init(
            name: "activate_app",
            description: "Bring a running macOS application to the foreground",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, or PID"),
                    ]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                guard let appStr = args?["app"]?.stringValue else {
                    throw ToolError.missingParameter("app")
                }
                let success: Bool
                if let pid = AppManager.resolvePID(from: appStr) {
                    success = await MainActor.run { AppManager.activate(pid: pid) }
                    await ShareableContentCache.shared.invalidate()
                } else {
                    success = false
                }
                return ToolResult.json(.object(["success": .bool(success)]))
            }
        ))
    }
}
