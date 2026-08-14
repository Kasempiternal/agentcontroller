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
        "get_window_bounds", "list_apps", "list_flows", "list_windows",
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
            return .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
                "annotations": .object(annotations),
            ])
        }
    }

    public func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        // Second normalization choke point (MCPProtocolHandler is the first):
        // handlers may force-unwrap `args`, so direct callers (flows, tests)
        // must never deliver nil either.
        let arguments = arguments ?? .object([:])
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
        let result = try await tool.handler(arguments)
        if let incident = FocusWatcher.shared.consumeIncident() {
            return ToolResult.appendingNotice(incident, to: result)
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
