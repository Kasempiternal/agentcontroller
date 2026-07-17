import AppKit
import AccessibilityEngine
import Foundation
import MCPServer
import MCPTools

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var httpServer: HTTPServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bound every AX call this process ever makes — a hung target app must
        // fail fast, not stall tool calls at the ~6s per-node system default.
        AXElement.installProcessWideTimeoutFloor()

        // Setup directories and bridge script
        SetupManager.setup()

        appState.updatePermissions()
        // First-run UX: this is an LSUIElement (no Dock icon), so on first launch we
        // fire the one-shot TCC prompts once AND surface the main window so the user
        // has a visible place with "Enable" buttons. The window/MenuBarExtra is the
        // ongoing path; we do NOT re-fire raw TCC prompts on every poll.
        if !appState.accessibilityGranted {
            PermissionChecker.requestAccessibility()
        }
        if !appState.screenRecordingGranted {
            PermissionChecker.requestScreenRecording()
        }
        if !appState.accessibilityGranted || !appState.screenRecordingGranted {
            showMainWindow()
        }
        appState.startPermissionPolling()

        // Start MCP server
        Task {
            await startServer()
        }
    }

    /// LSUIElement apps have no Dock icon, so re-launching Macoestro from Spotlight,
    /// Finder, or Launchpad while it's already running routes here instead of doing a
    /// fresh launch. Without handling it, "opening" a running Macoestro looks like a
    /// no-op. Resurface the main window when nothing is already visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Brings the accessory app forward and opens the main "Setup" window so the
    /// permissions UI is reachable even without a Dock icon.
    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running in background for MCP
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopPermissionPolling()
        SetupManager.removePort()
        SetupManager.removeToken()
        Task { await httpServer?.stop() }
    }

    private func startServer() async {
        let toolRegistry = ToolRegistry()
        let appState = self.appState
        // Telemetry: onToolCall is @Sendable and invoked off-main, so hop to MainActor.
        let protocolHandler = MCPProtocolHandler(
            toolProvider: toolRegistry,
            onToolCall: { name in
                Task { @MainActor in
                    appState.recordToolCall(name)
                }
            }
        )

        let server = HTTPServer { data -> Data? in
            await protocolHandler.handleRequest(data)
        }
        self.httpServer = server

        do {
            let port = try await server.start()
            // Persist BOTH the auth token and port (each chmod 0600) so the bridge
            // script can authenticate against the server. authToken is actor-isolated
            // on HTTPServer, so read it with await.
            let token = await server.authToken
            SetupManager.writeToken(token)
            SetupManager.writePort(port)
            appState.isServerRunning = true
            appState.serverPort = port
            print("Macoestro MCP server running on port \(port)")
        } catch {
            print("Failed to start MCP server: \(error)")
            appState.isServerRunning = false
        }
    }
}
