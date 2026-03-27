import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack {
            if state.isServerRunning {
                Label("Server running on port \(state.serverPort)", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Server stopped", systemImage: "circle.fill")
                    .foregroundStyle(.red)
            }

            Divider()

            if state.requestCount > 0 {
                Text("Requests handled: \(state.requestCount)")
            }

            Divider()

            Button("Open Macoestro") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Macoestro" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("Quit Macoestro") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
