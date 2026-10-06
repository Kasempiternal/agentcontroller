import SwiftUI
import AccessibilityEngine

struct StatusView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    stats
                    permissionsCard
                    focusGuardCard(isOn: $state.focusGuardEnabled)
                    activityCard
                    connectCard
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: 440, height: 680)
        .background(.background)
        .onAppear { state.updatePermissions() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("AgentController")
                    .font(.title2.weight(.bold))
                // Version sits directly under the name/logo, where the project wants it.
                Text("v" + appVersion)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
            }
            Spacer()
            serverPill
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .bottom) { Divider() }
    }

    private var serverPill: some View {
        HStack(spacing: 6) {
            LiveDot(color: state.isServerRunning ? Theme.ok : Theme.down,
                    pulsing: state.isServerRunning)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.isServerRunning ? "Live" : "Stopped")
                    .font(.callout.weight(.semibold))
                if state.isServerRunning {
                    Text(verbatim: ":\(state.serverPort)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.background.opacity(0.7)))
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.isServerRunning ? "MCP server live on port \(state.serverPort)" : "MCP server stopped")
    }

    // MARK: - Stats

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                StatTile(value: "\(state.requestCount)", label: "Tool calls", systemImage: "bolt.fill")
                StatTile(value: Formatters.uptime(since: state.serverStartedAt, now: context.date),
                         label: "Uptime", systemImage: "clock.fill")
                StatTile(value: state.defaultBrowserName, label: "Default browser", systemImage: "safari.fill")
            }
        }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        Card(title: "Permissions", systemImage: "lock.shield") {
            VStack(spacing: 10) {
                PermissionLine(
                    title: "Accessibility",
                    detail: "Inspect and operate app controls",
                    systemImage: "hand.point.up.left.fill",
                    granted: state.accessibilityGranted
                ) {
                    PermissionChecker.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Divider()
                PermissionLine(
                    title: "Screen Recording",
                    detail: "Screenshot windows, even in the background",
                    systemImage: "rectangle.dashed.badge.record",
                    granted: state.screenRecordingGranted
                ) {
                    // Fire the real TCC request first so macOS lists the app in the pane.
                    PermissionChecker.requestScreenRecording()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    // MARK: - Focus Guard

    private func focusGuardCard(isOn: Binding<Bool>) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "shield.lefthalf.filled.badge.checkmark" : "shield.slash")
                    .font(.title2)
                    .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.attention)
                    .frame(width: 28)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Focus Guard")
                        .font(.headline)
                    Text("Agents work in the background. Anything that would bring an app to the front or move your cursor is refused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Focus Guard", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        }
    }

    // MARK: - Activity

    private var activityCard: some View {
        Card(title: "Recent activity", systemImage: "waveform.path.ecg") {
            if state.recentCalls.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for an agent to connect…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    VStack(spacing: 6) {
                        ForEach(state.recentCalls.prefix(5)) { call in
                            HStack {
                                Circle()
                                    .fill(call.id == state.recentCalls.first?.id ? Theme.accent : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(call.name)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                Spacer()
                                Text(Formatters.ago(call.at, now: context.date))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .animation(.snappy, value: state.recentCalls)
                }
            }
        }
    }

    // MARK: - Connect

    private var connectCard: some View {
        Card(title: "Connect an agent", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 10) {
                Text(bridgeCommandDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                HStack(spacing: 8) {
                    CopyButton(text: SetupManager.mcpLaunch.command, label: "Copy command")
                    CopyButton(text: mcpJSONSnippet, label: "Copy .mcp.json")
                    Spacer()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(state.accessibilityGranted && state.screenRecordingGranted
                 ? "All set — agents can drive this Mac in the background."
                 : "Grant the permissions above to start.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Data

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// The command shown to the user, home-abbreviated: the compiled `agentcontroller mcp`
    /// when the installed CLI has it, else the bash bridge script.
    private var bridgeCommandDisplay: String {
        let launch = SetupManager.mcpLaunch
        let command = (launch.command as NSString).abbreviatingWithTildeInPath
        return ([command] + launch.args).joined(separator: " ")
    }

    private var mcpJSONSnippet: String {
        let launch = SetupManager.mcpLaunch
        let args = launch.args.isEmpty
            ? ""
            : ",\n      \"args\": [" + launch.args.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        return """
        {
          "mcpServers": {
            "agentcontroller": {
              "command": "\(launch.command)"\(args)
            }
          }
        }
        """
    }
}

private struct PermissionLine: View {
    let title: String
    let detail: String
    let systemImage: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(granted ? Theme.accent : Theme.attention)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill((granted ? Theme.accent : Theme.attention).opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                StatusChip(text: "Granted", color: Theme.ok)
            } else {
                Button("Enable", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStrong)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
