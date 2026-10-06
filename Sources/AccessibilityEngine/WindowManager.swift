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
    /// What AppKit knows about a running app. Captured on the MainActor so everything
    /// after it — the AX reads — can run on the app's own lane.
    struct AppIdentity: Sendable {
        let pid: pid_t
        let name: String
        let bundleId: String?
    }

    /// How long one app gets to answer before its entry degrades to window-server data.
    /// A hung app answers every AX read only after the messaging timeout, and
    /// `AXElement.attribute` retries `.cannotComplete` — so one unresponsive app costs
    /// several timeouts per read, and a lane busy with a long snapshot costs its whole
    /// walk. Neither should hold up the listing of every other app.
    public static let perAppDeadline: Double = 3.0

    /// List windows for one app, or for every regular app when `pid` is nil.
    ///
    /// Each app's AX reads run on that app's lane, fanned out across apps in parallel —
    /// the old version ran them serially on the MainActor, so one hung app froze the menu
    /// bar and an N-app listing cost N times the slowest app.
    public static func listWindows(pid: pid_t? = nil) async -> [WindowInfo] {
        // One window-server enumeration for the whole call. Per-app it would be a
        // full-system scan repeated once per running app. CoreGraphics only — no AppKit.
        let serverWindows = windowServerWindowsByPID()
        let apps = await MainActor.run { appIdentities(pid: pid) }

        return await withTaskGroup(of: (Int, [WindowInfo]).self) { group in
            for (order, app) in apps.enumerated() {
                let server = serverWindows[app.pid] ?? []
                group.addTask { (order, await windowsWithDeadline(app, serverWindows: server)) }
            }
            var byOrder: [Int: [WindowInfo]] = [:]
            for await (order, windows) in group { byOrder[order] = windows }
            return apps.indices.flatMap { byOrder[$0] ?? [] }
        }
    }

    /// MainActor only: NSRunningApplication/NSWorkspace.
    @MainActor
    private static func appIdentities(pid: pid_t?) -> [AppIdentity] {
        func identity(_ app: NSRunningApplication) -> AppIdentity {
            AppIdentity(pid: app.processIdentifier, name: app.localizedName ?? "Unknown", bundleId: app.bundleIdentifier)
        }
        if let pid {
            let app = NSRunningApplication(processIdentifier: pid)
            return [app.map(identity) ?? AppIdentity(pid: pid, name: "Unknown", bundleId: nil)]
        }
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(identity)
    }

    private static func windowsWithDeadline(_ app: AppIdentity, serverWindows: [ServerWindow]) async -> [WindowInfo] {
        await withDeadline(perAppDeadline, fallback: serverTier(app, serverWindows: serverWindows, excluding: [])) {
            await AXExecutor.app(app.pid).run { windowsForApp(app, serverWindows: serverWindows) }
        }
    }

    /// Resolves with `work`'s value, or `fallback` once `seconds` pass — whichever is
    /// first. Synchronous AX calls cannot be cancelled, so after a timeout the abandoned
    /// work keeps running on its own lane; that is the hung app's problem, and the point
    /// is that nobody else waits on it.
    static func withDeadline<T: Sendable>(_ seconds: Double, fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task {
                // Cancelled by the work finishing first; only an uninterrupted wait is a timeout.
                guard (try? await AXExecutor.pause(seconds)) != nil else { return }
                once.resume(fallback)
            }
            Task {
                once.resume(await work())
                timer.cancel()
            }
        }
    }

    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

        func resume(_ value: T) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
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
    /// wants listed. Matches the same floor `WindowCandidate.isPlausible` uses for capture.
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

    private static let windowAttributes = [
        kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen",
    ]

    /// Build a `WindowInfo` from one batched attribute read. Pure so the decoding is
    /// testable without a live window.
    static func windowInfo(attributes a: [String: CFTypeRef], app: AppIdentity, source: WindowSource) -> WindowInfo {
        WindowInfo(
            title: (a[kAXTitleAttribute] as? String) ?? "Untitled",
            bounds: CGRect(origin: AXValueExtract.point(a[kAXPositionAttribute]) ?? .zero,
                           size: AXValueExtract.size(a[kAXSizeAttribute]) ?? .zero),
            isMinimized: (a[kAXMinimizedAttribute] as? Bool) ?? false,
            isFullScreen: (a["AXFullScreen"] as? Bool) ?? false,
            appName: app.name,
            appBundleId: app.bundleId,
            pid: app.pid,
            source: source
        )
    }

    /// Window-server-only entries for `app`, skipping any whose frame matches one in
    /// `excluding` (already listed by a higher tier).
    private static func serverTier(_ app: AppIdentity, serverWindows: [ServerWindow], excluding known: [WindowInfo]) -> [WindowInfo] {
        var listed = known
        for server in serverWindows where !listed.contains(where: { sameWindow($0.bounds, server.frame) }) {
            listed.append(WindowInfo(
                title: server.title.isEmpty ? "Untitled" : server.title,
                bounds: server.frame,
                isMinimized: false,
                isFullScreen: false,
                appName: app.name,
                appBundleId: app.bundleId,
                pid: app.pid,
                source: .windowServer
            ))
        }
        return Array(listed.dropFirst(known.count))
    }

    /// Runs on the app's lane: AX enumeration, one batched read per window.
    private static func windowsForApp(_ app: AppIdentity, serverWindows: [ServerWindow]) -> [WindowInfo] {
        let appElement = AXElement.application(pid: app.pid)

        func describe(_ window: AXElement, source: WindowSource) -> WindowInfo {
            windowInfo(attributes: window.readAttributes(windowAttributes), app: app, source: source)
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
        return recovered + serverTier(app, serverWindows: serverWindows, excluding: recovered)
    }

    public static func setWindowBounds(pid: pid_t, windowIndex: Int = 0,
                                       position: CGPoint? = nil, size: CGSize? = nil) -> Bool {
        let appElement = AXElement.application(pid: pid)
        let windows = appElement.windows
        guard windowIndex >= 0, windowIndex < windows.count else { return false }
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
        guard windowIndex >= 0, windowIndex < windows.count else { return false }
        return windows[windowIndex].setAttribute(kAXMinimizedAttribute, value: kCFBooleanTrue)
    }

    public static func restore(pid: pid_t, windowIndex: Int = 0) -> Bool {
        let appElement = AXElement.application(pid: pid)
        let windows = appElement.windows
        guard windowIndex >= 0, windowIndex < windows.count else { return false }
        let window = windows[windowIndex]
        _ = window.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
        return window.raise()
    }

    public static func getWindowBounds(pid: pid_t, windowIndex: Int = 0) -> CGRect? {
        let appElement = AXElement.application(pid: pid)
        let windows = appElement.windows
        guard windowIndex >= 0, windowIndex < windows.count else { return nil }
        let a = windows[windowIndex].readAttributes([kAXPositionAttribute, kAXSizeAttribute])
        guard let origin = AXValueExtract.point(a[kAXPositionAttribute]),
              let size = AXValueExtract.size(a[kAXSizeAttribute]) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
