import AccessibilityEngine
import Foundation
import SwiftUI

@Observable
@MainActor
public final class AppState {
    var isServerRunning = false
    var serverPort: UInt16 = 0
    var requestCount = 0
    var lastRequestTime: Date?
    var lastToolName: String?
    var accessibilityGranted = false
    var screenRecordingGranted = false
    private var permissionTimer: Timer?

    func updatePermissions() {
        accessibilityGranted = PermissionChecker.isAccessibilityGranted
        screenRecordingGranted = PermissionChecker.isScreenRecordingGranted
        if accessibilityGranted && screenRecordingGranted {
            stopPermissionPolling()
        }
    }

    func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.updatePermissions()
            }
        }
    }

    func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}
