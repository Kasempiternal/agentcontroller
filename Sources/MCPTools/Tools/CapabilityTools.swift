import Foundation
import MCPServer

struct CapabilityTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "inspect_capabilities",
            description: "Probe a target (bundle ID, PID, URL, or iOS simulator UDID) and return the best backend this MCP will use. Handshakes native sockets (Blender Lab/community, Chrome CDP, idb). Does not ask except to report multi-instance, missing add-on, or code-exec consent. Do not pick Playwright vs AX vs bpy vs idb — call this, or just snapshot/click, and the server routes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, PID, URL, or iOS simulator UDID"),
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Alias of target"),
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("Page URL (forces the CDP backend)"),
                    ]),
                    "udid": .object([
                        "type": .string("string"),
                        "description": .string("iOS simulator UDID or 'booted'"),
                    ]),
                ]),
            ]),
            handler: { args in
                guard let identity = TargetIdentity.from(arguments: args) else {
                    throw ToolError.missingParameter("target")
                }
                if TargetIdentity.isHardwareUDID(identity.raw) {
                    return ToolResult.error(TargetIdentity.hardwareDeviceGuidance(identity.raw))
                }
                let record = await CapabilityProbe.probe(identity)
                return ToolResult.json(record.jsonValue())
            }
        ))

        registry.register(.init(
            name: "run_app_code",
            description: "Run a script on the auto-selected backend: Python in Blender (bpy) when the socket handshakes, JavaScript in a CDP page, otherwise an error pointing at AX run_steps. One script is the batch — do not issue one MCP call per primitive. First use per backend requires consent:true (RCE inside the app). Returns {backend, result}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, PID, URL, or simulator UDID"),
                    ]),
                    "target": .object([
                        "type": .string("string"),
                        "description": .string("Alias of app"),
                    ]),
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("Page URL for CDP JavaScript"),
                    ]),
                    "headless": .object([
                        "type": .string("boolean"),
                        "description": .string("With url: run in a private headless Chromium (no user logins, never visible) instead of the user's Chrome."),
                    ]),
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("Python (Blender) or JavaScript (CDP) to execute"),
                    ]),
                    "language": .object([
                        "type": .string("string"),
                        "description": .string("Optional hint: python or javascript. Default is the backend's native language."),
                    ]),
                    "consent": .object([
                        "type": .string("boolean"),
                        "description": .string("Required the first time per backend; persists after that."),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ]),
            handler: { args in
                guard let identity = TargetIdentity.from(arguments: args) else {
                    throw ToolError.missingParameter("app")
                }
                guard args?["code"]?.stringValue != nil else {
                    throw ToolError.missingParameter("code")
                }
                if TargetIdentity.isHardwareUDID(identity.raw) {
                    return ToolResult.error(TargetIdentity.hardwareDeviceGuidance(identity.raw))
                }
                let capability = await CapabilityProbe.probe(identity)
                return ToolResult.error(Self.noInProcessBackendMessage(identity: identity, backend: capability.backend.rawValue))
            }
        ))
    }

    /// `run_app_code` only has in-process backends for Blender (bpy) and a CDP page. For a
    /// browser app it used to stop at "use snapshot", which read as a refusal; the real
    /// alternatives for page content are a URL target or the AX tools.
    static func noInProcessBackendMessage(identity: TargetIdentity, backend: String) -> String {
        var message = "No in-process backend for '\(identity.raw)' (probe backend=\(backend))."
        message += " For native UI use snapshot → elementId → run_steps (read_all_text reads page text, click/type_text fill forms)."
        message += " To script a web page, pass a URL and use run_app_code with JavaScript on the CDP backend (headless:true for a private browser),"
        message += " or drive the user's Chrome (debug port) — Safari has no script channel, so read and click it through AX."
        return message
    }
}
