import AppKit
import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

struct AppTools {
    /// `NSRunningApplication.hide()/unhide()` return values are unreliable (false even
    /// when the request lands, especially right after a background launch). Send the
    /// request, then poll the app's actual `isHidden` state briefly and report THAT.
    static func setHiddenVerified(pid: pid_t, hidden: Bool) async throws -> Bool {
        _ = await MainActor.run { hidden ? AppManager.hide(pid: pid) : AppManager.unhide(pid: pid) }
        for _ in 0..<10 {
            let state = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }
            if state == hidden { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        return await MainActor.run { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }
    }

    /// How long `reset_app_state` waits for a quit request to take effect.
    static let quitTimeout: TimeInterval = 5

    /// Polls `condition` every `interval` seconds until it holds or `timeout` passes.
    /// Returns whether it held; checks once more at the deadline's edge so a zero
    /// timeout still answers for the present moment.
    static func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.1,
        _ condition: () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await condition() { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(for: .seconds(interval))
        }
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
                let hidden = try await setHiddenVerified(pid: pid, hidden: true)
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
                let hidden = try await setHiddenVerified(pid: pid, hidden: false)
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
            description: "Open a URL in a REAL browser the user can see (web link, deep link, or custom scheme like 'myapp://path'). Web links go to the browser named in `browser` (or `app`), otherwise the user's DEFAULT browser — never silently a different one. If the user names a browser (\"in Safari\", \"use Firefox\"), pass it. headless:true instead opens the page in a private headless Chromium for scripted testing. BACKGROUND-SAFE BY DEFAULT: the browser receives the URL WITHOUT being brought to the front. Then `snapshot` with app=<that browser> reads the page.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string"), "description": .string("URL to open (e.g. 'https://example.com' or 'myapp://route')")]),
                    "browser": .object(["type": .string("string"), "description": .string("Browser to open web links in: 'safari', 'chrome', 'firefox', 'edge', 'brave', 'arc', a bundle id, or 'default' (the user's default browser, which is what you get when omitted).")]),
                    "headless": .object(["type": .string("boolean"), "description": .string("Open in a private headless Chromium (CDP) instead of a visible browser. Only for scripted web testing; it has none of the user's logins.")]),
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

                // Web links honour the named browser; deep links (myapp://) always go to
                // whatever app registered the scheme.
                let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                let named = args?["browser"]?.stringValue
                    ?? args?["app"]?.stringValue.flatMap { BrowserResolver.isBrowserName($0) ? $0 : nil }
                if isWeb, let named {
                    guard let browser = BrowserResolver.named(named) else {
                        return ToolResult.error("Browser '\(named)' is not installed. Installed default: \(BrowserResolver.systemDefault()?.name ?? "unknown"). Not falling back to another browser.")
                    }
                    do {
                        let app = try await NSWorkspace.shared.open([url], withApplicationAt: browser.appURL, configuration: config)
                        return ToolResult.action(success: true, method: "workspace", extra: [
                            "url": .string(urlStr),
                            "handler": .string(app.bundleIdentifier ?? browser.bundleId),
                            "browser": .string(browser.name),
                            "activated": .bool(foreground),
                        ])
                    } catch {
                        return ToolResult.error("\(browser.name) could not open \(urlStr) (\(error.localizedDescription))")
                    }
                }
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
            description: "Quit an app to reset its in-memory state, waiting up to 5s for it to actually exit (an error if a 'Save changes?' sheet or similar kept it alive). When wipeData:true AND the app is sandboxed (a Container exists for its bundle ID), ALSO delete ~/Library/Containers/<bundleId>/Data — this is DESTRUCTIVE, only happens behind the explicit wipeData:true flag, and is refused while the app (or another instance of it) is still running. Without the flag, only quits.",
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

                // Quit if running. terminate() only REQUESTS a quit: an app with unsaved
                // work answers with a "Save changes?" sheet and keeps running, so wait for
                // the process to actually be gone rather than trusting the request.
                var quit = false
                var terminated = true
                if let pid = runningPID {
                    quit = await MainActor.run { AppManager.quit(pid: pid) }
                    terminated = try await waitUntil(timeout: quitTimeout) {
                        await MainActor.run { NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true }
                    }
                    await ShareableContentCache.shared.invalidate()
                }

                var fields: [String: JSONValue] = [
                    "quit": .bool(quit),
                    "wiped": .bool(false),
                ]
                if let bundleId { fields["bundleId"] = .string(bundleId) }

                // ToolResult.action(success: false) drops `extra`, so the reason has to ride in the error text.
                guard terminated else {
                    return ToolResult.error("\(appStr) is still running \(Int(quitTimeout))s after the quit request — most likely a 'Save changes?' sheet or another blocking dialog. Dismiss it (or force-quit the app) and retry.\(wipeData ? " Nothing was deleted." : "")")
                }

                guard wipeData else {
                    // Non-destructive path — never touch the filesystem without the flag.
                    return ToolResult.action(success: true, method: "quit", extra: fields)
                }

                guard let bundleId else {
                    return ToolResult.error("Cannot wipe data: could not resolve a bundle ID for '\(appStr)'")
                }

                // The target process is gone, but a second instance of the same bundle
                // shares the container; deleting it would pull the data out from under that one.
                let othersRunning = await MainActor.run {
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).contains { !$0.isTerminated }
                }
                guard !othersRunning else {
                    return ToolResult.error("Refusing to wipe data: another instance of \(bundleId) is still running and uses the same container. Quit it first. Nothing was deleted.")
                }

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
