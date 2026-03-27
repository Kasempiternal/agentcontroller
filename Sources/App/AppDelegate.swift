import AppKit
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

        // Check permissions
        appState.updatePermissions()

        // Start MCP server
        Task {
            await startServer()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running in background for MCP
    }

    func applicationWillTerminate(_ notification: Notification) {
        SetupManager.removePort()
        Task { await httpServer?.stop() }
    }

    private func startServer() async {
        let toolRegistry = ToolRegistry()
        let protocolHandler = MCPProtocolHandler(toolProvider: toolRegistry)

        let server = HTTPServer { data in
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
