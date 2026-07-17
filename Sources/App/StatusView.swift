import SwiftUI
import AccessibilityEngine

struct StatusView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(.teal)
                Text("Macoestro")
                    .font(.title2.bold())
                Spacer()
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Server Status
            VStack(alignment: .leading, spacing: 12) {
                StatusRow(
                    icon: "circle.fill",
                    color: state.isServerRunning ? .green : .red,
                    title: "MCP Server",
                    detail: state.isServerRunning ? "Running on port \(state.serverPort)" : "Stopped"
                )

                StatusRow(
                    icon: "circle.fill",
                    color: state.accessibilityGranted ? .green : .orange,
                    title: "Accessibility",
                    detail: state.accessibilityGranted ? "Granted" : "Not granted"
                )

                StatusRow(
                    icon: "circle.fill",
                    color: state.screenRecordingGranted ? .green : .orange,
                    title: "Screen Recording",
                    detail: state.screenRecordingGranted ? "Granted" : "Not granted"
                )

                Divider()

                Toggle(isOn: $state.focusGuardEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus Guard")
                            .font(.callout.bold())
                        Text("Refuse activate_app and foreground:true so a QA run can never steal your focus or cursor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(.teal)

                Divider()

                if state.requestCount > 0 {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                        Text("Requests: \(state.requestCount)")
                            .font(.callout)
                        Spacer()
                        if let tool = state.lastToolName {
                            Text("Last: \(tool)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text("Waiting for connections...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()

            Divider()

            // Actions
            HStack {
                if !state.accessibilityGranted {
                    Button("Grant Accessibility") {
                        PermissionChecker.requestAccessibility()
                        // Mirror the Screen Recording flow: also deep-link to the
                        // Accessibility pane so the user can flip the toggle directly.
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                }

                if !state.screenRecordingGranted {
                    Button("Grant Screen Recording") {
                        let granted = PermissionChecker.requestScreenRecording()
                        if !granted {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                }

                Spacer()

                Button("Refresh") {
                    state.updatePermissions()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            // Bridge path
            VStack(alignment: .leading) {
                Text("MCP Bridge Script")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                HStack {
                    Text("~/.macoestro/macoestro-mcp-bridge.sh")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            SetupManager.bridgeScript.path,
                            forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy path")
                }

                // Copy-able .mcp.json snippet built from the bridge path — paste
                // straight into a project's .mcp.json.
                Text(".mcp.json")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                HStack(alignment: .top) {
                    Text(mcpJSONSnippet)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpJSONSnippet, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy .mcp.json snippet")
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 400)
        .onAppear {
            state.updatePermissions()
        }
    }

    private var mcpJSONSnippet: String {
        """
        {
          "mcpServers": {
            "macoestro": {
              "command": "\(SetupManager.bridgeScript.path)"
            }
          }
        }
        """
    }
}

struct StatusRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(color)
            Text(title)
                .font(.callout.bold())
            Spacer()
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
