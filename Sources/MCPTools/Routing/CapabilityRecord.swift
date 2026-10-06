import Foundation
import MCPServer

/// Outcome of a capability probe. `backend` is what the router will actually
/// use; `ask` is set only for the three cases the product is allowed to
/// surface to a human (multi-instance, missing add-on, code-exec consent).
public struct CapabilityRecord: Equatable, Sendable {
    public enum Backend: String, Equatable, Sendable {
        case ax
        case cdp
        case blenderLab = "bpy-lab"
        case blenderWS = "bpy-ws"
        case iosSim = "ios-sim"
        case hid

        /// What this backend actually implements. `routableTools` is only the set of tools
        /// the router looks at; claiming a tool here that `BackendRouter` has no case for
        /// ends in a "not implemented" error after the probe, so this is the single list
        /// to keep honest.
        public var supportedTools: Set<String> {
            switch self {
            case .cdp:
                return [
                    "snapshot", "describe_screen", "click", "double_click", "type_text",
                    "read_text", "read_all_text",
                    "assert_visible", "assert_not_visible", "wait_for_element", "find_elements",
                    "screenshot_window", "screenshot_element", "screenshot_screen",
                    "open_url", "run_app_code",
                ]
            case .blenderLab, .blenderWS:
                return ["snapshot", "describe_screen", "click", "run_app_code"]
            case .iosSim:
                return ["snapshot", "describe_screen", "click", "type_text"]
            case .ax, .hid:
                return []
            }
        }

        public var targetNoun: String {
            switch self {
            case .cdp: return "web"
            case .blenderLab, .blenderWS: return "Blender"
            case .iosSim: return "iOS simulator"
            case .ax, .hid: return "native"
            }
        }
    }

    public enum Ask: String, Equatable, Sendable {
        case multiInstance = "multi-instance"
        case missingAddon = "missing-addon"
        case codeExecConsent = "code-exec-consent"
    }

    public var target: String
    public var backend: Backend
    public var fallback: Backend
    public var reason: String
    public var endpoint: String?
    public var protocolName: String?
    public var pid: Int?
    public var headless: Bool
    public var ask: Ask?
    public var askDetail: String?
    public var candidates: [JSONValue]
    public var extras: [String: JSONValue]

    public init(
        target: String,
        backend: Backend,
        fallback: Backend = .ax,
        reason: String,
        endpoint: String? = nil,
        protocolName: String? = nil,
        pid: Int? = nil,
        headless: Bool = false,
        ask: Ask? = nil,
        askDetail: String? = nil,
        candidates: [JSONValue] = [],
        extras: [String: JSONValue] = [:]
    ) {
        self.target = target
        self.backend = backend
        self.fallback = fallback
        self.reason = reason
        self.endpoint = endpoint
        self.protocolName = protocolName
        self.pid = pid
        self.headless = headless
        self.ask = ask
        self.askDetail = askDetail
        self.candidates = candidates
        self.extras = extras
    }

    public var usesAXFallback: Bool { backend == .ax }

    /// Tools the specialized backend can service. Anything else falls through
    /// to native AX (menus, window chrome, first-run dialogs) — or, for a web page or a
    /// simulator that has no AX fallback, becomes an actionable error.
    public func handles(tool: String) -> Bool {
        backend.supportedTools.contains(tool)
    }

    /// The simulator the probe resolved. For the "booted" alias this is the one booted
    /// simulator's real UDID — what idb needs — not the alias the caller typed.
    public var resolvedUDID: String? { extras["udid"]?.stringValue }

    public static func unsupportedMessage(tool: String, backend: Backend) -> String {
        let supported = backend.supportedTools.sorted().joined(separator: ", ")
        let escape: String
        switch backend {
        case .cdp: escape = " For anything else, run_app_code runs JavaScript in the page."
        case .blenderLab, .blenderWS: escape = " For anything else, run_app_code runs Python in Blender."
        default: escape = ""
        }
        return "\(tool) is not supported on \(backend.targetNoun) targets. Supported: \(supported).\(escape)"
    }

    /// Every tool the router considers routing off the AX path. A tool in here that the
    /// chosen backend does not support is refused with `unsupportedMessage` for web and
    /// simulator targets, and left to AX for Blender (whose window chrome AX does serve).
    public static let routableTools: Set<String> = [
        "snapshot", "describe_screen",
        "click", "double_click", "right_click", "type_text",
        "read_text", "read_all_text",
        "assert_visible", "assert_not_visible", "assert_value",
        "wait_for_element", "find_elements",
        "get_element_tree", "get_element_attributes", "get_focused_element",
        "screenshot_window", "screenshot_element", "screenshot_screen",
        "scroll", "scroll_until_visible", "swipe", "drag_drop",
        "send_shortcut", "open_url", "run_app_code",
    ]

    public func jsonValue() -> JSONValue {
        var fields: [String: JSONValue] = [
            "target": .string(target),
            "backend": .string(backend.rawValue),
            "fallback": .string(fallback.rawValue),
            "reason": .string(reason),
            "headless": .bool(headless),
        ]
        if let endpoint { fields["endpoint"] = .string(endpoint) }
        if let protocolName { fields["protocol"] = .string(protocolName) }
        if let pid { fields["pid"] = .int(pid) }
        if let ask { fields["ask"] = .string(ask.rawValue) }
        if let askDetail { fields["askDetail"] = .string(askDetail) }
        if !candidates.isEmpty { fields["candidates"] = .array(candidates) }
        for (key, value) in extras { fields[key] = value }
        return .object(fields)
    }
}
