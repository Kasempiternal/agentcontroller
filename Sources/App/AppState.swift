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

    func updatePermissions() {
        accessibilityGranted = PermissionChecker.isAccessibilityGranted
        screenRecordingGranted = PermissionChecker.isScreenRecordingGranted
    }
}

import AccessibilityEngine
