import Foundation
import MCPServer

/// Dispatch snapshot/click/type/… onto the backend the probe selected.
/// Returns nil when the AX/UIA/AT-SPI handler should run unchanged.
public enum BackendRouter {
    public static func dispatch(name: String, arguments: JSONValue) async -> JSONValue? {
        if let handleId = arguments["elementId"]?.stringValue,
           let ref = await RoutedHandleStore.shared.resolve(handleId) {
            do {
                return try await perform(name: name, arguments: arguments, ref: ref)
            } catch {
                return ToolResult.error(error.localizedDescription)
            }
        }

        guard CapabilityRecord.routableTools.contains(name) else { return nil }
        guard let identity = TargetIdentity.from(arguments: arguments) else { return nil }
        let capability = await CapabilityProbe.probe(identity)
        if identity.kind == .url, capability.backend != .cdp {
            return ToolResult.error(capability.askDetail ?? capability.reason)
        }
        if identity.kind == .iosSimulator, capability.backend != .iosSim {
            return ToolResult.error(capability.askDetail ?? capability.reason)
        }
        guard capability.handles(tool: name), capability.backend != .ax else { return nil }

        do {
            return try await perform(name: name, arguments: arguments, identity: identity, capability: capability)
        } catch {
            if identity.kind == .url || identity.kind == .iosSimulator {
                return ToolResult.error(error.localizedDescription)
            }
            return nil
        }
    }

    private static func perform(name: String, arguments: JSONValue, ref: RoutedRef) async throws -> JSONValue {
        switch ref {
        case .cdp:
            return try await performCDP(name: name, arguments: arguments, ref: ref, identity: nil)
        case .blender:
            return try await performBlender(name: name, arguments: arguments, ref: ref)
        case .ios:
            return try await performIOS(name: name, arguments: arguments, ref: ref)
        }
    }

    private static func perform(
        name: String,
        arguments: JSONValue,
        identity: TargetIdentity,
        capability: CapabilityRecord
    ) async throws -> JSONValue {
        switch capability.backend {
        case .cdp:
            return try await performCDP(name: name, arguments: arguments, ref: nil, identity: identity)
        case .blenderLab, .blenderWS:
            return try await performBlenderTool(name: name, arguments: arguments, capability: capability)
        case .iosSim:
            return try await performIOSTool(name: name, arguments: arguments, identity: identity)
        case .ax, .hid:
            return ToolResult.error("Router asked to handle an AX target")
        }
    }

    private static func performCDP(
        name: String,
        arguments: JSONValue,
        ref: RoutedRef?,
        identity: TargetIdentity?
    ) async throws -> JSONValue {
        switch name {
        case "snapshot", "describe_screen":
            guard let identity else { throw ToolError.missingParameter("app") }
            let interactive = (arguments["mode"]?.stringValue?.lowercased() ?? "interactive") != "all"
            let (_, refs) = try await WebCDPBackend.shared.snapshot(identity: identity, interactiveOnly: interactive)
            let ids = await RoutedHandleStore.shared.replace(refs: refs)
            let elements = CDPAccessibility.compactElements(ids: ids, refs: refs)
            return ToolResult.json(.object([
                "backend": .string("cdp"),
                "mode": .string(interactive ? "interactive" : "all"),
                "count": .int(elements.count),
                "elements": .array(elements),
            ]))
        case "click", "double_click":
            guard let ref else { throw ToolError.missingParameter("elementId") }
            try await WebCDPBackend.shared.click(ref: ref)
            if name == "double_click" { try await WebCDPBackend.shared.click(ref: ref) }
            return ToolResult.action(success: true, method: "cdp-click")
        case "type_text":
            guard let ref else { throw ToolError.missingParameter("elementId") }
            guard let text = arguments["text"]?.stringValue else { throw ToolError.missingParameter("text") }
            try await WebCDPBackend.shared.typeText(ref: ref, text: text)
            return ToolResult.action(success: true, method: "cdp-type")
        case "read_text", "read_all_text":
            if let ref {
                let text = try await WebCDPBackend.shared.readText(ref: ref)
                return ToolResult.json(.object(["text": .string(text), "backend": .string("cdp")]))
            }
            throw ToolError.missingParameter("elementId")
        case "screenshot_window", "screenshot_element", "screenshot_screen":
            guard let identity else { throw ToolError.missingParameter("app") }
            let data = try await WebCDPBackend.shared.screenshot(identity: identity)
            return ToolResult.image(base64: data.base64EncodedString(), mimeType: "image/jpeg")
        case "open_url":
            guard let identity else { throw ToolError.missingParameter("url") }
            _ = try await WebCDPBackend.shared.session(for: identity, headless: true)
            return ToolResult.json(.object(["backend": .string("cdp"), "url": .string(identity.raw)]))
        case "run_app_code":
            guard let identity else { throw ToolError.missingParameter("app") }
            guard let code = arguments["code"]?.stringValue else { throw ToolError.missingParameter("code") }
            try requireConsent(backend: "cdp", arguments: arguments, detail: "JavaScript inside the page")
            let result = try await WebCDPBackend.shared.evaluate(identity: identity, expression: code)
            return ToolResult.json(.object(["backend": .string("cdp"), "result": result]))
        case "assert_visible", "wait_for_element", "find_elements":
            guard let identity else { throw ToolError.missingParameter("app") }
            let (_, refs) = try await WebCDPBackend.shared.snapshot(identity: identity, interactiveOnly: false)
            let ids = await RoutedHandleStore.shared.replace(refs: refs)
            if let wanted = arguments["labelContains"]?.stringValue ?? arguments["title"]?.stringValue
                ?? arguments["titleContains"]?.stringValue {
                let hit = zip(ids, refs).first { _, ref in
                    if case .cdp(_, _, _, let label) = ref {
                        return label.localizedCaseInsensitiveContains(wanted)
                    }
                    return false
                }
                let found = hit != nil
                if name == "assert_visible" {
                    return found
                        ? ToolResult.json(.object(["pass": .bool(true), "backend": .string("cdp")]))
                        : ToolResult.error("Not visible: \(wanted)")
                }
                if let hit {
                    return ToolResult.json(.object([
                        "id": .string(hit.0),
                        "backend": .string("cdp"),
                    ]))
                }
                return ToolResult.error("No element matched \(wanted)")
            }
            return ToolResult.json(.object(["count": .int(ids.count), "backend": .string("cdp")]))
        default:
            throw ToolError.notImplemented("CDP routing for \(name)")
        }
    }

    private static func performBlender(name: String, arguments: JSONValue, ref: RoutedRef) async throws -> JSONValue {
        guard case .blender(let objectName, _) = ref else {
            throw ToolError.actionFailed("Not a Blender element")
        }
        let endpoints = await BlenderBackend.shared.handshake()
        guard let endpoint = endpoints.first, endpoints.count == 1 else {
            throw ToolError.actionFailed("Blender socket not uniquely available")
        }
        switch name {
        case "click":
            try requireConsent(backend: "bpy", arguments: arguments, detail: "Python inside Blender")
            let code = "import bpy; obj=bpy.data.objects.get('\(escape(objectName))');\n" +
                "result={'selected': False}\n" +
                "if obj:\n    bpy.context.view_layer.objects.active=obj; obj.select_set(True); result={'selected': True, 'name': obj.name}"
            let result = try await BlenderBackend.shared.execute(endpoint: endpoint, code: code)
            return ToolResult.json(.object(["backend": .string(endpoint.kind.rawValue), "result": result, "method": .string("bpy-select")]))
        default:
            throw ToolError.notImplemented("Blender routing for \(name)")
        }
    }

    private static func performBlenderTool(
        name: String,
        arguments: JSONValue,
        capability: CapabilityRecord
    ) async throws -> JSONValue {
        let endpoints = await BlenderBackend.shared.handshake()
        guard let endpoint = pickBlender(endpoints, capability: capability) else {
            throw ToolError.actionFailed(capability.askDetail ?? "Blender socket unavailable")
        }
        switch name {
        case "snapshot", "describe_screen":
            let refs = try await BlenderBackend.shared.sceneSnapshot(endpoint: endpoint)
            let ids = await RoutedHandleStore.shared.replace(refs: refs)
            let elements: [JSONValue] = zip(ids, refs).map { id, ref in
                guard case .blender(let objectName, let kind) = ref else {
                    return .object(["id": .string(id)])
                }
                return .object([
                    "id": .string(id),
                    "role": .string(kind),
                    "label": .string(objectName),
                    "enabled": .bool(true),
                ])
            }
            return ToolResult.json(.object([
                "backend": .string(endpoint.kind.rawValue),
                "count": .int(elements.count),
                "elements": .array(elements),
                "note": .string("Scene objects from bpy. Use run_app_code for mutations; AX still handles Preferences/menus if you snapshot the Blender window chrome via a non-blender identity."),
            ]))
        case "run_app_code":
            guard let code = arguments["code"]?.stringValue else { throw ToolError.missingParameter("code") }
            try requireConsent(backend: "bpy", arguments: arguments, detail: "Python inside Blender")
            let result = try await BlenderBackend.shared.execute(endpoint: endpoint, code: code)
            return ToolResult.json(.object(["backend": .string(endpoint.kind.rawValue), "result": result]))
        default:
            throw ToolError.notImplemented("Blender routing for \(name)")
        }
    }

    private static func pickBlender(
        _ endpoints: [BlenderBackend.Endpoint],
        capability: CapabilityRecord
    ) -> BlenderBackend.Endpoint? {
        if endpoints.count == 1 { return endpoints[0] }
        if let portStr = capability.endpoint?.split(separator: ":").last,
           let port = UInt16(portStr) {
            return endpoints.first { $0.port == port }
        }
        return nil
    }

    private static func performIOS(name: String, arguments: JSONValue, ref: RoutedRef) async throws -> JSONValue {
        switch name {
        case "click", "double_click":
            try IOSSimBackend.tap(ref: ref)
            return ToolResult.action(success: true, method: "idb-tap")
        case "type_text":
            guard case .ios(let udid, _, _, _, _, _) = ref else {
                throw ToolError.actionFailed("Not an iOS element")
            }
            guard let text = arguments["text"]?.stringValue else { throw ToolError.missingParameter("text") }
            try IOSSimBackend.typeText(udid: udid, text: text)
            return ToolResult.action(success: true, method: "idb-text")
        default:
            throw ToolError.notImplemented("iOS routing for \(name)")
        }
    }

    private static func performIOSTool(
        name: String,
        arguments: JSONValue,
        identity: TargetIdentity
    ) async throws -> JSONValue {
        let udid = identity.udid ?? identity.raw
        switch name {
        case "snapshot", "describe_screen":
            let refs = try IOSSimBackend.snapshot(udid: udid)
            let ids = await RoutedHandleStore.shared.replace(refs: refs)
            let elements: [JSONValue] = zip(ids, refs).map { id, ref in
                guard case .ios(_, let uid, let x, let y, let w, let h) = ref else {
                    return .object(["id": .string(id)])
                }
                return .object([
                    "id": .string(id),
                    "role": .string("element"),
                    "label": .string(uid),
                    "enabled": .bool(true),
                    "frame": .object([
                        "x": .double(x), "y": .double(y),
                        "w": .double(w), "h": .double(h),
                    ]),
                ])
            }
            return ToolResult.json(.object([
                "backend": .string("ios-sim"),
                "count": .int(elements.count),
                "elements": .array(elements),
            ]))
        default:
            throw ToolError.notImplemented("iOS routing for \(name)")
        }
    }

    private static func requireConsent(backend: String, arguments: JSONValue, detail: String) throws {
        if CodeExecConsent.shared.isGranted(backend) { return }
        if arguments["consent"]?.boolValue == true {
            CodeExecConsent.shared.grant(backend)
            return
        }
        throw ToolError.actionFailed(
            "Code execution (\(detail)) requires consent:true once per machine. This runs inside the target app."
        )
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
