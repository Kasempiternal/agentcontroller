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
    /// True once we've already done at least one poll; used to back off the timer.
    private var didFirstPoll = false

    /// Records an MCP tool call for telemetry rendered in StatusView / MenuBarView.
    /// Called from the (off-main, @Sendable) onToolCall closure by hopping to MainActor.
    func recordToolCall(_ name: String) {
        requestCount += 1
        lastToolName = name
        lastRequestTime = Date()
    }

    func updatePermissions() {
        accessibilityGranted = PermissionChecker.isAccessibilityGranted
        screenRecordingGranted = PermissionChecker.isScreenRecordingGranted
        if accessibilityGranted && screenRecordingGranted {
            stopPermissionPolling()
        } else if didFirstPoll {
            // A permission is still missing after the first quick poll — back off
            // from 2s to a lightweight 10s cadence so we're not busy-polling forever.
            scheduleTimer(interval: 10.0)
        }
    }

    func startPermissionPolling() {
        // First poll on a tight 2s cadence so newly-granted permissions reflect fast.
        didFirstPoll = false
        scheduleTimer(interval: 2.0)
    }

    private func scheduleTimer(interval: TimeInterval) {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.didFirstPoll = true
                self.updatePermissions()
            }
        }
    }

    func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}
