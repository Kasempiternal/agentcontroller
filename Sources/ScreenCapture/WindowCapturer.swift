import Foundation
import ScreenCaptureKit
import AppKit

/// Short-lived cache for SCShareableContent so bursts of screenshots share one
/// system-wide window enumeration. Enumeration costs 50-200ms; 100ms TTL keeps
/// staleness bounded. Invalidated on any window-affecting tool (activate, launch,
/// quit, set/minimize/restore window).
public actor ShareableContentCache {
    public static let shared = ShareableContentCache()

    private var entry: (content: SCShareableContent, at: Date)?
    private var inFlight: Task<SCShareableContent, Error>?
    private let ttl: TimeInterval = 0.1

    public func current() async throws -> SCShareableContent {
        if let entry, Date().timeIntervalSince(entry.at) < ttl {
            return entry.content
        }

        // Coalesce: if an enumeration is already running, every concurrent awaiter
        // shares its single result instead of each kicking off its own 50-200ms scan.
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<SCShareableContent, Error> {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        inFlight = task

        defer { inFlight = nil }
        do {
            let fresh = try await task.value
            entry = (fresh, Date())
            return fresh
        } catch {
            // Leave the cache empty so the next caller retries a fresh enumeration.
            throw error
        }
    }

    public func invalidate() {
        entry = nil
    }
}

public struct WindowCapturer {
    /// Default agent-friendly cap: a ~1400px longest side keeps base64 small while
    /// staying legible. Callers may override with `maxLongestSide`.
    public static let defaultMaxLongestSide = 1400

    public static func captureWindow(
        pid: pid_t,
        windowTitle: String? = nil,
        windowOrigin: CGPoint? = nil,
        scale: CGFloat = 2.0,
        maxLongestSide: Int? = defaultMaxLongestSide,
        format: ImageFormat = .jpeg,
        quality: CGFloat = 0.7
    ) async throws -> (data: Data, mimeType: String) {
        let content = try await ShareableContentCache.shared.current()
        let owned = content.windows.filter { $0.owningApplication?.processID == pid }
        guard !owned.isEmpty else { throw CaptureError.windowNotFound }

        // Title is strict when it is the ONLY disambiguator (a user-supplied title that
        // matches nothing must error, not silently capture a different window). When an
        // origin is also provided (windowIndex path: both derived from the same AX
        // window), a title miss falls through to nearest-origin matching.
        var picked: SCWindow?
        if let windowTitle, !windowTitle.isEmpty {
            picked = owned.first { $0.title == windowTitle }
            if picked == nil, windowOrigin == nil { throw CaptureError.windowNotFound }
        }
        if picked == nil, let windowOrigin {
            picked = nearestWindow(to: windowOrigin, in: owned)
        }
        if picked == nil, windowTitle == nil || windowTitle!.isEmpty {
            picked = bestWindow(in: owned)
        }
        guard let window = picked else { throw CaptureError.windowNotFound }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = false
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return ImageEncoder.encode(image, maxLongestSide: maxLongestSide, format: format, quality: quality)
        } catch {
            throw CaptureError.surfaceUnavailable(
                title: window.title ?? "", onScreen: window.isOnScreen, underlying: error.localizedDescription
            )
        }
    }

    // A note for whoever reads the `catch` above and reaches for a fallback: the obvious
    // one does not work. `SCContentFilter(display:including:[window])` DOES return an
    // image for a window whose surface is gone — a blank white frame of exactly the right
    // dimensions. Wiring it in would turn an honest error into a screenshot that passes
    // every check an agent can make and shows nothing. Verified against a Safari window
    // whose Space was inactive: `desktopIndependentWindow` failed, the display filter
    // "succeeded", and the PNG was blank. There is no supported replacement either —
    // `CGWindowListCreateImage` is unavailable from the macOS 15 SDK onward.

    public static func captureScreen(
        screenIndex: Int = 0,
        scale: CGFloat = 1.0,
        maxLongestSide: Int? = defaultMaxLongestSide,
        format: ImageFormat = .jpeg,
        quality: CGFloat = 0.7
    ) async throws -> (data: Data, mimeType: String) {
        let content = try await ShareableContentCache.shared.current()

        guard screenIndex < content.displays.count else {
            throw CaptureError.displayNotFound
        }

        let display = content.displays[screenIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ImageEncoder.encode(image, maxLongestSide: maxLongestSide, format: format, quality: quality)
    }

    /// Captures a sub-rect of a *specific* window. `region` is in that window's local
    /// coordinate space (top-left origin). `windowID`/`windowTitle`/`windowOrigin`
    /// disambiguate which window to grab so the crop lines up for multi-window apps
    /// (sheets, inspectors). `sourceRect` crops at capture time so no separate
    /// decode/crop pass is needed.
    public static func captureRegion(
        pid: pid_t,
        region: CGRect,
        scale: CGFloat = 2.0,
        windowID: CGWindowID? = nil,
        windowTitle: String? = nil,
        windowOrigin: CGPoint? = nil,
        maxLongestSide: Int? = defaultMaxLongestSide,
        format: ImageFormat = .jpeg,
        quality: CGFloat = 0.7
    ) async throws -> (data: Data, mimeType: String) {
        let content = try await ShareableContentCache.shared.current()
        guard let window = resolveWindow(
            in: content,
            pid: pid,
            windowID: windowID,
            windowTitle: windowTitle,
            windowOrigin: windowOrigin
        ) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = true
        config.width = Int(region.width * scale)
        config.height = Int(region.height * scale)
        config.sourceRect = region
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ImageEncoder.encode(image, maxLongestSide: maxLongestSide, format: format, quality: quality)
    }

    /// Pick the SCWindow that matches the AX window we measured the element against.
    /// Priority: exact CGWindowID → title match → closest frame origin → first owned.
    private static func resolveWindow(
        in content: SCShareableContent,
        pid: pid_t,
        windowID: CGWindowID?,
        windowTitle: String?,
        windowOrigin: CGPoint?
    ) -> SCWindow? {
        let owned = content.windows.filter { $0.owningApplication?.processID == pid }
        guard !owned.isEmpty else { return nil }

        if let windowID, let exact = owned.first(where: { $0.windowID == windowID }) {
            return exact
        }
        if let windowTitle, !windowTitle.isEmpty,
           let byTitle = owned.first(where: { $0.title == windowTitle }) {
            return byTitle
        }
        if let windowOrigin {
            return nearestWindow(to: windowOrigin, in: owned)
        }
        return bestWindow(in: owned)
    }

    /// SCWindow.frame is top-left origin in global (screen) points — same space as
    /// AXPosition — so match the window whose origin is nearest the measured one.
    static func nearestWindow(to origin: CGPoint, in owned: [SCWindow]) -> SCWindow? {
        owned.min(by: { lhs, rhs in
            hypot(lhs.frame.origin.x - origin.x, lhs.frame.origin.y - origin.y) <
            hypot(rhs.frame.origin.x - origin.x, rhs.frame.origin.y - origin.y)
        })
    }

    /// The most plausible "main" window when nothing disambiguates. Enumeration includes
    /// off-screen windows (tooltips, status-item panels, zero-sized helpers), so raw
    /// `.first` could pick garbage: restrict to layer-0 windows of real size, prefer
    /// on-screen, then the largest area.
    static func bestWindow(in owned: [SCWindow]) -> SCWindow? {
        let plausible = owned.filter { $0.windowLayer == 0 && $0.frame.width >= 40 && $0.frame.height >= 40 }
        let pool = plausible.isEmpty ? owned : plausible
        return pool.max(by: { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen { return rhs.isOnScreen }
            return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        })
    }
}

public enum CaptureError: Error, LocalizedError {
    case windowNotFound
    case displayNotFound
    case captureFailure
    case permissionDenied
    /// The window was found but ScreenCaptureKit could not read it. Raw SCKit reports
    /// this as "Failed to start stream due to audio/video capture failure", which reads
    /// like a broken permission or a broken machine and sends the caller off checking
    /// both. It is neither: some apps release their window's backing surface while the
    /// window is off-screen, leaving nothing to capture. Reproduced with Safari while its
    /// Space was inactive, in a standalone process, with screen recording granted — and
    /// TextEdit in the identical state captured fine, so it is per-app behaviour.
    case surfaceUnavailable(title: String, onScreen: Bool, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .windowNotFound: return "Window not found. Is the app running and visible?"
        case .displayNotFound: return "Display not found"
        case .captureFailure: return "Failed to capture screenshot"
        case .permissionDenied: return "Screen recording permission not granted. Go to System Settings > Privacy & Security > Screen Recording"
        case .surfaceUnavailable(let title, let onScreen, let underlying):
            let which = title.isEmpty ? "The window" : "Window '\(title)'"
            let where_ = onScreen
                ? "It IS on screen, so this is unusual — retry once; if it persists the app is refusing capture."
                : "It is currently OFF SCREEN (another Space, or fully hidden), and some apps drop their window's backing surface in that state, leaving nothing to read. Browsers and GPU-composited apps do it most reliably (confirmed with Safari and Ghostty); TextEdit in the identical state captures fine, so it is per-app behaviour rather than a rule about off-screen windows."
            return "\(which) exists but has no capturable content. \(where_) This is not a permissions problem: check_permissions still reports screenRecording, and screenshot_screen still works. Workarounds: screenshot_screen if the window is visible on the current Space, unhide_app/restore_window if it is hidden or minimized, or read the UI with snapshot/read_all_text instead of pixels. (Underlying: \(underlying))"
        }
    }
}
