import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

struct InteractionTools {
    /// Default deadline for the implicit find-retry loop (P2). A control that appears a
    /// frame late self-heals instead of reporting a phantom miss — this is Maestro's
    /// defining behavior. Overridable per call via the `timeout` param.
    static let defaultFindTimeout: Double = 4.0

    /// Outcome of resolving the target element for an interaction.
    enum ResolvedTarget {
        /// Resolved directly from a cached `elementId` handle (skipped the BFS).
        case handle(AXElement)
        /// Found by selector search.
        case found(AXElement, role: String, path: String)
        /// A handle id was supplied but is stale; fell back to a selector match.
        case foundAfterStaleHandle(AXElement, role: String, path: String)
        /// Nothing matched.
        case none
    }

    /// Short human description of the criteria for `ToolResult.error` messages so a real
    /// miss reads "No element matched selector: role=AXButton title='Save'" instead of a
    /// bare "not found".
    static func describe(_ args: JSONValue?) -> String {
        var parts: [String] = []
        for key in ["role", "title", "titleContains", "identifier", "value", "description", "descriptionContains", "labelContains"] {
            if let v = args?[key]?.stringValue { parts.append("\(key)='\(v)'") }
        }
        if let n = args?["index"]?.intValue ?? args?["nth"]?.intValue { parts.append("index=\(n)") }
        return parts.isEmpty ? "(no matchers given)" : parts.joined(separator: " ")
    }

    /// Build the search root honoring the `scope` param. Default "window" searches from
    /// the app's focused window (faster, avoids matching hidden/background-window
    /// controls); "app" searches from the app root (all windows + menu bar).
    static func searchRoot(pid: pid_t, args: JSONValue?) -> AXElement {
        let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
        let scope = args?["scope"]?.stringValue ?? "window"
        if scope == "app" { return appElement }
        return appElement.focusedWindow ?? appElement
    }

    /// Resolve the interaction target: try an `elementId` handle first (O(1)), else run
    /// the selector BFS in a poll-until-deadline loop on the AXExecutor so a late control
    /// self-heals. Returns the live element plus its role/path for legible outcomes.
    static func resolveTarget(pid: pid_t, args: JSONValue?, timeout: Double) async -> ResolvedTarget {
        var usedStaleHandle = false
        if let handleId = args?["elementId"]?.stringValue {
            if let element = await ElementHandleStore.shared.resolve(handleId) {
                return .handle(element)
            }
            // Handle is stale (nil) — fall back to selector search but note it.
            usedStaleHandle = true
        }

        let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            let hit = await AXExecutor.shared.run { () -> (AXElement, String, String)? in
                let root = searchRoot(pid: pid, args: args)
                guard let r = AXElementSearch.find(root: root, criteria: criteria).first else { return nil }
                return (r.element, r.element.role ?? "element", r.path)
            }
            if let (element, role, path) = hit {
                return usedStaleHandle
                    ? .foundAfterStaleHandle(element, role: role, path: path)
                    : .found(element, role: role, path: path)
            }
            if Date() >= deadline { break }
            await AXExecutor.shared.pause(0.15)
        } while Date() < deadline

        return .none
    }

    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "click",
            description: "Click a UI element (AX action, background-safe) or at screen coordinates (CGEvent, requires focus). For element matching, use role+title/identifier when known; use labelContains when you see the text on-screen but don't know which AX attribute carries it (common with SwiftUI buttons that stash labels in AXDescription). Pass an `elementId` from a prior snapshot/describe_screen to act on that exact element and skip the search. Element searches default to the focused window (scope:'window'); pass scope:'app' to search all windows + menu bar.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id (e.g. 'e7') from a prior snapshot/describe_screen — acts on that element directly, skipping the search")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (focused window, default) or 'app' (all windows + menu bar)")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find before reporting a miss (default 4)")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate (screen points) for coordinate click")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate (screen points) for coordinate click")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()

                // Coordinate-based click — requires focus, so activate first.
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    let activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                    await AXExecutor.shared.run {
                        InputSimulator.click(at: CGPoint(x: x, y: y))
                    }
                    return ToolResult.action(success: true, method: "coordinate", extra: [
                        "activated": .bool(activated),
                        "x": .double(x), "y": .double(y),
                    ])
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, role, staleHandle): (AXElement, String, Bool)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .handle(let e):
                    (element, role, staleHandle) = (e, e.role ?? "element", false)
                case .found(let e, let r, _):
                    (element, role, staleHandle) = (e, r, false)
                case .foundAfterStaleHandle(let e, let r, _):
                    (element, role, staleHandle) = (e, r, true)
                }

                let pressed = await AXExecutor.shared.run { element.press() }
                guard pressed else {
                    return ToolResult.error("Found \(role) but the press action was refused")
                }
                return ToolResult.action(success: true, method: "accessibility", extra: [
                    "found": .bool(true),
                    "role": .string(role),
                    "staleHandle": .bool(staleHandle),
                ])
            }
        ))

        registry.register(.init(
            name: "double_click",
            description: "Double-click a UI element or at coordinates. AX path (two press actions, background-safe) preferred; falls back to coordinate CGEvent if AX press fails. Accepts the same matchers as click (role/title/identifier/description/labelContains) plus `elementId` and `scope`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id from a prior snapshot/describe_screen — acts on that element directly")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find (default 4)")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()

                // Coordinate path: still requires focus.
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    let activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                    await AXExecutor.shared.run {
                        InputSimulator.doubleClick(at: CGPoint(x: x, y: y))
                    }
                    return ToolResult.action(success: true, method: "coordinate", extra: [
                        "activated": .bool(activated),
                    ])
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, role): (AXElement, String)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .handle(let e):
                    (element, role) = (e, e.role ?? "element")
                case .found(let e, let r, _), .foundAfterStaleHandle(let e, let r, _):
                    (element, role) = (e, r)
                }

                // Try AX double-press (background-safe for most standard controls).
                let center: CGPoint? = await AXExecutor.shared.run { () -> CGPoint? in
                    let first = element.press()
                    let second = element.press()
                    if first && second { return nil }
                    // AX press refused — compute the element center for a coordinate fallback.
                    guard let pos = element.position, let sz = element.size else { return nil }
                    return CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
                }

                if let pt = center {
                    // AX press returned false; use coordinate-based double click as fallback.
                    let activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                    await AXExecutor.shared.run { InputSimulator.doubleClick(at: pt) }
                    return ToolResult.action(success: true, method: "coordinate-fallback", extra: [
                        "found": .bool(true), "role": .string(role), "activated": .bool(activated),
                    ])
                }
                return ToolResult.action(success: true, method: "accessibility", extra: [
                    "found": .bool(true), "role": .string(role),
                ])
            }
        ))

        registry.register(.init(
            name: "right_click",
            description: "Right-click a UI element (AX showMenu, background-safe) or at coordinates to open a context menu. Accepts the same matchers as click plus `elementId` and `scope`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id from a prior snapshot/describe_screen — acts on that element directly")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find (default 4)")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    let activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                    await AXExecutor.shared.run {
                        InputSimulator.rightClick(at: CGPoint(x: x, y: y))
                    }
                    return ToolResult.action(success: true, method: "coordinate", extra: [
                        "activated": .bool(activated),
                    ])
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, role): (AXElement, String)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .handle(let e):
                    (element, role) = (e, e.role ?? "element")
                case .found(let e, let r, _), .foundAfterStaleHandle(let e, let r, _):
                    (element, role) = (e, r)
                }

                let shown = await AXExecutor.shared.run { element.showMenu() }
                guard shown else {
                    return ToolResult.error("Found \(role) but the showMenu action was refused")
                }
                return ToolResult.action(success: true, method: "accessibility", extra: [
                    "found": .bool(true), "role": .string(role),
                ])
            }
        ))

        registry.register(.init(
            name: "type_text",
            description: "Type text into the focused element, or into a specific element matched by selector/elementId. For AXTextField/AXTextArea the value is set directly via AX (background-safe, replaces the field). When that path is unavailable the keyboard (CGEvent) fallback runs; by default it CLEARS the field first (Cmd+A then forward-delete) so re-running does not double the text — pass append:true to keep existing content and append instead.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "text": .object(["type": .string("string"), "description": .string("Text to type")]),
                    "append": .object(["type": .string("boolean"), "description": .string("Keyboard fallback only: when true, keep existing field content and append; when false (default), clear the field first so re-running does not double the text")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id from a prior snapshot/describe_screen — focuses/sets that element directly")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find (default 4)")]),
                ])),
                "required": .array([.string("app"), .string("text")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let text = args?["text"]?.stringValue else {
                    throw ToolError.missingParameter("text")
                }
                let append = args?["append"]?.boolValue ?? false
                let hasTarget = args?["role"] != nil || args?["title"] != nil
                    || args?["titleContains"] != nil || args?["identifier"] != nil
                    || args?["description"] != nil || args?["descriptionContains"] != nil
                    || args?["labelContains"] != nil || args?["elementId"] != nil

                // Resolve the target element (if any). Try AX set-value first — for
                // AXTextField/AXTextArea this works in the background and REPLACES the
                // field. SwiftUI TextField often rejects AX-set silently (its @Binding
                // fires on NSTextDidChange, not AX), so we read back and fall through to
                // the CGEvent path if the value didn't stick.
                enum TypeOutcome: Sendable {
                    case axSuccess
                    case axFocusedFallback   // target found, AX-set rejected → focus it, type
                    case noTarget            // no selector → type into whatever has focus
                    case notFound            // selector given but nothing matched
                }

                var focusElement: AXElement?
                let outcome: TypeOutcome
                if !hasTarget {
                    outcome = .noTarget
                } else {
                    let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                    let target = await resolveTarget(pid: pid, args: args, timeout: timeout)
                    switch target {
                    case .none:
                        outcome = .notFound
                    case .handle(let e), .found(let e, _, _), .foundAfterStaleHandle(let e, _, _):
                        let resolved = await AXExecutor.shared.run { () -> TypeOutcome in
                            let role = e.role ?? ""
                            if role == "AXTextField" || role == "AXTextArea",
                               e.setAttribute(kAXValueAttribute, value: text as CFString),
                               e.stringValue == text {
                                return .axSuccess
                            }
                            return .axFocusedFallback
                        }
                        outcome = resolved
                        if case .axFocusedFallback = resolved { focusElement = e }
                    }
                }

                if case .notFound = outcome {
                    return ToolResult.error("No element matched selector: \(describe(args))")
                }
                if case .axSuccess = outcome {
                    return ToolResult.action(success: true, method: "accessibility", extra: [
                        "typed": .string(text), "found": .bool(true),
                    ])
                }

                // Keyboard (CGEvent) fallback. Activate for focus, optionally focus the
                // resolved element, clear the field unless appending, then type.
                let activated = await MainActor.run { AppManager.activate(pid: pid) }
                await AXExecutor.shared.pause(0.1)
                let capturedFocus = focusElement
                await AXExecutor.shared.run {
                    if let element = capturedFocus {
                        _ = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
                    }
                    if !append {
                        // Clear the field first so re-running replaces rather than appends.
                        InputSimulator.clearFocusedField()
                    }
                    InputSimulator.typeText(text)
                }
                return ToolResult.action(success: true, method: "keyboard", extra: [
                    "typed": .string(text),
                    "appended": .bool(append),
                    "activated": .bool(activated),
                ])
            }
        ))

        registry.register(.init(
            name: "send_shortcut",
            description: "Send a keyboard shortcut (e.g. Cmd+S, Cmd+Shift+Z) to the app. Activates the app first so the keystroke lands; the `activated` field reports whether activation succeeded.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "key": .object(["type": .string("string"), "description": .string("Key name (e.g. 's', 'z', 'return', 'tab', 'f5')")]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Modifier keys: 'cmd', 'shift', 'opt'/'alt', 'ctrl'"),
                    ]),
                ]),
                "required": .array([.string("app"), .string("key")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let keyName = args?["key"]?.stringValue else {
                    throw ToolError.missingParameter("key")
                }
                guard let keyCode = InputSimulator.keyCode(for: keyName) else {
                    throw ToolError.invalidParameter("Unknown key: \(keyName)")
                }
                let modNames = args?["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let flags = InputSimulator.modifierFlags(from: modNames)

                let activated = await MainActor.run { AppManager.activate(pid: pid) }
                await AXExecutor.shared.pause(0.1)
                await AXExecutor.shared.run {
                    InputSimulator.sendShortcut(keyCode: keyCode, modifiers: flags)
                }
                guard activated else {
                    return ToolResult.error("Could not activate app (pid \(pid)) to receive the shortcut")
                }
                return ToolResult.action(success: true, method: "keyboard", extra: [
                    "activated": .bool(true),
                    "key": .string(keyName),
                ])
            }
        ))
    }
}
