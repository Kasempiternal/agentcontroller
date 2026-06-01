import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

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
                openWindow(id: "main")
            }

            Button("Quit Macoestro") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
