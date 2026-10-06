import SwiftUI

@main
struct AgentControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("AgentController", id: "main") {
            StatusView()
                .environment(appDelegate.appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.appState)
        } label: {
            // The title+systemImage initializer exposed the raw symbol name
            // ("rectangle.3.group.bubble.left.fill") as the status item's AX title, which
            // is what VoiceOver read out.
            Image(systemName: "rectangle.3.group.bubble.left.fill")
                .accessibilityLabel("AgentController")
        }
        // A real panel instead of a plain NSMenu: it can show live state (pulsing status,
        // counters, recent calls) and host a proper switch.
        .menuBarExtraStyle(.window)
    }
}
