import Foundation
import ScreenCaptureKit
import AppKit

public struct WindowCapturer {
    /// Default agent-friendly cap: a ~1400px longest side keeps base64 small while
    /// staying legible. Callers may override with `maxLongestSide`.
    public static let defaultMaxLongestSide = 1400

    /// `scale` overrides the pixels-per-point factor; nil uses the display's backing
    /// scale, reduced as needed so the output lands at `maxLongestSide` without a CPU
    /// resample (see `CaptureSizing`).
    public static func captureWindow(
        pid: pid_t,
        windowTitle: String? = nil,
        windowOrigin: CGPoint? = nil,
        scale: CGFloat? = nil,
        maxLongestSide: Int? = defaultMaxLongestSide,
        format: ImageFormat = .jpeg,
        quality: CGFloat = 0.7
    ) async throws -> (data: Data, mimeType: String) {
        try await ShareableContentCache.shared.withContent { content, isFresh in
            let window = try resolveWindow(
                in: content, isFresh: isFresh, pid: pid, windowTitle: windowTitle, windowOrigin: windowOrigin
            )
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = CaptureSizing.pixelSize(
                points: window.frame.size,
                backingScale: scale ?? CGFloat(filter.pointPixelScale),
                maxLongestSide: maxLongestSide
            )
            let config = SCStreamConfiguration()
            config.scalesToFit = true
            config.width = size.width
            config.height = size.height
            config.showsCursor = false
            config.captureResolution = .best

            let image: CGImage
            do {
                image = try await capture(filter, config)
            } catch CaptureError.permissionDenied {
                throw CaptureError.permissionDenied
            } catch {
                throw CaptureError.surfaceUnavailable(
                    title: window.title ?? "", onScreen: window.isOnScreen, underlying: error.localizedDescription
                )
            }
            return try ImageEncoder.encode(image, maxLongestSide: maxLongestSide, format: format, quality: quality)
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
        scale: CGFloat? = nil,
        maxLongestSide: Int? = defaultMaxLongestSide,
        format: ImageFormat = .jpeg,
        quality: CGFloat = 0.7
    ) async throws -> (data: Data, mimeType: String) {
        try await ShareableContentCache.shared.withContent { content, _ in
            guard content.displays.indices.contains(screenIndex) else {
                throw CaptureError.displayNotFound
            }

            let display = content.displays[screenIndex]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let size = CaptureSizing.pixelSize(
                points: CGSize(width: display.width, height: display.height),
                backingScale: scale ?? CGFloat(filter.pointPixelScale),
                maxLongestSide: maxLongestSide
            )
            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            config.showsCursor = false

            let image = try await capture(filter, config)
            return try ImageEncoder.encode(image, maxLongestSide: maxLongestSide, format: format, quality: quality)
        }
    }

    /// Captures a sub-rect of a *specific* window. `region` is in that window's local
    /// coordinate space (top-left origin). `windowID`/`windowTitle`/`windowOrigin`
    /// disambiguate which window to grab so the crop lines up for multi-window apps
    /// (sheets, inspectors). `sourceRect` crops at capture time so no separate
    /// decode/crop pass is needed.
    public static func captureRegion(
        pid: pid_t,
        region: CGRect,
        scale: CGFloat? = nil,
        windowID: CGWindowID? = nil,
        windowTitle: String? = nil,
        windowOrigin: CGPoint? = nil,
        maxLongestSide: Int? = defaultMaxLongestSide,
        format: ImageFormat = .jpeg,
        quality: CGFloat = 0.7
    ) async throws -> (data: Data, mimeType: String) {
        guard region.width > 0, region.height > 0 else { throw CaptureError.emptyRegion }

        return try await ShareableContentCache.shared.withContent { content, isFresh in
            let window = try resolveWindow(
                in: content, isFresh: isFresh, pid: pid,
                windowID: windowID, windowTitle: windowTitle, windowOrigin: windowOrigin
            )
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = CaptureSizing.pixelSize(
                points: region.size,
                backingScale: scale ?? CGFloat(filter.pointPixelScale),
                maxLongestSide: maxLongestSide
            )
            let config = SCStreamConfiguration()
            config.scalesToFit = true
            config.width = size.width
            config.height = size.height
            config.sourceRect = region
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await capture(filter, config)
            return try ImageEncoder.encode(image, maxLongestSide: maxLongestSide, format: format, quality: quality)
        }
    }

    /// One place that turns SCK's "user declined" into `.permissionDenied`, so a missing
    /// Screen Recording grant reads the same from every capture path.
    private static func capture(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.classify(error)
        }
    }

    /// Resolves the SCWindow the hints describe among `pid`'s windows. On a cached
    /// listing a non-exact pick counts as a miss: the origin AX measured matches no
    /// listed window, so the window has moved or opened since the listing was taken and
    /// `withContent` should retry on a fresh one rather than capture the wrong window.
    static func resolveWindow(
        in content: SCShareableContent,
        isFresh: Bool,
        pid: pid_t,
        windowID: CGWindowID? = nil,
        windowTitle: String?,
        windowOrigin: CGPoint?
    ) throws -> SCWindow {
        let owned = content.windows.filter { $0.owningApplication?.processID == pid }
        guard let pick = WindowPicker.pick(
                  from: owned.map(WindowCandidate.init),
                  windowID: windowID, title: windowTitle, origin: windowOrigin
              ),
              isFresh || pick.isExact,
              let window = owned.first(where: { $0.windowID == pick.window.id })
        else { throw CaptureError.windowNotFound }
        return window
    }
}

public enum CaptureError: Error, LocalizedError {
    case windowNotFound
    case displayNotFound
    case emptyRegion
    case encodingFailed
    /// Screen Recording is not granted. Raised from every capture path, not only the
    /// window one, so the caller sees the same instruction whichever tool they used.
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
        case .emptyRegion: return "The region to capture has no area (zero width or height)"
        case .encodingFailed: return "The screenshot was captured but could not be encoded as an image"
        case .permissionDenied: return "Screen Recording permission is not granted to AgentController. Open System Settings > Privacy & Security > Screen Recording, enable AgentController, then quit and reopen it (macOS applies a new Screen Recording grant only to processes started afterwards). check_permissions reports the current state."
        case .surfaceUnavailable(let title, let onScreen, let underlying):
            let which = title.isEmpty ? "The window" : "Window '\(title)'"
            let where_ = onScreen
                ? "It IS on screen, so this is unusual — retry once; if it persists the app is refusing capture."
                : "It is currently OFF SCREEN (another Space, or fully hidden), and some apps drop their window's backing surface in that state, leaving nothing to read. Browsers and GPU-composited apps do it most reliably (confirmed with Safari and Ghostty); TextEdit in the identical state captures fine, so it is per-app behaviour rather than a rule about off-screen windows."
            return "\(which) exists but has no capturable content. \(where_) This is not a permissions problem: check_permissions still reports screenRecording, and screenshot_screen still works. Workarounds: screenshot_screen if the window is visible on the current Space, unhide_app/restore_window if it is hidden or minimized, or read the UI with snapshot/read_all_text instead of pixels. (Underlying: \(underlying))"
        }
    }
}

extension CaptureError {
    /// ScreenCaptureKit reports a missing Screen Recording grant as
    /// `SCStreamError.userDeclined` (-3801), from `SCShareableContent` and from every
    /// capture call alike. Anything else passes through untouched.
    static func classify(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return CaptureError.permissionDenied
        }
        return error
    }
}
