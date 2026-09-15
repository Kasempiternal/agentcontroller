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

    /// Fire the field's action after an AX value-set, for controls where setting the
    /// string is only half the operation.
    ///
    /// `AXUIElementSetAttributeValue(kAXValue)` writes the text straight into the cell —
    /// it does not run the text-did-change chain AppKit uses to notify the control's
    /// target. A plain text field does not care; a search field does everything through
    /// that chain, so its value changes on screen and nothing filters. Observed in Font
    /// Book: the field showed "mono", the list still read 362 typefaces. A follow-up
    /// `send_shortcut return` does not help either, because AX-set never made the field
    /// first responder, so the Return landed elsewhere in the app.
    ///
    /// Scoped to search fields on purpose. `AXConfirm` on an arbitrary text field sends
    /// its action too, which for a form field can mean submitting the form — a surprise
    /// nobody asked this tool for.
    static func commit(_ element: AXElement) -> Bool {
        guard element.subrole == "AXSearchField" else { return false }
        _ = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
        return element.actionNames.contains(kAXConfirmAction) && element.confirm()
    }

    /// Whether a keyboard write is observably present in the target element afterwards.
    enum WriteVerification: Sendable {
        /// The element's value now contains what we typed.
        case landed
        /// The element has a readable value and it is not what we typed.
        case didNotLand(observed: String)
        /// There is nothing to read back: no target element, or the element exposes no
        /// AXValue at all. Not evidence of failure, and not evidence of success either.
        case unverifiable
    }

    /// How long to keep re-reading the element before calling a write unverified. The
    /// keystrokes are posted to the app's queue, so the value appears a few frames later;
    /// a single immediate read reports a false negative on every app under load.
    static let writeVerifyDeadline: Double = 0.6
    static let writeVerifyPollInterval: Double = 0.05

    /// Poll the element's value until it reflects the write or the deadline passes.
    static func verifyWrite(pid: pid_t, element: AXElement?, text: String, append: Bool) async -> WriteVerification {
        guard let element else { return .unverifiable }
        let deadline = Date().addingTimeInterval(writeVerifyDeadline)
        var observed: String?
        repeat {
            observed = await AXExecutor.app(pid).run { element.stringValue }
            if let observed {
                // append:true inserts at the caret, so the field holds more than we
                // typed; the claim we can check is that what we typed is now in there.
                if append ? observed.contains(text) : observed == text { return .landed }
            }
            if Date() >= deadline { break }
            await AXExecutor.pause(writeVerifyPollInterval)
        } while Date() < deadline
        guard let observed else { return .unverifiable }
        return .didNotLand(observed: observed)
    }

    /// Collapse an action name to a single line so it can sit inside a sentence.
    static func oneLine(_ name: String) -> String {
        let flattened = name.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flattened.count > 60 ? String(flattened.prefix(59)) + "…" : flattened
    }

    /// Plain-language gloss for an accessibility action name. Discovery that returns bare
    /// identifiers ("AXPick", "AXConfirm") only moves the lookup elsewhere; the point of
    /// an escape hatch is that the caller can use it without already knowing the platform.
    /// Unknown names get an honest placeholder rather than an invented meaning — this list
    /// is the standard set, and apps are free to define their own.
    static func actionGloss(_ name: String) -> String {
        switch name {
        case "AXPress": return "activate it, the way a click would"
        case "AXConfirm": return "commit the current value, the way Return would"
        case "AXCancel": return "dismiss or revert, the way Escape would"
        case "AXShowMenu": return "open its context menu, the way a right-click would"
        case "AXIncrement": return "step the value up (sliders, steppers)"
        case "AXDecrement": return "step the value down (sliders, steppers)"
        case "AXPick": return "choose this item (menu and combo box entries)"
        case "AXRaise": return "bring this window to the front of its app"
        case "AXOpen": return "open what it represents (files, rows in a Finder list)"
        case "AXDelete": return "delete what it represents"
        case "AXScrollToVisible": return "scroll its container until it is on screen"
        case "AXZoomWindow": return "zoom the window"
        case "AXShowDefaultUI", "AXShowAlternateUI": return "swap between the default and alternate presentation"
        default: return "app-defined action"
        }
    }

    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "click",
            description: "Click a UI element (AX press action) or at screen coordinates. PREFER `elementId` from a prior snapshot/describe_screen — it acts on that exact element with no tree search, and it is both faster and more reliable than a selector. Fall back to selectors only for elements you have not snapshotted: role+title/identifier when known, labelContains when you see the text on-screen but don't know which AX attribute carries it (common with SwiftUI buttons that stash labels in AXDescription); a selector matching nothing in a rendered UI fails fast; one that may just not have rendered yet retries until `timeout`. Element searches default to the focused window (scope:'window'); pass scope:'app' to search all windows + menu bar. Issuing several clicks? Send them as one `run_steps` call rather than one call each. BACKGROUND-SAFE BY DEFAULT: the element path uses AXPress and the coordinate path posts to the target PID — neither moves the user's mouse cursor, brings the app forward, nor steals keyboard focus. Set foreground:true ONLY for apps that ignore targeted events (Electron/games) — that activates the app and injects a global click (moves the real cursor). Auto-routes: CDP click for web refs, bpy select for Blender scene ids, idb tap for iOS; you do not pick the backend.",
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
            description: "Type text into the focused element, or into a specific element matched by selector/elementId. BACKGROUND-SAFE BY DEFAULT: for AXTextField/AXTextArea the value is set directly via AX (replaces the field, no keystrokes, no focus steal); a search field additionally gets its action fired, because setting the string alone changes the text without running the search. When AX-set is rejected (e.g. some SwiftUI fields) the keyboard fallback focuses the control via AX (kAXFocusedAttribute, no app activation) and delivers keystrokes to the target PID — the user's keyboard focus and cursor are never disturbed. THE WRITE IS THEN READ BACK: `verified:true` means the text is observably in the field, an error means it demonstrably is not, and `verified:false` means the element exposes no readable value so you must confirm with read_text/assert_value (common for web content). By default the fallback CLEARS the field first (Cmd+A then forward-delete) so re-running does not double the text — pass append:true to keep existing content and append instead. Set foreground:true only for apps that ignore PID-targeted keys (activates the app and types via the global HID stream).",
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
                    case axSuccess(committed: Bool)
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
                                if e.stringValue == text { return .axSuccess(committed: commit(e)) }
                                // Some SwiftUI fields apply an AX value-set asynchronously,
                                // so an immediate readback can be a stale negative. One
                                // short beat before falling back avoids a needless
                                // clear-and-retype keyboard pass.
                                usleep(50_000)
                                if e.stringValue == text { return .axSuccess(committed: commit(e)) }
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
                if case .axSuccess(let committed) = outcome {
                    var extra: [String: JSONValue] = [
                        "typed": .string(text), "found": .bool(true), "verified": .bool(true),
                    ]
                    if committed { extra["committed"] = .bool(true) }
                    return ToolResult.action(success: true, method: "accessibility", extra: extra)
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
                // Whether AX accepted the focus request matters: posting keystrokes to a
                // control we could not focus sends them to whatever the app's first
                // responder happens to be, which is exactly how "typed successfully" ends
                // up in the wrong field.
                let focusSet: Bool? = await AXExecutor.lane(pid: pid, foreground: foreground).run {
                    let focused = capturedFocus.map { $0.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue) }
                    if !append {
                        // Clear the field first so re-running replaces rather than appends.
                        InputSimulator.clearFocusedField(pid: targetPid)
                    }
                    InputSimulator.typeText(text, pid: targetPid)
                    return focused
                }

                let verification = await verifyWrite(pid: pid, element: capturedFocus, text: text, append: append)
                var extra: [String: JSONValue] = [
                    "typed": .string(text),
                    "appended": .bool(append),
                    "activated": .bool(activated),
                ]
                if let focusSet { extra["focused"] = .bool(focusSet) }

                switch verification {
                case .landed:
                    extra["verified"] = .bool(true)
                    return ToolResult.action(success: true, method: "keyboard", extra: extra)
                case .didNotLand(let observed):
                    return ToolResult.error("Typed \(text.count) character(s) into the matched element but the text did NOT land — the field still reads '\(observed)'. The keystrokes went to the app but not to this control: it may be read-only, may reject synthetic input, or another control holds the app's focus. Click the element first, then retry.")
                case .unverifiable:
                    extra["verified"] = .bool(false)
                    guard focusSet != false else {
                        return ToolResult.error("Could not focus the matched element (AX refused kAXFocused) and it exposes no readable value, so the keystrokes were delivered blind and there is no way to confirm they landed. Click the element first, then retry — a real click sets the app's first responder where an AX focus request did not.")
                    }
                    // Two different reasons for the same verdict, and telling the caller
                    // which one applies is the difference between a fixable call and a
                    // shrug: no selector means we never had an element to read back, so
                    // the fix is to name one.
                    extra["verificationNote"] = .string(capturedFocus == nil
                        ? "No selector was given, so the text went to whatever already held the app's focus and there was no element to read back. Pass a selector or elementId to get a verified write."
                        : "The element exposes no readable AXValue, so the write could not be confirmed. Verify with read_text, assert_value or screenshot_window before depending on it. Web content (Safari/Chrome) and canvas-drawn fields commonly behave this way.")
                    return ToolResult.action(success: true, method: "keyboard", extra: extra)
                }
            }
        ))

        registry.register(.init(
            name: "perform_action",
            description: "Escape hatch: perform ANY accessibility action a control exposes, not just the ones with a dedicated tool. Call it WITHOUT `action` first to discover what the element supports — it returns the action list with a short gloss for each, plus the element's role, subrole and current value. Then call it again with one of those names. Use this for controls the standard tools cannot drive: AXIncrement/AXDecrement on steppers and sliders, AXPick on combo box items, AXConfirm to commit a field, AXRaise on a window, AXCancel to dismiss. The action vocabulary is the platform's own and is NOT portable across backends — discovery mode is how you find the right name on whichever platform you are on. BACKGROUND-SAFE: an accessibility action is delivered to the control directly, so nothing moves the cursor, activates the app, or steals focus.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "action": .object(["type": .string("string"), "description": .string("Accessibility action name (e.g. 'AXPress', 'AXIncrement', 'AXConfirm'). Omit to list what this element supports instead of performing anything.")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id from a prior snapshot/describe_screen — acts on that element directly")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Seconds to keep retrying the element find (default 4)")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                // An empty selector matches whatever the walk reaches first, which for a
                // tool that performs arbitrary actions means acting on an arbitrary
                // control. Demand a target rather than picking one.
                guard args?["elementId"] != nil
                    || AXElementSearchCriteria(from: args, maxResults: 1).hasAnyMatcher else {
                    return ToolResult.error("perform_action needs a target: pass elementId from a snapshot, or a selector (role/title/identifier/labelContains/…). Without one it would act on whichever element the search happened to reach first.")
                }
                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = await resolveTarget(pid: pid, args: args, timeout: timeout)

                let element: AXElement
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .handle(let e), .found(let e, _, _), .foundAfterStaleHandle(let e, _, _):
                    element = e
                }

                struct Described: Sendable {
                    let role: String
                    let subrole: String?
                    let actions: [String]
                    let value: JSONValue?
                    let enabled: Bool
                }
                let described: Described = await AXExecutor.app(pid).run {
                    Described(role: element.role ?? "unknown", subrole: element.subrole,
                              actions: element.actionNames, value: element.valueJSON,
                              enabled: element.isEnabled)
                }

                // Discovery mode. Returning the gloss alongside each name is what makes
                // this usable without leaving the session to look up what an AX action
                // called "AXPick" does.
                guard let action = args?["action"]?.stringValue else {
                    var fields: [String: JSONValue] = [
                        "role": .string(described.role),
                        "enabled": .bool(described.enabled),
                        "actions": .array(described.actions.map { name in
                            .object(["name": .string(name), "does": .string(actionGloss(name))])
                        }),
                    ]
                    if let subrole = described.subrole { fields["subrole"] = .string(subrole) }
                    if let value = described.value { fields["value"] = value }
                    if described.actions.isEmpty {
                        fields["note"] = .string("This element exposes no accessibility actions. Interact with its parent (rows and cells often carry the actions their contents do not), or click its frame coordinates.")
                    }
                    return ToolResult.json(.object(fields))
                }

                // A name the element does not advertise cannot succeed, and performing it
                // anyway returns an unhelpful failure. Name what IS available instead.
                guard described.actions.contains(action) else {
                    // App-defined action names can be whole Objective-C target/action
                    // descriptors spanning several lines ("Name:Move next\nTarget:0x0\n
                    // Selector:(null)"), which turns a one-sentence error into a dozen
                    // ragged lines. The JSON in discovery mode keeps them verbatim, since
                    // the exact string is what you pass back; only the prose is flattened.
                    let available = described.actions.isEmpty
                        ? "it exposes none at all"
                        : "it exposes: \(described.actions.map(oneLine).joined(separator: ", "))"
                    return ToolResult.error("\(described.role) does not support '\(action)' — \(available). Call perform_action without `action` for the full list with descriptions.")
                }
                // Same silent-no-op trap as navigate_menu: a disabled control accepts an
                // action and does nothing with it.
                guard described.enabled else {
                    return ToolResult.error("\(described.role) is disabled, so '\(action)' would have been a no-op. Satisfy whatever the control requires first (a selection, a filled field, an active app), then retry.")
                }

                let performed = await AXExecutor.app(pid).run { element.performAction(action) }
                guard performed else {
                    return ToolResult.error("\(described.role) advertises '\(action)' but refused it. The control may require the app to be active, or its state may have changed since the snapshot — re-snapshot and retry.")
                }
                let after = await AXExecutor.app(pid).run { element.valueJSON }
                var extra: [String: JSONValue] = [
                    "action": .string(action),
                    "role": .string(described.role),
                ]
                if let after { extra["value"] = after }
                return ToolResult.action(success: true, method: "accessibility", extra: extra)
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
