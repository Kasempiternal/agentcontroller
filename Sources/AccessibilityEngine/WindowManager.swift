import AppKit
import Foundation

/// Where a window entry came from, which decides what a caller may do with it.
///
/// macOS excludes windows on an INACTIVE Space from an app element's
/// `kAXWindowsAttribute` *and* from its `kAXChildren`. With one app fullscreen, every
/// other app's windows vanish from AX: Safari, TextEdit, Preview, Xcode and QuickTime
/// all reported zero AX windows in a session where the window server listed their real
/// ones. `kAXFocusedWindow` survives that filter, but only for an app that has been key
/// at some point — background-launched apps that never took focus expose nothing.
///
/// So enumeration has three tiers of decreasing capability, and the caller has to know
/// which tier it got: only `accessibility` entries carry the AX window index that
/// `windowIndex`, `set_window_bounds`, `minimize_window` and `restore_window` address.
/// The AX window index lives INSIDE the accessibility case rather than beside the
/// source, so a window the AX layer never enumerated cannot carry one. Emitting a
/// positional index for a window-server entry would hand the caller a number that
/// addresses a different window — worse than admitting there isn't one — and this shape
/// makes that mistake impossible to write instead of merely documented.
public enum WindowSource: Sendable, Equatable {
    /// Enumerated from `kAXWindows`. Fully manipulable; the index is the one
    /// `windowIndex`, `set_window_bounds`, `minimize_window` and `restore_window` take.
    case accessibility(index: Int)
    /// Recovered from `kAXFocusedWindow` when `kAXWindows` came back empty. Readable and
    /// screenshot-able; the app's window array is empty, so there is no index.
    case focusedWindow
    /// Seen only by the window server (`CGWindowListCopyWindowInfo`). Proves the app owns
    /// a window of this size and title and that it can be screenshot by title, but no AX
    /// operation can reach it — and it cannot tell a window on an inactive Space from one
    /// the app has ordered out but not destroyed (AppKit keeps a dismissed panel around
    /// for reuse, and it stays in the window list). Nothing the window server exposes
    /// separates those two, so this tier over-reports rather than under-reports.
    case windowServer

    public var name: String {
        switch self {
        case .accessibility: return "accessibility"
        case .focusedWindow: return "focusedWindow"
        case .windowServer: return "windowServer"
        }
    }

    public var index: Int? {
        if case .accessibility(let index) = self { return index }
        return nil
    }
}

public struct WindowInfo: Sendable {
    public let title: String
    public let bounds: CGRect
    public let isMinimized: Bool
    public let isFullScreen: Bool
    public let appName: String
    public let appBundleId: String?
    public let pid: pid_t
    public let source: WindowSource
}

public struct WindowManager {
    public static func listWindows(pid: pid_t? = nil) -> [WindowInfo] {
        // One window-server enumeration for the whole call. Per-app it would be a
        // full-system scan repeated once per running app.
        let serverWindows = windowServerWindowsByPID()
        if let pid {
            return windowsForApp(pid: pid, serverWindows: serverWindows[pid] ?? [])
        }
        var allWindows: [WindowInfo] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appPID = app.processIdentifier
            allWindows.append(contentsOf: windowsForApp(pid: appPID, serverWindows: serverWindows[appPID] ?? []))
        }
        return allWindows
    }

    /// A window as the window server sees it. Same coordinate space as `AXPosition`
    /// (top-left origin, global points).
    struct ServerWindow: Sendable {
        let title: String
        let frame: CGRect
    }

    /// Real, user-facing windows per PID, straight from the window server. Filters to
    /// layer 0 (ordinary app windows — not menus, popovers, tooltips or status items)
    /// and to a size a person could interact with, which also drops the 1-pixel-tall
    /// helper and menu-bar-shadow windows AppKit keeps around.
    private static func windowServerWindowsByPID() -> [pid_t: [ServerWindow]] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var out: [pid_t: [ServerWindow]] = [:]
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= minimumWindowSide, frame.height >= minimumWindowSide
            else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            out[ownerPID, default: []].append(ServerWindow(title: title, frame: frame))
        }
        return out
    }

    /// Below this on either side a "window" is a helper surface, not something a QA run
    /// wants listed. Matches the same floor `WindowCapturer.bestWindow` uses.
    private static let minimumWindowSide: CGFloat = 40

    /// Two windows are the same window if their frames land on the same point and size.
    /// Titles are unreliable for matching — the window server reports an empty title for
    /// windows AX titles as "Untitled", and vice-versa.
    private static let frameMatchTolerance: CGFloat = 2

    static func sameWindow(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= frameMatchTolerance
            && abs(a.origin.y - b.origin.y) <= frameMatchTolerance
            && abs(a.width - b.width) <= frameMatchTolerance
            && abs(a.height - b.height) <= frameMatchTolerance
    }

    private static func windowsForApp(pid: pid_t, serverWindows: [ServerWindow]) -> [WindowInfo] {
        let appElement = AXElement.application(pid: pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? "Unknown"
        let bundleId = app?.bundleIdentifier

        func describe(_ window: AXElement, source: WindowSource) -> WindowInfo {
            WindowInfo(
                title: window.title ?? "Untitled",
                bounds: CGRect(origin: window.position ?? .zero, size: window.size ?? .zero),
                isMinimized: (window.attribute(kAXMinimizedAttribute) as Bool?) ?? false,
                isFullScreen: (window.attribute("AXFullScreen") as Bool?) ?? false,
                appName: appName,
                appBundleId: bundleId,
                pid: pid,
                source: source
            )
        }

        let axWindows = appElement.windows
        if !axWindows.isEmpty {
            return axWindows.enumerated().map { describe($1, source: .accessibility(index: $0)) }
        }

        // AX enumerated nothing. Recover what the lower tiers can still see rather than
        // reporting an empty list for an app that plainly has windows on screen.
        var recovered: [WindowInfo] = []
        if let focused = appElement.focusedWindow {
            recovered.append(describe(focused, source: .focusedWindow))
        }
        for server in serverWindows where !recovered.contains(where: { sameWindow($0.bounds, server.frame) }) {
            recovered.append(WindowInfo(
                title: server.title.isEmpty ? "Untitled" : server.title,
                bounds: server.frame,
                isMinimized: false,
                isFullScreen: false,
                appName: appName,
                appBundleId: bundleId,
                pid: pid,
                source: .windowServer
            ))
        }
        return recovered
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
