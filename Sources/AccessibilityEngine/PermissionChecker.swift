import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionChecker {
    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public static var isScreenRecordingGranted: Bool {
        // Reliable check: CGPreflightScreenCaptureAccess reflects the actual
        // capture permission, not window-name visibility (which can false-positive
        // right after a TCC change while window metadata is still cached).
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system Screen Recording prompt if not yet granted. Returns
    /// the current grant status. The prompt only appears once per bundle ID —
    /// if the user dismisses it, subsequent calls just return false until they
    /// toggle the permission on in System Settings.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
