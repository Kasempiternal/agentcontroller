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
        // Setup directories and bridge script
        SetupManager.setup()

        appState.updatePermissions()
        if !appState.accessibilityGranted {
            PermissionChecker.requestAccessibility()
        }
        appState.startPermissionPolling()

        // Start MCP server
        Task {
            await startServer()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running in background for MCP
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopPermissionPolling()
        SetupManager.removePort()
        Task { await httpServer?.stop() }
    }

    private func startServer() async {
        let toolRegistry = ToolRegistry()
        let protocolHandler = MCPProtocolHandler(toolProvider: toolRegistry)

        let server = HTTPServer { data -> Data? in
            await protocolHandler.handleRequest(data)
        }
        self.httpServer = server

        do {
            let port = try await server.start()
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
