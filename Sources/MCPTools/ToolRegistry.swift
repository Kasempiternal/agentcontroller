import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

public final class ToolRegistry: MCPToolProvider, @unchecked Sendable {
    public struct ToolDefinition: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
        public let handler: @Sendable (JSONValue?) async throws -> JSONValue
    }

    private var tools: [String: ToolDefinition] = [:]

    public init() {
        registerAllTools()
    }

    public func register(_ tool: ToolDefinition) {
        tools[tool.name] = tool
    }

    public func listTools() -> [JSONValue] {
        tools.values.sorted(by: { $0.name < $1.name }).map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ])
        }
    }

    public func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        guard let tool = tools[name] else {
            return ToolResult.error("Unknown tool: \(name)")
        }
        return try await tool.handler(arguments)
    }

    // MARK: - Registration

    private func registerAllTools() {
        AppTools.register(in: self)
        InspectionTools.register(in: self)
        InteractionTools.register(in: self)
        ScrollTools.register(in: self)
        CaptureTools.register(in: self)
        WindowTools.register(in: self)
        MenuTools.register(in: self)
        WaitTools.register(in: self)
        SystemTools.register(in: self)
    }
}

// MARK: - Helper to resolve app PID from arguments

extension JSONValue {
    func resolvePID() throws -> pid_t {
        guard let appStr = self["app"]?.stringValue else {
            throw ToolError.missingParameter("app")
        }
        guard let pid = AppManager.resolvePID(from: appStr) else {
            throw ToolError.appNotFound(appStr)
        }
        return pid
    }
}
