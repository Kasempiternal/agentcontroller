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

        MenuBarExtra("AgentController", systemImage: "rectangle.3.group.bubble.left.fill") {
            MenuBarView()
                .environment(appDelegate.appState)
        }
    }
}
