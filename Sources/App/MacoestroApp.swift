import SwiftUI

@main
struct MacoestroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Macoestro", id: "main") {
            StatusView()
                .environment(appDelegate.appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra("Macoestro", systemImage: "network") {
            MenuBarView()
                .environment(appDelegate.appState)
        }
    }
}
