import SwiftUI
import AccessibilityEngine

struct PermissionsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.teal)

            Text("Permissions Required")
                .font(.title2.bold())

            Text("Macoestro needs these permissions to inspect and control macOS applications for AI agents.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                PermissionRow(
                    title: "Accessibility",
                    description: "Required to inspect UI elements and interact with apps",
                    isGranted: state.accessibilityGranted,
                    action: {
                        PermissionChecker.requestAccessibility()
                        // Mirror Screen Recording: also deep-link to the Accessibility pane.
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                )

                PermissionRow(
                    title: "Screen Recording",
                    description: "Required to capture app window screenshots",
                    isGranted: state.screenRecordingGranted,
                    action: {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                )
            }
            .padding()

            Button("Refresh Permissions") {
                state.updatePermissions()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 450)
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isGranted ? .green : .orange)
                    Text(title)
                        .font(.callout.bold())
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isGranted {
                Button("Enable") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
