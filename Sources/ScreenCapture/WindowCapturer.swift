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
    private let ttl: TimeInterval = 0.1

    public func current() async throws -> SCShareableContent {
        if let entry, Date().timeIntervalSince(entry.at) < ttl {
            return entry.content
        }
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        entry = (fresh, Date())
        return fresh
    }

    public func invalidate() {
        entry = nil
    }
}

public struct WindowCapturer {
    public static func captureWindow(pid: pid_t, windowTitle: String? = nil, scale: CGFloat = 2.0) async throws -> Data {
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
        return ImageEncoder.pngData(from: image)
    }

    public static func captureScreen(screenIndex: Int = 0, scale: CGFloat = 1.0) async throws -> Data {
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
        return ImageEncoder.pngData(from: image)
    }

    /// Captures a sub-rect of a window. `sourceRect` crops at capture time so no
    /// separate decode/crop pass is needed.
    public static func captureRegion(pid: pid_t, region: CGRect, scale: CGFloat = 2.0) async throws -> Data {
        let content = try await ShareableContentCache.shared.current()
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid }) else {
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
        return ImageEncoder.pngData(from: image)
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
