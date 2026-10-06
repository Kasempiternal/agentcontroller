import Foundation

public protocol MCPToolProvider: Sendable {
    func listTools() -> [JSONValue]
    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue
    /// Live facts appended to the `initialize` instructions (e.g. the user's default
    /// browser). Computed per session so it is never stale.
    func instructionsAddendum() -> String?
}

extension MCPToolProvider {
    public func instructionsAddendum() -> String? { nil }
}

public struct MCPProtocolHandler: Sendable {
    private let toolProvider: MCPToolProvider
    private let serverInfo: JSONValue
    /// Invoked with the tool name whenever `tools/call` dispatches a tool.
    /// The App layer wires this to AppState for telemetry; nil by default.
    private let onToolCall: (@Sendable (String) -> Void)?
    /// In-flight `tools/call` requests, so `notifications/cancelled` can stop the one it names.
    private let inFlight = InFlightRegistry()

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
            "name": .string("agentcontroller"),
            "version": .string(version),
        ])
    }

    /// Key for requests that carry no `X-AC-Client` header. They share one namespace, so
    /// JSON-RPC ids collide across unrelated clients; `notifications/cancelled` is therefore
    /// honoured only from a client that names itself.
    static let anonymousClient = "anon"

    /// Returns nil when the caller must send no response: notifications (no `id`) and
    /// requests that were cancelled (MCP: a cancelled request gets no response).
    ///
    /// `clientId` names the stdio bridge session the request came from; JSON-RPC ids are
    /// only unique within one session.
    public func handleRequest(_ data: Data, clientId: String? = nil) async -> Data? {
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            return Self.encode(Self.rejection(of: data))
        }

        let client = clientId ?? Self.anonymousClient

        // MCP spec: notifications (no id) MUST NOT receive a response
        guard let id = request.id else {
            // A cancel with no session id names an id out of the namespace every header-less
            // client shares — and they all number from 0, so it would stop another client's
            // call. Those clients are still cancellable by hanging up.
            if request.method == "notifications/cancelled", let clientId {
                await cancelRequest(named: request.params, client: clientId)
            }
            return nil
        }

        let response: JSONRPCResponse?
        if request.method == "tools/call" {
            response = await runCancellable(request, id: id, client: client)
        } else {
            response = await dispatch(request)
        }
        return response.map(Self.encode)
    }

    /// Why `data` is not a request. Valid JSON that is not a request object is an Invalid
    /// Request and echoes the `id` when one is recoverable; text that is not JSON at all is a
    /// Parse error, which has no id to give.
    static func rejection(of data: Data) -> JSONRPCResponse {
        struct IdOnly: Decodable { let id: JSONRPCId? }
        guard (try? JSONDecoder().decode(JSONValue.self, from: data)) != nil else {
            return .failure(.parseError, id: nil)
        }
        let id = (try? JSONDecoder().decode(IdOnly.self, from: data))?.id
        return .failure(.invalidRequest, id: id)
    }

    /// An encoding failure must still answer. A silent empty 200 leaves the client waiting
    /// out its whole deadline for a reply that is never coming.
    static func encode(_ response: JSONRPCResponse) -> Data {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(response) { return data }
        let fallback = JSONRPCResponse.failure(.internalError, id: response.id)
        return (try? encoder.encode(fallback))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }

    /// Runs the call as its own Task so `notifications/cancelled` (and an HTTP disconnect,
    /// which cancels this task) can reach it. Returns nil when the call was cancelled.
    private func runCancellable(_ request: JSONRPCRequest, id: JSONRPCId, client: String) async -> JSONRPCResponse? {
        let key = InFlightRegistry.Key(client: client, id: id)
        let call = Task { () -> JSONRPCResponse? in
            let response = await handleToolsCall(request)
            // Tools that honour cancellation return or throw early; either way the client
            // has abandoned the request and must not be sent a result for it.
            return Task.isCancelled ? nil : response
        }
        guard let token = await inFlight.register(key, cancel: { call.cancel() }) else {
            call.cancel()
            return nil
        }
        let response = await withTaskCancellationHandler {
            await call.value
        } onCancel: {
            call.cancel()
        }
        await inFlight.finish(key, token: token)
        return response
    }

    private func cancelRequest(named params: JSONValue?, client: String) async {
        let id: JSONRPCId
        switch params?["requestId"] {
        case .int(let i)?: id = .int(i)
        case .string(let s)?: id = .string(s)
        default: return
        }
        await inFlight.cancel(.init(client: client, id: id))
    }

    private func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "tools/list":
            return handleToolsList(request)
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
        AgentController drives native apps, web pages, browsers, and iOS simulators \
        through ONE MCP. You never pick Playwright vs AX vs bpy vs idb — pass a \
        target identity (bundle ID / pid / URL / simulator UDID) to the existing \
        tools and the server routes to the best backend. `inspect_capabilities` \
        is the read-only probe (handshake native sockets; it only reports \
        multi-instance, missing add-on, or code-exec consent).

        Start with `list_apps` or `inspect_capabilities`. Then `snapshot` for a \
        compact element list. Blender uses bpy when the socket handshakes. An iOS \
        UDID uses idb/WDA. Everything else is native AX.

        BROWSERS — the user's choice is binding. When the user names a browser \
        ("in Safari", "use Firefox"), pass it as `app` (e.g. app:"Safari", \
        url:"https://…") on snapshot/screenshot_window/read_all_text, or as \
        `browser` on open_url. The server opens the page in THAT browser in the \
        background, waits for it to load, and drives the real window — with the \
        user's logins. Never substitute Chrome for a browser the user named. With \
        no browser named, web pages go to the user's default browser. Pass \
        headless:true only for scripted web testing that should not touch a \
        visible browser (private headless Chromium via CDP, no user logins).

        BATCH YOUR STEPS. `snapshot` returns stable element ids, and every interaction \
        tool takes an `elementId` that acts on that exact element with no search. So the \
        efficient loop is: ONE `snapshot`, then ONE `run_steps` carrying the whole \
        sequence of {tool, args} steps against those ids — not one tool call per action. \
        `run_steps` composes every tool in this server, reports {ran, failedAt, results}, \
        omits nested screenshots by default, and stops at the first failure by default. \
        Re-snapshot only when the UI actually \
        changes shape (a new window, a new screen), not after every click. Driving \
        several apps is the same call: steps naming different `app` values run in one \
        batch. A run that issues one tool call per turn spends almost all of its wall \
        clock waiting on the model, not on this server — a tool call here takes ~0.3s. \
        For Blender/DCC or a known web flow, `run_app_code` ships one script instead.

        PREFER `elementId` OVER SELECTORS. An id from a snapshot resolves in O(1); a \
        selector re-walks the accessibility tree, and one that matches nothing retries \
        until its timeout before reporting the miss. Use selectors when you have not \
        snapshotted, or when the element is expected to appear late; use ids for \
        everything you have already seen. If an id has gone stale the tool says so \
        explicitly — re-snapshot then, and only then.

        GOLDEN RULE: every tool is background-safe by default — the user \
        keeps their focus, cursor, and frontmost window for the entire run. Never \
        call `activate_app` and never pass `foreground:true` unless a tool result \
        explicitly tells you to: `screenshot_window` captures background and even \
        hidden windows, so an app never needs to be frontmost to be driven, \
        asserted on, or screenshotted. While Focus Guard is on (the default) such \
        calls are refused with an error. The rule protects the OUTCOME, not just \
        these tools: never take the user's focus by ANY other means either — no \
        shell/AppleScript bypass (`osascript` `activate`/`set frontmost`, System \
        Events `keystroke`/`click at`, `open` without `-g`). Those steal focus \
        exactly the same way, and keystroke-based driving can type into the \
        user's own window. To open a file or folder in an app, pass `paths` to \
        `launch_app` instead of driving the open panel. If a step truly has no \
        background-safe path, stop and ask the user — do not switch channels.
        """
        let result: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": serverInfo,
            "instructions": .string(
                toolProvider.instructionsAddendum().map { instructions + "\n\n" + $0 } ?? instructions
            ),
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
