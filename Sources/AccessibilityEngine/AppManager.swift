import AppKit
import Foundation

public struct RunningApp: Sendable {
    public let name: String
    public let bundleIdentifier: String?
    public let pid: pid_t
    public let isActive: Bool
    public let isHidden: Bool
}

public struct AppManager {
    public static func listRunningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                RunningApp(
                    name: app.localizedName ?? "Unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    isActive: app.isActive,
                    isHidden: app.isHidden
                )
            }
    }

    /// Launch an app. `activates` defaults to FALSE (the `open -g` semantics): the app
    /// starts and its windows appear, but the user's frontmost app keeps keyboard focus
    /// and the cursor is untouched — required for background QA runs. Pass
    /// `activates: true` only behind an explicit foreground request.
    public static func launch(bundleIdentifier: String, activates: Bool = false) async throws -> RunningApp {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw AppError.appNotFound(bundleIdentifier)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates

        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)

        // Wait briefly for app to become responsive
        try await Task.sleep(for: .milliseconds(500))

        return RunningApp(
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            pid: app.processIdentifier,
            isActive: app.isActive,
            isHidden: app.isHidden
        )
    }

    @discardableResult
    public static func activate(bundleIdentifier: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }
        return app.activate()
    }

    @discardableResult
    public static func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    /// Hide all of an app's windows (Cmd+H equivalent). The app keeps running and its
    /// AX tree, PID-targeted input, and internal focus chain all keep working.
    @discardableResult
    public static func hide(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.hide() ?? false
    }

    /// Unhide an app WITHOUT activating it — windows come back on screen but the
    /// user's frontmost app keeps focus (unlike `activate`, which unhides AND focuses).
    @discardableResult
    public static func unhide(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.unhide() ?? false
    }

    public static func quit(bundleIdentifier: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }
        return app.terminate()
    }

    public static func quit(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.terminate()
    }

    public static func findPID(bundleIdentifier: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
    }

    public static func findPID(name: String) -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == name.lowercased()
        }?.processIdentifier
    }

    public static func frontmostApp() -> RunningApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return RunningApp(
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            pid: app.processIdentifier,
            isActive: app.isActive,
            isHidden: app.isHidden
        )
    }

    public static func resolvePID(from appString: String) -> pid_t? {
        // Try as bundle ID first
        if let pid = findPID(bundleIdentifier: appString) { return pid }
        // Try as app name
        if let pid = findPID(name: appString) { return pid }
        // Try as PID
        if let pidInt = Int32(appString) {
            if NSRunningApplication(processIdentifier: pidInt) != nil { return pidInt }
        }
        return nil
    }
}

public enum AppError: Error, LocalizedError {
    case appNotFound(String)
    case appNotRunning(String)
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .appNotRunning(let id): return "Application not running: \(id)"
        case .permissionDenied: return "Accessibility permission not granted"
        }
    }
}
