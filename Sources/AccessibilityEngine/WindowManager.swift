import AppKit
import Foundation

public struct WindowInfo: Sendable {
    public let title: String
    public let bounds: CGRect
    public let isMinimized: Bool
    public let isFullScreen: Bool
    public let appName: String
    public let appBundleId: String?
    public let pid: pid_t
    public let index: Int
}

public struct WindowManager {
    public static func listWindows(pid: pid_t? = nil) -> [WindowInfo] {
        if let pid {
            return windowsForApp(pid: pid)
        }
        // All visible windows
        var allWindows: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            allWindows.append(contentsOf: windowsForApp(pid: app.processIdentifier))
        }
        return allWindows
    }

    private static func windowsForApp(pid: pid_t) -> [WindowInfo] {
        let appElement = AXElement.application(pid: pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? "Unknown"
        let bundleId = app?.bundleIdentifier

        return appElement.windows.enumerated().compactMap { (index, window) in
            let title = window.title ?? "Untitled"
            let pos = window.position ?? .zero
            let size = window.size ?? .zero
            let isMinimized = (window.attribute(kAXMinimizedAttribute) as Bool?) ?? false
            let isFullScreen = (window.attribute("AXFullScreen") as Bool?) ?? false

            return WindowInfo(
                title: title,
                bounds: CGRect(origin: pos, size: size),
                isMinimized: isMinimized,
                isFullScreen: isFullScreen,
                appName: appName,
                appBundleId: bundleId,
                pid: pid,
                index: index
            )
        }
    }

    public static func setWindowBounds(pid: pid_t, windowIndex: Int = 0,
                                       position: CGPoint? = nil, size: CGSize? = nil) -> Bool {
        let appElement = AXElement.application(pid: pid)
        let windows = appElement.windows
        guard windowIndex < windows.count else { return false }
        let window = windows[windowIndex]

        var success = true
        if let pos = position {
            success = window.setPosition(pos) && success
        }
        if let sz = size {
            success = window.setSize(sz) && success
        }
        return success
    }

    public static func minimize(pid: pid_t, windowIndex: Int = 0) -> Bool {
        let appElement = AXElement.application(pid: pid)
        let windows = appElement.windows
        guard windowIndex < windows.count else { return false }
        return windows[windowIndex].setAttribute(kAXMinimizedAttribute, value: kCFBooleanTrue)
    }

    public static func restore(pid: pid_t, windowIndex: Int = 0) -> Bool {
        let appElement = AXElement.application(pid: pid)
        let windows = appElement.windows
        guard windowIndex < windows.count else { return false }
        let window = windows[windowIndex]
        _ = window.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
        return window.raise()
    }

    public static func getWindowBounds(pid: pid_t, windowIndex: Int = 0) -> CGRect? {
        let appElement = AXElement.application(pid: pid)
        let windows = appElement.windows
        guard windowIndex < windows.count else { return nil }
        return windows[windowIndex].frame
    }
}
