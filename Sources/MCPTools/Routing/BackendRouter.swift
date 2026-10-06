import Foundation
import MCPServer

/// The caller asked for something this backend cannot do (a tool it lacks, a missing
/// elementId, consent not yet given). Nothing about the backend itself is in doubt.
private struct Refusal: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Dispatch snapshot/click/type/… onto the backend the probe selected.
/// Returns nil when the AX/UIA/AT-SPI handler should run unchanged.
public enum BackendRouter {
    public static func dispatch(name: String, arguments: JSONValue) async -> JSONValue? {
        if let handleId = arguments["elementId"]?.stringValue,
           let ref = await RoutedHandleStore.shared.resolve(handleId) {
            guard ref.backend.supportedTools.contains(name) else {
                return ToolResult.error(CapabilityRecord.unsupportedMessage(tool: name, backend: ref.backend))
            }
            do {
                return try await perform(name: name, arguments: arguments, ref: ref)
            } catch {
                if backendMayBeGone(error) { await ProbeCache.shared.invalidate(backend: ref.backend) }
                return ToolResult.error(error.localizedDescription)
            }
        }

        guard CapabilityRecord.routableTools.contains(name) else { return nil }
        // open_url means "open it in a browser the user can see" — the default handler or
        // the one named. Only an explicit headless:true sends it to the private Chromium.
        if name == "open_url", arguments["headless"]?.boolValue != true { return nil }
        guard let identity = identity(from: arguments) else { return nil }
        let capability = await CapabilityProbe.probe(identity)
        if identity.kind == .url, capability.backend != .cdp {
            return ToolResult.error(capability.askDetail ?? capability.reason)
        }
        if identity.kind == .iosSimulator, capability.backend != .iosSim {
            return ToolResult.error(capability.askDetail ?? capability.reason)
        }
        guard capability.backend != .ax else { return nil }
        let owned = identity.kind == .url || identity.kind == .iosSimulator
        guard capability.handles(tool: name) else {
            // A web page or simulator has no AX path to fall back to; Blender's window
            // chrome (menus, dialogs) does.
            guard owned else { return nil }
            return ToolResult.error(CapabilityRecord.unsupportedMessage(tool: name, backend: capability.backend))
        }

        do {
            return try await perform(name: name, arguments: arguments, identity: identity, capability: capability)
        } catch {
            // The verdict may be why it failed (Blender quit, simulator shut down): the next
            // call re-probes instead of trusting a 30s-old answer.
            if backendMayBeGone(error) { await ProbeCache.shared.invalidate(backend: capability.backend) }
            // run_app_code has no AX equivalent, so falling through would only replace the
            // real error (a Python traceback, the consent request) with "no in-process backend".
            if owned || name == "run_app_code" {
                return ToolResult.error(error.localizedDescription)
            }
            return nil
        }
    }

    /// Who the call names, plus the two things only the arguments know: which page an
    /// attached Chrome is meant to be on (`_pageURL`, set by `BrowserRouting`), and whether
    /// the agent asked for the private headless browser.
    static func identity(from arguments: JSONValue) -> TargetIdentity? {
        TargetIdentity.from(arguments: arguments)?.routed(
            pageHint: arguments[BrowserRouting.pageURLKey]?.stringValue.flatMap(TargetIdentity.parseURL),
            headless: arguments["headless"]?.boolValue == true
        )
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
            return try await performIOSTool(name: name, arguments: arguments, capability: capability)
        case .ax, .hid:
            return ToolResult.error("Router asked to handle an AX target")
        }
    }

    /// Transport and subprocess failures cast doubt on the cached probe verdict; a caller's
    /// mistake, a stale element id, or a script that threw do not.
    private static func backendMayBeGone(_ error: Error) -> Bool {
        if error is Refusal || error is CDPError { return false }
        if let tool = error as? ToolError {
            switch tool {
            case .missingParameter, .invalidParameter, .notImplemented: return false
            default: return true
            }
        }
        return true
    }

    // MARK: - Web (CDP)

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
            let page = try await WebCDPBackend.shared.snapshot(identity: identity, interactiveOnly: interactive)
            let ids = await RoutedHandleStore.shared.replace(refs: page.refs, scope: .cdp(page.key))
            let elements = CDPAccessibility.compactElements(ids: ids, refs: page.refs)
            var fields: [String: JSONValue] = [
                "backend": .string("cdp"),
                "mode": .string(interactive ? "interactive" : "all"),
                "count": .int(elements.count),
                "elements": .array(elements),
            ]
            if let url = page.url { fields["url"] = .string(url) }
            if !page.loaded {
                fields["note"] = .string("The page's load event did not fire within \(Int(WebCDPBackend.loadTimeout))s; this is whatever had rendered. Re-snapshot (or wait_for_element) if content looks incomplete.")
            }
            return ToolResult.json(.object(fields))
        case "click", "double_click":
            guard let ref else { throw needsElementId(name, noun: "web page") }
            let double = name == "double_click"
            try await WebCDPBackend.shared.click(ref: ref, clickCount: double ? 2 : 1)
            return ToolResult.action(success: true, method: double ? "cdp-double-click" : "cdp-click")
        case "type_text":
            guard let ref else { throw needsElementId(name, noun: "web page") }
            guard let text = arguments["text"]?.stringValue else { throw ToolError.missingParameter("text") }
            try await WebCDPBackend.shared.typeText(ref: ref, text: text)
            return ToolResult.action(success: true, method: "cdp-type")
        case "read_text", "read_all_text":
            if let ref {
                let text = try await WebCDPBackend.shared.readText(ref: ref)
                return ToolResult.json(.object(["text": .string(text), "backend": .string("cdp")]))
            }
            guard name == "read_all_text", let identity else { throw needsElementId(name, noun: "web page") }
            let text = try await WebCDPBackend.shared.readAllText(identity: identity)
            return ToolResult.json(.object(["text": .string(text), "backend": .string("cdp")]))
        case "screenshot_window", "screenshot_element", "screenshot_screen":
            guard let identity else {
                throw Refusal(message: "\(name) by elementId is not supported on web targets; use screenshot_window with the page url.")
            }
            let data = try await WebCDPBackend.shared.screenshot(identity: identity)
            return ToolResult.image(base64: data.base64EncodedString(), mimeType: "image/jpeg")
        case "open_url":
            guard let identity else { throw ToolError.missingParameter("url") }
            let session = try await WebCDPBackend.shared.openURL(identity: identity)
            var fields: [String: JSONValue] = [
                "backend": .string("cdp"),
                "url": .string(identity.raw),
                "pageURL": .string(session.browserURL),
                "loaded": .bool(session.loaded),
            ]
            if !session.loaded { fields["note"] = .string("Load event not seen within \(Int(WebCDPBackend.loadTimeout))s.") }
            return ToolResult.json(.object(fields))
        case "run_app_code":
            guard let identity else { throw ToolError.missingParameter("app") }
            guard let code = arguments["code"]?.stringValue else { throw ToolError.missingParameter("code") }
            try requireConsent(backend: "cdp", arguments: arguments, detail: "JavaScript inside the page")
            let result = try await WebCDPBackend.shared.evaluate(identity: identity, expression: code)
            return ToolResult.json(.object(["backend": .string("cdp"), "result": result]))
        case "assert_visible", "assert_not_visible", "wait_for_element", "find_elements":
            guard let identity else {
                throw Refusal(message: "\(name) takes a selector (labelContains, role, identifier …) with app or url, not an elementId.")
            }
            return try await performCDPQuery(name: name, arguments: arguments, identity: identity)
        default:
            throw Refusal(message: CapabilityRecord.unsupportedMessage(tool: name, backend: .cdp))
        }
    }

    /// Selector tools against a live page. Waiting is the page's problem, not the caller's:
    /// `wait_for_element` and `assert_*` poll to their timeout the way the AX versions do,
    /// instead of judging the first snapshot (taken mid-render, so usually empty).
    private static func performCDPQuery(name: String, arguments: JSONValue, identity: TargetIdentity) async throws -> JSONValue {
        let selector = try CDPSelector.parse(arguments)
        if selector.isEmpty && name != "find_elements" {
            throw ToolError.invalidParameter("\(name) needs a selector: role, identifier, title, titleContains, description, descriptionContains or labelContains")
        }
        let defaultTimeout: Double = name == "wait_for_element" ? 10 : name == "find_elements" ? 0 : 7
        let timeout = max(arguments["timeout"]?.doubleValue ?? defaultTimeout, 0)
        let pollInterval = max(arguments["pollInterval"]?.doubleValue ?? 0.5, 0.1)
        let outcome = try await WebCDPBackend.shared.query(
            identity: identity,
            selector: selector,
            expect: name == "assert_not_visible" ? .absent : .present,
            timeout: timeout,
            pollInterval: pollInterval
        )
        let backend = JSONValue.string("cdp")
        let elapsed = JSONValue.double(outcome.elapsed)

        switch name {
        case "assert_not_visible":
            guard outcome.satisfied else {
                return ToolResult.error("assert_not_visible FAILED: element matching \(selector.summary) was still present after \(timeout)s")
            }
            return ToolResult.json(.object(["passed": .bool(true), "elapsed": elapsed, "backend": backend]))
        case "assert_visible", "wait_for_element":
            guard outcome.satisfied, let first = outcome.matched.first else {
                if name == "assert_visible" {
                    return ToolResult.error("assert_visible FAILED: no element matched \(selector.summary) within \(timeout)s")
                }
                return ToolResult.json(.object([
                    "found": .bool(false),
                    "elapsed": elapsed,
                    "message": .string("Element not found within \(timeout)s timeout"),
                    "backend": backend,
                ]))
            }
            let ids = await RoutedHandleStore.shared.replace(refs: outcome.refs, scope: .cdp(outcome.key))
            var fields: [String: JSONValue] = [
                name == "assert_visible" ? "passed" : "found": .bool(true),
                "id": .string(ids[first]),
                "elapsed": elapsed,
                "backend": backend,
            ]
            if case .cdp(_, _, let role, let label) = outcome.refs[first] {
                fields["role"] = .string(role)
                if !label.isEmpty { fields["label"] = .string(label) }
            }
            return ToolResult.json(.object(fields))
        default:
            let ids = await RoutedHandleStore.shared.replace(refs: outcome.refs, scope: .cdp(outcome.key))
            let limit = arguments["maxResults"]?.intValue ?? 20
            let shown = Array(outcome.matched.prefix(limit))
            let elements = CDPAccessibility.compactElements(ids: shown.map { ids[$0] }, refs: shown.map { outcome.refs[$0] })
            return ToolResult.json(.object([
                "backend": backend,
                "count": .int(outcome.matched.count),
                "elements": .array(elements),
            ]))
        }
    }

    // MARK: - Blender

    private static func performBlender(name: String, arguments: JSONValue, ref: RoutedRef) async throws -> JSONValue {
        guard case .blender(let objectName, _, let endpoint) = ref else {
            throw ToolError.actionFailed("Not a Blender element")
        }
        switch name {
        case "click":
            try requireConsent(backend: "bpy", arguments: arguments, detail: "Python inside Blender")
            let code = "import bpy; obj=bpy.data.objects.get('\(escape(objectName))');\n" +
                "result={'selected': False}\n" +
                "if obj:\n    bpy.context.view_layer.objects.active=obj; obj.select_set(True); result={'selected': True, 'name': obj.name}"
            let result = try await BlenderBackend.execute(endpoint: endpoint, code: code)
            return ToolResult.json(.object(["backend": .string(endpoint.kind.rawValue), "result": result, "method": .string("bpy-select")]))
        default:
            throw Refusal(message: CapabilityRecord.unsupportedMessage(tool: name, backend: endpoint.kind))
        }
    }

    private static func performBlenderTool(
        name: String,
        arguments: JSONValue,
        capability: CapabilityRecord
    ) async throws -> JSONValue {
        // The probe already handshook and cached its answer; use that endpoint rather than
        // handshaking 21 ports again. A failure invalidates the cache, which is what
        // triggers the next handshake.
        guard let endpoint = BlenderEndpoint(record: capability) else {
            throw ToolError.actionFailed(capability.askDetail ?? "Blender socket unavailable")
        }
        switch name {
        case "snapshot", "describe_screen":
            let refs = try await BlenderBackend.sceneSnapshot(endpoint: endpoint)
            let ids = await RoutedHandleStore.shared.replace(refs: refs, scope: .blender(endpoint.address))
            let elements: [JSONValue] = zip(ids, refs).map { id, ref in
                guard case .blender(let objectName, let kind, _) = ref else {
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
            let result = try await BlenderBackend.execute(endpoint: endpoint, code: code)
            return ToolResult.json(.object(["backend": .string(endpoint.kind.rawValue), "result": result]))
        case "click":
            throw needsElementId(name, noun: "Blender scene")
        default:
            throw Refusal(message: CapabilityRecord.unsupportedMessage(tool: name, backend: endpoint.kind))
        }
    }

    // MARK: - iOS simulator

    private static func performIOS(name: String, arguments: JSONValue, ref: RoutedRef) async throws -> JSONValue {
        switch name {
        case "click":
            try await IOSSimBackend.shared.tap(ref: ref)
            return ToolResult.action(success: true, method: "idb-tap")
        case "type_text":
            guard let text = arguments["text"]?.stringValue else { throw ToolError.missingParameter("text") }
            try await IOSSimBackend.shared.typeText(ref: ref, text: text)
            return ToolResult.action(success: true, method: "idb-tap-text")
        default:
            throw Refusal(message: CapabilityRecord.unsupportedMessage(tool: name, backend: .iosSim))
        }
    }

    private static func performIOSTool(
        name: String,
        arguments: JSONValue,
        capability: CapabilityRecord
    ) async throws -> JSONValue {
        // The probe's resolved UDID, never the identity's: "booted" is an alias only this
        // router understands, and idb rejects it.
        guard let udid = capability.resolvedUDID else {
            throw ToolError.actionFailed("The simulator UDID was not resolved; call inspect_capabilities.")
        }
        switch name {
        case "snapshot", "describe_screen":
            let refs = try await IOSSimBackend.shared.snapshot(udid: udid)
            let ids = await RoutedHandleStore.shared.replace(refs: refs, scope: .ios(udid))
            let elements: [JSONValue] = zip(ids, refs).map { id, ref in
                guard case .ios(_, let identifier, let role, let label, let x, let y, let w, let h) = ref else {
                    return .object(["id": .string(id)])
                }
                var fields: [String: JSONValue] = [
                    "id": .string(id),
                    "role": .string(role),
                    "enabled": .bool(true),
                    "frame": .object([
                        "x": .double(x), "y": .double(y),
                        "w": .double(w), "h": .double(h),
                    ]),
                ]
                if !label.isEmpty { fields["label"] = .string(label) }
                if !identifier.isEmpty { fields["identifier"] = .string(identifier) }
                return .object(fields)
            }
            return ToolResult.json(.object([
                "backend": .string("ios-sim"),
                "udid": .string(udid),
                "count": .int(elements.count),
                "elements": .array(elements),
            ]))
        case "click", "type_text":
            throw needsElementId(name, noun: "simulator screen")
        default:
            throw Refusal(message: CapabilityRecord.unsupportedMessage(tool: name, backend: .iosSim))
        }
    }

    // MARK: - Shared

    /// These backends act on handles, not selectors, so a bare click has nothing to aim at.
    private static func needsElementId(_ tool: String, noun: String) -> Refusal {
        Refusal(message: "\(tool) on a \(noun) needs an elementId — call snapshot first and pass one of its ids.")
    }

    private static func requireConsent(backend: String, arguments: JSONValue, detail: String) throws {
        if CodeExecConsent.shared.isGranted(backend) { return }
        if arguments["consent"]?.boolValue == true {
            CodeExecConsent.shared.grant(backend)
            return
        }
        throw Refusal(
            message: "Code execution (\(detail)) requires consent:true once per machine. This runs inside the target app."
        )
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
