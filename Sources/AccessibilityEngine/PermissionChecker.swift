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
        // Heuristic: try to get window names from CGWindowList
        // If screen recording is not granted, window names will be nil
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // Check if any non-self window has a name
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return windowList.contains { info in
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if ownerPID == selfPID { return false }
            return info[kCGWindowName as String] as? String != nil
        }
    }
}
