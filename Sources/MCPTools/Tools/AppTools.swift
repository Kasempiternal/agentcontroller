import AppKit
import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

struct AppTools {
    /// `NSRunningApplication.hide()/unhide()` return values are unreliable (false even
    /// when the request lands, especially right after a background launch). Send the
    /// request, then poll the app's actual `isHidden` state briefly and report THAT.
    static func setHiddenVerified(pid: pid_t, hidden: Bool) async -> Bool {
        _ = await MainActor.run { hidden ? AppManager.hide(pid: pid) : AppManager.unhide(pid: pid) }
        for _ in 0..<10 {
            let state = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }
            if state == hidden { return state }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await MainActor.run { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }
    }

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
            description: "Launch a macOS application by bundle identifier (e.g. 'com.apple.TextEdit'). BACKGROUND-SAFE BY DEFAULT: the app starts WITHOUT being activated — its window appears but the user's current app keeps keyboard focus (open -g semantics). Pass `paths` to open files/folders in the app at launch — THE way to get a document or project open: never drive the app's open panel with keystrokes (that requires activation and steals the user's focus). Also works when the app is already running. Set foreground:true only when the app genuinely must start frontmost.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundleId": .object([
                        "type": .string("string"),
                        "description": .string("Bundle identifier (e.g. 'com.apple.TextEdit')"),
                    ]),
                    "paths": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Absolute file/folder paths to open in the app at launch ('~' allowed). Replaces any open-panel driving — background-safe."),
                    ]),
                    "foreground": .object([
                        "type": .string("boolean"),
                        "description": .string("Default false (launch without stealing focus). When true, activates the app on launch."),
                    ]),
                ]),
                "required": .array([.string("bundleId")]),
            ]),
            handler: { args in
                guard let bundleId = args?["bundleId"]?.stringValue else {
                    throw ToolError.missingParameter("bundleId")
                }
                let foreground = args?["foreground"]?.boolValue ?? false
                let paths = args?["paths"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                let app = try await AppManager.launch(bundleIdentifier: bundleId, activates: foreground, paths: paths)
                await ShareableContentCache.shared.invalidate()
                var fields: [String: JSONValue] = [
                    "name": .string(app.name),
                    "bundleId": .string(app.bundleIdentifier ?? bundleId),
                    "pid": .int(Int(app.pid)),
                    "activated": .bool(foreground),
                ]
                if !paths.isEmpty {
                    fields["opened"] = .array(paths.map { .string($0) })
                }
                return ToolResult.json(.object(fields))
            }
        ))

        registry.register(.init(
            name: "hide_app",
            description: "Hide all windows of a running app (Cmd+H equivalent) so it is completely invisible to the user while the QA run continues. VERIFIED to keep working while hidden: focused-window interactions (click/type_text by selector, snapshot, get_focused_element) AND screenshot_window — ScreenCaptureKit renders hidden windows fresh, so captures show current content, not a stale frame. CAVEATS: (1) the AX windows LIST is empty while hidden, so list_windows and scope:'app' searches see no windows — stick to the default scope:'window'; (2) clipboard/responder-chain commands (Copy/Paste menu items or Cmd+C/V) no-op without an active app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let hidden = await setHiddenVerified(pid: pid, hidden: true)
                await ShareableContentCache.shared.invalidate()
                return ToolResult.action(success: hidden, method: "hide", extra: [
                    "isHidden": .bool(hidden),
                ])
            }
        ))

        registry.register(.init(
            name: "unhide_app",
            description: "Unhide a hidden app's windows WITHOUT activating it — the user's frontmost app keeps keyboard focus. NOTE: until the app is activated once, its AX windows LIST may stay empty (focused-window tools and screenshots work regardless); use activate_app only if you explicitly need list_windows/scope:'app' enumeration back.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let hidden = await setHiddenVerified(pid: pid, hidden: false)
                await ShareableContentCache.shared.invalidate()
                return ToolResult.action(success: !hidden, method: "unhide", extra: [
                    "isHidden": .bool(hidden),
                ])
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
            description: "Bring a running macOS application to the foreground. ⚠️ This is the ONE tool that STEALS THE USER'S FOCUS, and it is almost never needed: screenshot_window captures background and even hidden windows, and every interaction tool (click/type_text/send_shortcut/scroll/navigate_menu) works without activation. Legitimate uses are clipboard/paste flows and apps that ignore PID-targeted input. While Focus Guard is enabled (the default; menu-bar toggle) this call is refused with an error.",
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
            description: "Open a URL with the default handler (web link, deep link, or custom scheme like 'myapp://path'). BACKGROUND-SAFE BY DEFAULT: the handler app receives the URL WITHOUT being brought to the front — the user's focus is untouched. Set foreground:true to activate the handler app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string"), "description": .string("URL to open (e.g. 'https://example.com' or 'myapp://route')")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (handler app stays in the background). When true, activates the handler app.")]),
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
                let foreground = args?["foreground"]?.boolValue ?? false
                let config = NSWorkspace.OpenConfiguration()
                config.activates = foreground
                do {
                    let handler = try await NSWorkspace.shared.open(url, configuration: config)
                    return ToolResult.action(success: true, method: "workspace", extra: [
                        "url": .string(urlStr),
                        "handler": .string(handler.bundleIdentifier ?? handler.localizedName ?? "unknown"),
                        "activated": .bool(foreground),
                    ])
                } catch {
                    return ToolResult.error("No handler could open URL: \(urlStr) (\(error.localizedDescription))")
                }
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
                await AXExecutor.pause(0.5)

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
