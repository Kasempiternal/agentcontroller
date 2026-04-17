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

    /// Triggers the system Screen Recording prompt if not yet granted.
    /// For notarized builds, CGRequestScreenCaptureAccess is sufficient to register
    /// the app in Settings > Privacy > Screen Recording. (Non-notarized builds also
    /// need an SCShareableContent call, but we're notarized so we skip that —
    /// it was causing a deadlock against MainActor-bound tool handlers.)
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
