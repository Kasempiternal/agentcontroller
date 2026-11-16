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

    /// MCP tool annotations (2025-03-26 spec): behavior hints clients use to
    /// gate approvals — e.g. auto-allowing read-only tools. Central maps rather
    /// than per-definition fields so the classification is reviewable at a
    /// glance; `AnnotationTests` asserts every name here actually exists.
    static let readOnlyTools: Set<String> = [
        "assert_not_visible", "assert_value", "assert_visible",
        "check_permissions", "describe_screen", "find_elements",
        "get_clipboard", "get_element_attributes", "get_element_tree",
        "get_focused_element", "get_frontmost_app", "get_menu_structure",
        "get_window_bounds", "inspect_capabilities", "list_apps", "list_flows", "list_windows",
        "read_all_text", "read_text", "screenshot_element",
        "screenshot_screen", "screenshot_window", "snapshot",
        "wait_for_element",
    ]

    /// Tools that can lose user data or clobber user-owned state: container
    /// wipes, app termination (unsaved work), and the system-wide clipboard.
    static let destructiveTools: Set<String> = [
        "quit_app", "reset_app_state", "set_clipboard",
    ]

    public init() {
        registerAllTools()
    }

    public func register(_ tool: ToolDefinition) {
        tools[tool.name] = tool
    }

    public func instructionsAddendum() -> String? {
        guard let browser = BrowserResolver.systemDefault() else { return nil }
        return "This Mac's default web browser is \(browser.name) (\(browser.bundleId)). " +
            "A web page with no browser named goes there."
    }

    public func listTools() -> [JSONValue] {
        tools.values.sorted(by: { $0.name < $1.name }).map { tool in
            // openWorldHint false: every tool acts on this Mac's UI, nothing
            // reaches the open internet. destructiveHint defaults to true in
            // the spec, so state it explicitly for the harmless majority.
            var annotations: [String: JSONValue] = [
                "openWorldHint": .bool(false),
                "destructiveHint": .bool(Self.destructiveTools.contains(tool.name)),
            ]
            if Self.readOnlyTools.contains(tool.name) {
                annotations["readOnlyHint"] = .bool(true)
            }
            let (description, schema) = Self.webKitAdvertised(tool)
            return .object([
                "name": .string(tool.name),
                "description": .string(description),
                "inputSchema": schema,
                "annotations": .object(annotations),
            ])
        }
    }

    /// Every tool the WebKit backend implements also advertises its options, so the schema of
    /// the 19 tools is not hand-copied 19 times and cannot drift from what the router reads.
    private static func webKitAdvertised(_ tool: ToolDefinition) -> (String, JSONValue) {
        guard WebKitRouter.supportedTools.contains(tool.name) else { return (tool.description, tool.inputSchema) }
        guard case .object(var schema) = tool.inputSchema, case .object(var properties)? = schema["properties"] else {
            return (tool.description, tool.inputSchema)
        }
        for (key, value) in WebKitTarget.optionSchema where properties[key] == nil { properties[key] = value }
        schema["properties"] = .object(properties)
        let note = tool.name == "open_url"
            ? " With browser:\"webkit\" the page renders in this app's own off-screen WebKit view: no window on any Space, no focus, no logins from the user's browsers, its own cookie profile. For Safari-like pixels of a local page (light/dark, any width, any pixel ratio) use it; use real Safari only for pages that need the user's logins. Only http(s) and about:blank load (file: and data: need allowFile:true); a page's own links, popups and redirects stay on http(s) and nothing downloads."
            : " Also works on the off-screen WebKit page: app:\"webkit\" (or browser:\"webkit\"); see open_url for its options."
        return (tool.description + note, .object(schema))
    }

    public func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        // Second normalization choke point (MCPProtocolHandler is the first):
        // handlers may force-unwrap `args`, so direct callers (flows, tests)
        // must never deliver nil either.
        var arguments = BrowserRouting.strippingPrivateKeys(arguments ?? .object([:]))
        guard let tool = tools[name] else {
            return ToolResult.error("Unknown tool: \(name)")
        }
        // Focus Guard: every focus-stealing path in the tool set is either the
        // `activate_app` tool or gated behind `foreground:true`, so this single
        // dispatch-level check covers all of them — including steps replayed via
        // run_steps/run_saved_flow (they re-enter through callTool) and any
        // future tool that adopts the `foreground` convention.
        if FocusGuard.isEnabled {
            if name == "activate_app" {
                return ToolResult.error(FocusGuard.denialMessage(for: "activate_app"))
            }
            if arguments["foreground"]?.boolValue == true {
                return ToolResult.error(FocusGuard.denialMessage(for: "foreground:true on \(name)"))
            }
        }
        // FocusWatcher: stamp the activity clock so a driven-app activation in
        // the next few seconds is attributed to the agent, and surface any
        // steal detected since the last call as an in-band warning — the only
        // feedback path that reaches an agent bypassing us via another tool.
        FocusWatcher.shared.noteDispatch()

        // `browser:"webkit"` (or app/target): the in-app WebKit page. Every tool, before any browser
        // or app is resolved, so a tool it lacks says so instead of matching a process by name.
        if let webkit = WebKitTarget.parse(arguments) {
            var result = await WebKitRouter.handle(name: name, arguments: arguments, target: webkit)
            if let incident = FocusWatcher.shared.consumeIncident() { result = ToolResult.appendingNotice(incident, to: result) }
            return result
        }

        // Browser choice happens here, once, before any backend sees the call.
        var browserNotice: String?
        switch try await BrowserRouting.prepare(name: name, arguments: arguments) {
        case .unchanged:
            break
        case .rewritten(let rewritten, let notice):
            arguments = rewritten
            browserNotice = notice
        case .failed(let error):
            return error
        }

        var result: JSONValue
        if let routed = await BackendRouter.dispatch(name: name, arguments: arguments) {
            result = routed
        } else {
            result = try await tool.handler(arguments)
        }
        if let browserNotice {
            result = ToolResult.appendingNotice(browserNotice, to: result)
        }
        if let incident = FocusWatcher.shared.consumeIncident() {
            result = ToolResult.appendingNotice(incident, to: result)
        }
        return result
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
        // QA-capability layer.
        AssertTools.register(in: self)
        SnapshotTools.register(in: self)
        ReadTextTools.register(in: self)
        CapabilityTools.register(in: self)
        // FlowTools handlers capture `self` to call back into callTool for composed flows.
        FlowTools.register(in: self)
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
        // Single choke point where tool calls resolve their target app — the
        // natural place to record which apps this server is driving, so the
        // FocusWatcher only ever restores focus away from apps we touched.
        FocusWatcher.shared.noteDriven(pid: pid)
        return pid
    }
}
