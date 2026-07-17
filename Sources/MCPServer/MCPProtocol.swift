import Foundation

public protocol MCPToolProvider: Sendable {
    func listTools() -> [JSONValue]
    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue
}

public struct MCPProtocolHandler: Sendable {
    private let toolProvider: MCPToolProvider
    private let serverInfo: JSONValue
    /// Invoked with the tool name whenever `tools/call` dispatches a tool.
    /// The App layer wires this to AppState for telemetry; nil by default.
    private let onToolCall: (@Sendable (String) -> Void)?

    public init(
        toolProvider: MCPToolProvider,
        onToolCall: (@Sendable (String) -> Void)? = nil
    ) {
        self.toolProvider = toolProvider
        self.onToolCall = onToolCall
        // Real version from the bundle. Info.plist is injected via -sectcreate into
        // the executable's __TEXT,__info_plist section, so Bundle.main resolves it.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.serverInfo = .object([
            "name": .string("macoestro"),
            "version": .string(version),
        ])
    }

    /// Returns nil for notifications (no `id`) — caller must not send a response.
    public func handleRequest(_ data: Data) async -> Data? {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        guard let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            let response = JSONRPCResponse.failure(.parseError, id: nil)
            return (try? encoder.encode(response)) ?? Data()
        }

        // MCP spec: notifications (no id) MUST NOT receive a response
        if request.id == nil {
            return nil
        }

        let response = await dispatch(request)
        return (try? encoder.encode(response)) ?? Data()
    }

    private func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
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

    /// MCP revisions this server actually implements. Echoing an arbitrary
    /// client-requested version would claim semantics we don't have.
    private static let supportedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18",
    ]

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        // Spec: echo the requested version when supported; otherwise answer with
        // the latest version we do support. No request → conservative baseline.
        let requested = request.params?["protocolVersion"]?.stringValue
        let protocolVersion: String
        if let requested, Self.supportedProtocolVersions.contains(requested) {
            protocolVersion = requested
        } else if requested != nil {
            protocolVersion = "2025-06-18"
        } else {
            protocolVersion = "2024-11-05"
        }
        let instructions = """
        Macoestro is a macOS QA-automation server that drives native apps via the \
        Accessibility API. Start with `list_apps` to find a running app, then \
        `snapshot` (compact element list with stable ids) or `find_elements` to \
        inspect its UI, then use the interaction tools (click, type_text, etc.) to \
        drive it. GOLDEN RULE: every tool is background-safe by default — the user \
        keeps their focus, cursor, and frontmost window for the entire run. Never \
        call `activate_app` and never pass `foreground:true` unless a tool result \
        explicitly tells you to: `screenshot_window` captures background and even \
        hidden windows, so an app never needs to be frontmost to be driven, \
        asserted on, or screenshotted. While Focus Guard is on (the default) such \
        calls are refused with an error.
        """
        let result: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": serverInfo,
            "instructions": .string(instructions),
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

        // `arguments` is OPTIONAL in the MCP spec. Normalize its absence to an
        // empty object so handlers never see nil — a nil here used to reach the
        // handlers' force-unwraps and take down the whole process on one
        // malformed (but spec-legal) call.
        let arguments = params["arguments"] ?? .object([:])

        // Telemetry: notify the host that a tool is being dispatched.
        onToolCall?(name)

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
