import SwiftUI

@main
struct DeskestroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Deskestro", id: "main") {
            StatusView()
                .environment(appDelegate.appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra("Deskestro", systemImage: "rectangle.3.group.bubble.left.fill") {
            MenuBarView()
                .environment(appDelegate.appState)
        }
    }
}
