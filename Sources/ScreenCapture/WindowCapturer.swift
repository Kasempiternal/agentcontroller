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
        scale: CGFloat = 2.0,
        maxLongestSide: Int? = defaultMaxLongestSide,
        format: ImageFormat = .jpeg,
        quality: CGFloat = 0.7
    ) async throws -> (data: Data, mimeType: String) {
        let content = try await ShareableContentCache.shared.current()

        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid &&
            (windowTitle == nil || $0.title == windowTitle)
        }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = false
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ImageEncoder.encode(image, maxLongestSide: maxLongestSide, format: format, quality: quality)
    }

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
            // SCWindow.frame is top-left origin in global (screen) points — same space as
            // AXPosition — so match the window whose origin is nearest the measured one.
            return owned.min(by: { lhs, rhs in
                hypot(lhs.frame.origin.x - windowOrigin.x, lhs.frame.origin.y - windowOrigin.y) <
                hypot(rhs.frame.origin.x - windowOrigin.x, rhs.frame.origin.y - windowOrigin.y)
            })
        }
        return owned.first
    }
}

public enum CaptureError: Error, LocalizedError {
    case windowNotFound
    case displayNotFound
    case captureFailure
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .windowNotFound: return "Window not found. Is the app running and visible?"
        case .displayNotFound: return "Display not found"
        case .captureFailure: return "Failed to capture screenshot"
        case .permissionDenied: return "Screen recording permission not granted. Go to System Settings > Privacy & Security > Screen Recording"
        }
    }
}
