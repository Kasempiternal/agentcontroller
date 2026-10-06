import AccessibilityEngine
import Foundation
import MCPTools
import SwiftUI

@Observable
@MainActor
public final class AppState {
    var isServerRunning = false
    var serverPort: UInt16 = 0
    var requestCount = 0
    var lastRequestTime: Date?
    var lastToolName: String?
    /// When the MCP server last came up — drives the uptime readout.
    var serverStartedAt: Date?
    /// Refreshed with the permission poll — the user can change it in System Settings.
    var defaultBrowserName = BrowserResolver.systemDefault()?.name ?? "—"
    /// Newest first, capped at `recentCallLimit`; the activity feed in both windows.
    var recentCalls: [ToolCall] = []
    static let recentCallLimit = 8

    struct ToolCall: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let at: Date
    }
    var accessibilityGranted = false
    var screenRecordingGranted = false
    /// UI mirror of `FocusGuard` (the engine-side source of truth read by the
    /// tool dispatcher). Persisted via UserDefaults inside FocusGuard.
    var focusGuardEnabled = FocusGuard.isEnabled {
        didSet { FocusGuard.setEnabled(focusGuardEnabled) }
    }
    private var permissionTimer: Timer?
    /// True once we've already done at least one poll; used to back off the timer.
    private var didFirstPoll = false

    /// Records an MCP tool call for telemetry rendered in StatusView / MenuBarView.
    /// Called from the (off-main, @Sendable) onToolCall closure by hopping to MainActor.
    func recordToolCall(_ name: String) {
        let now = Date()
        requestCount += 1
        lastToolName = name
        lastRequestTime = now
        recentCalls.insert(ToolCall(name: name, at: now), at: 0)
        if recentCalls.count > Self.recentCallLimit {
            recentCalls.removeLast(recentCalls.count - Self.recentCallLimit)
        }
    }

    func updatePermissions() {
        accessibilityGranted = PermissionChecker.isAccessibilityGranted
        screenRecordingGranted = PermissionChecker.isScreenRecordingGranted
        defaultBrowserName = BrowserResolver.systemDefault()?.name ?? "—"
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
