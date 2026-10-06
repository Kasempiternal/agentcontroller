import SwiftUI

/// The menu-bar popover: the glanceable subset of the main window — is it live, is Focus
/// Guard on, what did the agent just do — plus a way into the full window.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AgentController").font(.headline)
                    Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                HStack(spacing: 4) {
                    LiveDot(color: state.isServerRunning ? Theme.ok : Theme.down,
                            pulsing: state.isServerRunning, size: 7)
                    Text(state.isServerRunning ? "Live" : "Stopped")
                        .font(.caption.weight(.semibold))
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    StatTile(value: "\(state.requestCount)", label: "Tool calls", systemImage: "bolt.fill")
                    StatTile(value: Formatters.uptime(since: state.serverStartedAt, now: context.date),
                             label: "Uptime", systemImage: "clock.fill")
                }
            }

            if !(state.accessibilityGranted && state.screenRecordingGranted) {
                Label("A permission is missing — open the window to fix it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
            }

            Toggle(isOn: $state.focusGuardEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Focus Guard").font(.callout.weight(.semibold))
                    Text("Never steal my focus or cursor").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)

            if !state.recentCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        VStack(spacing: 3) {
                            ForEach(state.recentCalls.prefix(3)) { call in
                                HStack {
                                    Text(call.name).font(.caption.monospaced()).lineLimit(1)
                                    Spacer()
                                    Text(Formatters.ago(call.at, now: context.date))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: {
                    Label("Open AgentController", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentStrong)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }
}
