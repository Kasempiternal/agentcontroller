import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct PermissionChecker {
    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system Screen Recording prompt and — critically on macOS 15+ —
    /// registers the app in Settings > Privacy > Screen Recording so the user can
    /// toggle it on. Calling CGRequestScreenCaptureAccess alone is NOT enough on
    /// Sequoia; we must also touch ScreenCaptureKit (SCShareableContent) because
    /// that's the API path TCC watches to surface the app in the list.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        // Fire-and-forget ScreenCaptureKit call; triggers TCC registration on macOS 15+.
        // We don't care about the result — the side effect is what matters.
        Task.detached {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        return granted
    }
}
