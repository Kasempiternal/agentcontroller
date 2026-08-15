import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

struct InteractionTools {
    /// Default deadline for the implicit find-retry loop (P2). A control that appears a
    /// frame late self-heals instead of reporting a phantom miss; tolerant matching is
    /// the defining property of the interaction model, not an opt-in convenience.
    /// Overridable per call via the `timeout` param.
    static let defaultFindTimeout: Double = 4.0

    /// Outcome of resolving the target element for an interaction.
    enum ResolvedTarget {
        /// Resolved directly from a cached `elementId` handle (skipped the BFS).
        case handle(AXElement)
        /// Found by selector search.
        case found(AXElement, role: String, path: String)
        /// A handle id was supplied but is stale; fell back to a selector match.
        case foundAfterStaleHandle(AXElement, role: String, path: String)
        /// A handle id was supplied, it is stale, and no selector was given to
        /// fall back to — retrying the search would be pointless, so callers
        /// should tell the agent to re-snapshot instead of polling the timeout.
        case staleHandleNoFallback(id: String)
        /// Nothing matched.
        case none
    }

    /// Shared error for a dead handle with no selector fallback: name the id,
    /// say why it died, say exactly how to recover.
    static func staleHandleError(_ id: String) -> JSONValue {
        ToolResult.error("elementId '\(id)' is stale — the app's UI changed since that snapshot and no fallback selectors were given. Re-run snapshot/describe_screen and use a fresh id (or add role/labelContains selectors so the tool can re-find the element itself).")
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
        SearchScope.root(pid: pid, args: args, defaultScope: "window")
    }

    /// Resolve the interaction target: try an `elementId` handle first (O(1)), else run
    /// the selector BFS in a poll-until-deadline loop on the AXExecutor so a late control
    /// self-heals. Returns the live element plus its role/path for legible outcomes.
    static func resolveTarget(pid: pid_t, args: JSONValue?, timeout: Double) async -> ResolvedTarget {
        var usedStaleHandle = false
        if let handleId = args?["elementId"]?.stringValue {
            if let element = await ElementHandleStore.shared.resolve(handleId) {
                // Liveness probe: the store can hand back a ref whose element the
                // app has since destroyed (UI rebuilt without a re-snapshot). A
                // dead ref answers .invalidUIElement to every read, so one cheap
                // role read distinguishes live from stale — without it, the
                // press later "fails" with a message that never mentions
                // staleness.
                let alive = await AXExecutor.app(pid).run { element.role != nil }
                if alive { return .handle(element) }
            }
            // Handle is stale (unknown id or dead ref) — fall back to selector
            // search if the call carries any selector; otherwise fail fast with
            // recovery guidance instead of polling a search that can never match.
            usedStaleHandle = true
        }

        let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
        if usedStaleHandle && !criteria.hasAnyMatcher {
            return .staleHandleNoFallback(id: args?["elementId"]?.stringValue ?? "?")
        }
        var deadline = Date().addingTimeInterval(max(0, timeout))
        var firstPass = true
        repeat {
            let outcome = await AXExecutor.app(pid).run { () -> (hit: (AXElement, String, String)?, probe: AXSearchProbe) in
                let root = searchRoot(pid: pid, args: args)
                let (results, probe) = AXElementSearch.findProbing(root: root, criteria: criteria)
                guard let r = results.first else { return (nil, probe) }
                return ((r.element, r.element.role ?? "element", r.path), probe)
            }
            if let (element, role, path) = outcome.hit {
                return usedStaleHandle
                    ? .foundAfterStaleHandle(element, role: role, path: path)
                    : .found(element, role: role, path: path)
            }
            // A selector that describes nothing in a fully-rendered UI will describe
            // nothing 4 seconds later either. Measured on a real session: 111 of 824
            // clicks missed, each paying the full timeout — 14.4 minutes of waiting for
            // an answer that could not change. Hopeless does not mean bail NOW: the
            // deadline collapses to one grace retry, so a control rendering a frame
            // late (~0.3s) still self-heals while a typo'd selector stops costing 4s.
            if firstPass && searchIsHopeless(outcome.probe) {
                deadline = min(deadline, Date().addingTimeInterval(hopelessGraceSeconds))
            }
            firstPass = false
            if Date() >= deadline { break }
            await AXExecutor.pause(0.15)
        } while Date() < deadline

        return .none
    }

    /// How long a hopeless-looking search keeps retrying before reporting the miss.
    /// Long enough for a control that renders a frame or two late (the retry loop's one
    /// real payoff case), far short of the full default timeout.
    static let hopelessGraceSeconds: Double = 0.45

    /// Minimum elements the first walk must have seen before "nothing matched" is
    /// treated as evidence about the UI rather than evidence the UI hasn't rendered.
    static let hopelessMinNodesVisited = 50

    /// Decide, from the first walk alone, whether retrying until the deadline can
    /// change the answer.
    ///
    /// The rule: give up (after the grace retry) only when the walk saw a substantial,
    /// rendered UI (`nodesVisited`) AND no element was one criterion away from matching
    /// (`oneAway`). Two structural facts shape it:
    ///   - With a single criterion, `nearMisses`/`oneAway` are always 0 (any element
    ///     satisfying it is a full match) — so single-criterion misses in a rendered UI
    ///     always take the grace path. That is the measured common case: 111 misses at
    ///     4s each, dominated by labelContains selectors for text not on screen.
    ///   - With role+X selectors, every same-role element is a near miss, so `oneAway`
    ///     stays hot whenever the roles exist and the label is mid-update — those keep
    ///     the full timeout, which is the conservative side of the asymmetry (a wrong
    ///     "hopeless" costs a recovery turn; a wrong "keep waiting" costs 4 seconds).
    static func searchIsHopeless(_ probe: AXSearchProbe) -> Bool {
        probe.nodesVisited >= hopelessMinNodesVisited && probe.oneAway == 0
    }

    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "click",
            description: "Click a UI element (AX press action) or at screen coordinates. PREFER `elementId` from a prior snapshot/describe_screen — it acts on that exact element with no tree search, and it is both faster and more reliable than a selector. Fall back to selectors only for elements you have not snapshotted: role+title/identifier when known, labelContains when you see the text on-screen but don't know which AX attribute carries it (common with SwiftUI buttons that stash labels in AXDescription); a selector matching nothing in a rendered UI fails fast; one that may just not have rendered yet retries until `timeout`. Element searches default to the focused window (scope:'window'); pass scope:'app' to search all windows + menu bar. Issuing several clicks? Send them as one `run_steps` call rather than one call each. BACKGROUND-SAFE BY DEFAULT: the element path uses AXPress and the coordinate path posts to the target PID — neither moves the user's mouse cursor, brings the app forward, nor steals keyboard focus. Set foreground:true ONLY for apps that ignore targeted events (Electron/games) — that activates the app and injects a global click (moves the real cursor).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id (e.g. 'e7') from a prior snapshot/describe_screen — acts on that element directly, skipping the search")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (focused window, default) or 'app' (all windows + menu bar)")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find before reporting a miss (default 4)")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate (screen points) for coordinate click")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate (screen points) for coordinate click")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and injects a global click (moves the real cursor) — use only for apps that ignore PID-targeted events.")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let foreground = args?["foreground"]?.boolValue ?? false

                // Coordinate-based click. Background-safe path delivers to the target PID
                // (no cursor warp, no activation); foreground path activates + global HID.
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    var activated = false
                    if foreground {
                        activated = await MainActor.run { AppManager.activate(pid: pid) }
                        await AXExecutor.pause(0.1)
                    }
                    let targetPid: pid_t? = foreground ? nil : pid
                    await AXExecutor.lane(pid: pid, foreground: foreground).run {
                        InputSimulator.click(at: CGPoint(x: x, y: y), pid: targetPid)
                    }
                    var extra: [String: JSONValue] = [
                        "activated": .bool(activated),
                        "x": .double(x), "y": .double(y),
                    ]
                    if !foreground, let warning = await offTargetWarning(pid: pid, x: x, y: y) {
                        extra["warning"] = .string(warning)
                    }
                    return ToolResult.action(success: true, method: foreground ? "coordinate" : "coordinate-pid", extra: extra)
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, role, staleHandle): (AXElement, String, Bool)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .handle(let e):
                    (element, role, staleHandle) = (e, e.role ?? "element", false)
                case .found(let e, let r, _):
                    (element, role, staleHandle) = (e, r, false)
                case .foundAfterStaleHandle(let e, let r, _):
                    (element, role, staleHandle) = (e, r, true)
                }

                let pressed = await AXExecutor.app(pid).run { element.press() }
                guard pressed else {
                    return ToolResult.error("Found \(role) but the press action was refused — the control may be disabled, or the element may not accept AXPress. Try clicking its coordinates (x/y from snapshot's frame) instead.")
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
            description: "Double-click a UI element or at coordinates. BACKGROUND-SAFE BY DEFAULT: prefers two AX press actions; the coordinate fallback posts to the target PID (no cursor move, no activation, no focus steal). Accepts the same matchers as click (role/title/identifier/description/labelContains) plus `elementId` and `scope`. Set foreground:true only for apps that ignore PID-targeted events (activates + global double-click, moves the real cursor).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id from a prior snapshot/describe_screen — acts on that element directly")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find (default 4)")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and injects a global double-click (moves the real cursor).")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let foreground = args?["foreground"]?.boolValue ?? false

                // Coordinate path. Background-safe path delivers to the target PID;
                // foreground path activates + global HID.
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    var activated = false
                    if foreground {
                        activated = await MainActor.run { AppManager.activate(pid: pid) }
                        await AXExecutor.pause(0.1)
                    }
                    let targetPid: pid_t? = foreground ? nil : pid
                    await AXExecutor.lane(pid: pid, foreground: foreground).run {
                        InputSimulator.doubleClick(at: CGPoint(x: x, y: y), pid: targetPid)
                    }
                    var extra: [String: JSONValue] = ["activated": .bool(activated)]
                    if !foreground, let warning = await offTargetWarning(pid: pid, x: x, y: y) {
                        extra["warning"] = .string(warning)
                    }
                    return ToolResult.action(success: true, method: foreground ? "coordinate" : "coordinate-pid", extra: extra)
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, role): (AXElement, String)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .handle(let e):
                    (element, role) = (e, e.role ?? "element")
                case .found(let e, let r, _), .foundAfterStaleHandle(let e, let r, _):
                    (element, role) = (e, r)
                }

                // Try AX double-press (background-safe for most standard controls).
                // Three distinct outcomes — the old CGPoint? return overloaded nil as
                // both "pressed fine" and "refused with no geometry", reporting the
                // latter as a false success.
                enum DoublePressOutcome: Sendable {
                    case pressed
                    case fallback(CGPoint)
                    case refusedNoGeometry
                }
                let outcome: DoublePressOutcome = await AXExecutor.app(pid).run {
                    let first = element.press()
                    let second = element.press()
                    if first && second { return .pressed }
                    // AX press refused — compute the element center for a coordinate fallback.
                    guard let pos = element.position, let sz = element.size else {
                        return .refusedNoGeometry
                    }
                    return .fallback(CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2))
                }

                if case .refusedNoGeometry = outcome {
                    return ToolResult.error("Found \(role) but the press action was refused and the element exposes no frame for a coordinate fallback. Re-snapshot and try its parent row/cell, or click by coordinates.")
                }
                if case .fallback(let pt) = outcome {
                    // AX press returned false; use coordinate-based double click as fallback.
                    // Background-safe: deliver to the target PID (no cursor warp, no
                    // activation). foreground:true restores activate + global HID.
                    var activated = false
                    if foreground {
                        activated = await MainActor.run { AppManager.activate(pid: pid) }
                        await AXExecutor.pause(0.1)
                    }
                    let targetPid: pid_t? = foreground ? nil : pid
                    await AXExecutor.lane(pid: pid, foreground: foreground).run { InputSimulator.doubleClick(at: pt, pid: targetPid) }
                    return ToolResult.action(success: true, method: foreground ? "coordinate-fallback" : "coordinate-fallback-pid", extra: [
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
            description: "Right-click a UI element (AX showMenu) or at coordinates to open a context menu. BACKGROUND-SAFE BY DEFAULT: the element path uses AXShowMenu and the coordinate path posts to the target PID — no cursor move, no activation, no focus steal. Accepts the same matchers as click plus `elementId` and `scope`. Set foreground:true only for apps that ignore PID-targeted events (activates + global right-click, moves the real cursor).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id from a prior snapshot/describe_screen — acts on that element directly")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find (default 4)")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and injects a global right-click (moves the real cursor).")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let foreground = args?["foreground"]?.boolValue ?? false
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    var activated = false
                    if foreground {
                        activated = await MainActor.run { AppManager.activate(pid: pid) }
                        await AXExecutor.pause(0.1)
                    }
                    let targetPid: pid_t? = foreground ? nil : pid
                    await AXExecutor.lane(pid: pid, foreground: foreground).run {
                        InputSimulator.rightClick(at: CGPoint(x: x, y: y), pid: targetPid)
                    }
                    var extra: [String: JSONValue] = ["activated": .bool(activated)]
                    if !foreground, let warning = await offTargetWarning(pid: pid, x: x, y: y) {
                        extra["warning"] = .string(warning)
                    }
                    return ToolResult.action(success: true, method: foreground ? "coordinate" : "coordinate-pid", extra: extra)
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, role): (AXElement, String)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .handle(let e):
                    (element, role) = (e, e.role ?? "element")
                case .found(let e, let r, _), .foundAfterStaleHandle(let e, let r, _):
                    (element, role) = (e, r)
                }

                let shown = await AXExecutor.app(pid).run { element.showMenu() }
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
            description: "Type text into the focused element, or into a specific element matched by selector/elementId. BACKGROUND-SAFE BY DEFAULT: for AXTextField/AXTextArea the value is set directly via AX (replaces the field, no keystrokes, no focus steal). When AX-set is rejected (e.g. some SwiftUI fields) the keyboard fallback focuses the control via AX (kAXFocusedAttribute, no app activation) and delivers keystrokes to the target PID — the user's keyboard focus and cursor are never disturbed. By default the fallback CLEARS the field first (Cmd+A then forward-delete) so re-running does not double the text — pass append:true to keep existing content and append instead. Set foreground:true only for apps that ignore PID-targeted keys (activates the app and types via the global HID stream).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "text": .object(["type": .string("string"), "description": .string("Text to type")]),
                    "append": .object(["type": .string("boolean"), "description": .string("Keyboard fallback only: when true, keep existing field content and append; when false (default), clear the field first so re-running does not double the text")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id from a prior snapshot/describe_screen — focuses/sets that element directly")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find (default 4)")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and types via the global HID stream — use only for apps that ignore PID-targeted keys.")]),
                ])),
                "required": .array([.string("app"), .string("text")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let text = args?["text"]?.stringValue else {
                    throw ToolError.missingParameter("text")
                }
                let append = args?["append"]?.boolValue ?? false
                let foreground = args?["foreground"]?.boolValue ?? false
                // Every advertised selector counts as targeting — `value` and
                // `index`/`nth` were missing here, so a call selecting purely by
                // them typed into whatever happened to hold focus instead.
                let hasTarget = args?["role"] != nil || args?["title"] != nil
                    || args?["titleContains"] != nil || args?["identifier"] != nil
                    || args?["description"] != nil || args?["descriptionContains"] != nil
                    || args?["labelContains"] != nil || args?["elementId"] != nil
                    || args?["value"] != nil || args?["index"] != nil || args?["nth"] != nil

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
                    case .staleHandleNoFallback(let id):
                        return staleHandleError(id)
                    case .handle(let e), .found(let e, _, _), .foundAfterStaleHandle(let e, _, _):
                        let resolved = await AXExecutor.app(pid).run { () -> TypeOutcome in
                            let role = e.role ?? ""
                            if role == "AXTextField" || role == "AXTextArea",
                               e.setAttribute(kAXValueAttribute, value: text as CFString) {
                                if e.stringValue == text { return .axSuccess }
                                // Some SwiftUI fields apply an AX value-set asynchronously,
                                // so an immediate readback can be a stale negative. One
                                // short beat before falling back avoids a needless
                                // clear-and-retype keyboard pass.
                                usleep(50_000)
                                if e.stringValue == text { return .axSuccess }
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

                // Keyboard (CGEvent) fallback.
                //
                // Background-safe (default): focus the resolved control via AX
                // (kAXFocusedAttribute steers where text lands WITHOUT activating the
                // app), then deliver the clear + keystrokes to the target PID via
                // postToPid. No cursor move, no app activation, no global HID.
                //
                // foreground:true: activate the app and type through the global HID
                // stream — the escape hatch for apps that ignore PID-targeted keys.
                var activated = false
                if foreground {
                    activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.pause(0.1)
                }
                let targetPid: pid_t? = foreground ? nil : pid
                let capturedFocus = focusElement
                await AXExecutor.lane(pid: pid, foreground: foreground).run {
                    if let element = capturedFocus {
                        _ = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
                    }
                    if !append {
                        // Clear the field first so re-running replaces rather than appends.
                        InputSimulator.clearFocusedField(pid: targetPid)
                    }
                    InputSimulator.typeText(text, pid: targetPid)
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
            description: "Send a keyboard shortcut (e.g. Cmd+S, Cmd+Shift+Z) to the app. BACKGROUND-SAFE BY DEFAULT: the chord is delivered to the target PID via postToPid, so it lands in that app's queue WITHOUT bringing it forward, moving the cursor, or stealing the user's keyboard focus. CAVEAT: clipboard/responder-chain chords (Cmd+C/V/X, Select All) need an ACTIVE app and silently no-op in background apps — verify content with read_text/assert_value instead, or activate_app first for paste flows. Set foreground:true only for system-wide hotkeys or apps that ignore PID-targeted chords — that activates the app and posts to the global HID stream.",
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
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and posts the chord to the global HID stream — use for system-wide hotkeys or apps that ignore PID-targeted chords.")]),
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
                let foreground = args?["foreground"]?.boolValue ?? false

                // Background-safe (default): deliver the chord to the target PID — no
                // activation, no global HID, no focus steal. foreground:true activates
                // the app and posts globally (system-wide hotkeys).
                var activated = false
                if foreground {
                    activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.pause(0.1)
                    guard activated else {
                        return ToolResult.error("Could not activate app (pid \(pid)) to receive the foreground shortcut")
                    }
                }
                let targetPid: pid_t? = foreground ? nil : pid
                await AXExecutor.lane(pid: pid, foreground: foreground).run {
                    InputSimulator.sendShortcut(keyCode: keyCode, modifiers: flags, pid: targetPid)
                }
                return ToolResult.action(success: true, method: "keyboard", extra: [
                    "activated": .bool(activated),
                    "key": .string(keyName),
                ])
            }
        ))
    }
}
