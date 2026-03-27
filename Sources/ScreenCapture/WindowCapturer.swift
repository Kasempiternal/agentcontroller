import Foundation
import ScreenCaptureKit
import AppKit

public struct WindowCapturer {
    public static func captureWindow(pid: pid_t, windowTitle: String? = nil, scale: CGFloat = 2.0) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

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

    public static func captureRegion(pid: pid_t, region: CGRect, scale: CGFloat = 2.0) async throws -> Data {
        let fullCapture = try await captureWindow(pid: pid, scale: scale)
        guard let fullImage = NSImage(data: fullCapture),
              let cgImage = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CaptureError.captureFailure
        }

        let scaledRegion = CGRect(
            x: region.origin.x * scale,
            y: region.origin.y * scale,
            width: region.width * scale,
            height: region.height * scale
        )

        guard let cropped = cgImage.cropping(to: scaledRegion) else {
            throw CaptureError.captureFailure
        }

        return ImageEncoder.pngData(from: cropped)
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
