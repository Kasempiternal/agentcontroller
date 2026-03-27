import Foundation

public protocol MCPToolProvider: Sendable {
    func listTools() -> [JSONValue]
    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue
}

public struct MCPProtocolHandler: Sendable {
    private let toolProvider: MCPToolProvider
    private let serverInfo: JSONValue

    public init(toolProvider: MCPToolProvider) {
        self.toolProvider = toolProvider
        self.serverInfo = .object([
            "name": .string("macoestro"),
            "version": .string("1.0.0"),
        ])
    }

    public func handleRequest(_ data: Data) async -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        guard let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            let response = JSONRPCResponse.failure(.parseError, id: nil)
            return (try? encoder.encode(response)) ?? Data()
        }

        let response = await dispatch(request)
        return (try? encoder.encode(response)) ?? Data()
    }

    private func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "notifications/initialized", "initialized":
            return JSONRPCResponse.success(.object([:]), id: request.id)
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return await handleToolsCall(request)
        case "ping":
            return JSONRPCResponse.success(.object([:]), id: request.id)
        default:
            return JSONRPCResponse.failure(.methodNotFound, id: request.id)
        }
    }

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": serverInfo,
        ])
        return .success(result, id: request.id)
    }

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let tools = toolProvider.listTools()
        let result: JSONValue = .object([
            "tools": .array(tools),
        ])
        return .success(result, id: request.id)
    }

    private func handleToolsCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params,
              let name = params["name"]?.stringValue else {
            return .failure(.invalidParams, id: request.id)
        }

        let arguments = params["arguments"]

        do {
            let result = try await toolProvider.callTool(name: name, arguments: arguments)
            return .success(result, id: request.id)
        } catch {
            let errorResult: JSONValue = .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Error: \(error.localizedDescription)"),
                    ])
                ]),
                "isError": .bool(true),
            ])
            return .success(errorResult, id: request.id)
        }
    }
}
