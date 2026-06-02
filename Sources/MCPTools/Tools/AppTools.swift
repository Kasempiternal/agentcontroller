import AppKit
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
                guard let pid = AppManager.resolvePID(from: appStr) else {
                    return ToolResult.error("App not found or not running: \(appStr)")
                }
                let success = await MainActor.run { AppManager.quit(pid: pid) }
                await ShareableContentCache.shared.invalidate()
                return ToolResult.action(success: success, method: "terminate")
            }
        ))

        registry.register(.init(
            name: "activate_app",
            description: "Bring a running macOS application to the foreground. This is the ONE tool that intentionally changes focus and is the explicit, user-requested way to do so — every other interaction tool (click/type_text/send_shortcut/scroll/etc.) runs in the background by default and does NOT bring the app forward. Use this only when you genuinely need the target app frontmost (e.g. before a foreground:true escape-hatch action).",
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
                guard let pid = AppManager.resolvePID(from: appStr) else {
                    return ToolResult.error("App not found or not running: \(appStr)")
                }
                let success = await MainActor.run { AppManager.activate(pid: pid) }
                await ShareableContentCache.shared.invalidate()
                return ToolResult.action(success: success, method: "activate")
            }
        ))

        registry.register(.init(
            name: "open_url",
            description: "Open a URL with the default handler (web link, deep link, or custom scheme like 'myapp://path'). Use for deep-link / web navigation during a flow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string"), "description": .string("URL to open (e.g. 'https://example.com' or 'myapp://route')")]),
                ]),
                "required": .array([.string("url")]),
            ]),
            handler: { args in
                guard let urlStr = args?["url"]?.stringValue else {
                    throw ToolError.missingParameter("url")
                }
                guard let url = URL(string: urlStr), url.scheme != nil else {
                    return ToolResult.error("Invalid URL: \(urlStr)")
                }
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                guard opened else {
                    return ToolResult.error("No handler could open URL: \(urlStr)")
                }
                return ToolResult.action(success: true, method: "workspace", extra: [
                    "url": .string(urlStr),
                ])
            }
        ))

        registry.register(.init(
            name: "reset_app_state",
            description: "Quit an app to reset its in-memory state. When wipeData:true AND the app is sandboxed (a Container exists for its bundle ID), ALSO delete ~/Library/Containers/<bundleId>/Data — this is DESTRUCTIVE and only happens behind the explicit wipeData:true flag. Without the flag, only quits.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "wipeData": .object(["type": .string("boolean"), "description": .string("DESTRUCTIVE: when true, delete the app's sandbox Data container after quitting. Default false (quit only).")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                guard let appStr = args?["app"]?.stringValue else {
                    throw ToolError.missingParameter("app")
                }
                let wipeData = args?["wipeData"]?.boolValue ?? false

                // Resolve a bundle id (from the live process if running, else treat the
                // arg as a bundle id) BEFORE quitting so we can target its container.
                let runningPID = AppManager.resolvePID(from: appStr)
                let bundleId: String? = await MainActor.run { () -> String? in
                    if let pid = runningPID,
                       let app = NSRunningApplication(processIdentifier: pid),
                       let bid = app.bundleIdentifier {
                        return bid
                    }
                    // Not running: accept the arg as a bundle id if it resolves to an app.
                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: appStr) != nil {
                        return appStr
                    }
                    return nil
                }

                // Quit if running.
                var quit = false
                if let pid = runningPID {
                    quit = await MainActor.run { AppManager.quit(pid: pid) }
                    await ShareableContentCache.shared.invalidate()
                }

                var fields: [String: JSONValue] = [
                    "quit": .bool(quit),
                    "wiped": .bool(false),
                ]
                if let bundleId { fields["bundleId"] = .string(bundleId) }

                guard wipeData else {
                    // Non-destructive path — never touch the filesystem without the flag.
                    return ToolResult.action(success: true, method: "quit", extra: fields)
                }

                guard let bundleId else {
                    return ToolResult.error("Cannot wipe data: could not resolve a bundle ID for '\(appStr)'")
                }

                // Give the app a beat to terminate and release file handles.
                await AXExecutor.shared.pause(0.5)

                let home = FileManager.default.homeDirectoryForCurrentUser
                let dataDir = home
                    .appendingPathComponent("Library/Containers/\(bundleId)/Data", isDirectory: true)
                guard FileManager.default.fileExists(atPath: dataDir.path) else {
                    fields["wiped"] = .bool(false)
                    fields["note"] = .string("No sandbox container at \(dataDir.path); nothing removed (app may be unsandboxed).")
                    return ToolResult.action(success: true, method: "quit", extra: fields)
                }
                do {
                    try FileManager.default.removeItem(at: dataDir)
                    fields["wiped"] = .bool(true)
                    fields["removed"] = .string(dataDir.path)
                    return ToolResult.action(success: true, method: "wipe", extra: fields)
                } catch {
                    return ToolResult.error("Quit ok but failed to remove container data: \(error.localizedDescription)")
                }
            }
        ))
    }
}
