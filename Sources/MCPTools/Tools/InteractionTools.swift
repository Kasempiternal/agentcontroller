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
        /// A handle id was supplied but the app did not answer the identity check (busy,
        /// hung, or its stall breaker is open). That says nothing about the element, so the
        /// recovery is to retry, not to re-snapshot — and a selector search against the same
        /// unresponsive app would fare no better.
        case busyHandle(id: String)
        /// Nothing matched.
        case none
    }

    /// Shared error for a dead handle with no selector fallback: name the id,
    /// say why it died, say exactly how to recover.
    static func staleHandleError(_ id: String) -> JSONValue {
        ToolResult.error("elementId '\(id)' is stale — the app's UI changed since that snapshot and no fallback selectors were given. Re-run snapshot/describe_screen and use a fresh id (or add role/labelContains selectors so the tool can re-find the element itself).")
    }

    static func busyHandleError(_ id: String) -> JSONValue {
        ToolResult.error("elementId '\(id)' could not be checked: the app is not answering accessibility reads right now (busy or hung). The id is NOT known to be stale — retry in a moment, and re-snapshot only if this keeps happening.")
    }

    /// Record that the agent just acted through the handle it passed as `elementId`, so the
    /// store can follow the control's own relabelling (Play → Pause) instead of calling the
    /// id stale on the next step. A no-op for targets that were found by selector.
    static func noteActed(on target: ResolvedTarget, args: JSONValue?) async {
        guard case .handle = target, let id = args?["elementId"]?.stringValue else { return }
        await ElementHandleStore.shared.noteActed(id)
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
    /// controls); "app" searches from the app root (all windows, but not the menu bar
    /// unless `includeMenus` is set or the role is an AXMenu* one).
    static func searchRoot(pid: pid_t, args: JSONValue?) -> AXElement {
        SearchScope.root(pid: pid, args: args, defaultScope: "window")
    }

    /// Resolve the interaction target: try an `elementId` handle first (O(1)), else run
    /// the selector BFS in a poll-until-deadline loop on the AXExecutor so a late control
    /// self-heals. Returns the live element plus its role/path for legible outcomes.
    ///
    /// Throws `CancellationError`: the loop is how a cancelled call would otherwise keep
    /// walking the app's AX tree to its deadline.
    static func resolveTarget(pid: pid_t, args: JSONValue?, timeout: Double) async throws -> ResolvedTarget {
        var usedStaleHandle = false
        if let handleId = args?["elementId"]?.stringValue {
            // The store reads the live element (a destroyed one answers .invalidUIElement,
            // which would otherwise surface later as a press that "fails" without ever
            // mentioning staleness) and tells an unanswered read apart from a dead ref.
            switch await ElementHandleStore.shared.lookup(handleId) {
            case .live(let element): return .handle(element)
            case .busy: return .busyHandle(id: handleId)
            case .stale:
                // Fall back to selector search if the call carries any selector;
                // otherwise fail fast with recovery guidance instead of polling a
                // search that can never match.
                usedStaleHandle = true
            }
        }

        let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
        if usedStaleHandle && !criteria.hasAnyMatcher {
            return .staleHandleNoFallback(id: args?["elementId"]?.stringValue ?? "?")
        }
        var deadline = Date().addingTimeInterval(max(0, timeout))
        var firstPass = true
        repeat {
            try Task.checkCancellation()
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
            try await AXExecutor.pause(0.15)
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

    /// What the AX value-set route did for a text field.
    enum AXSetOutcome: Sendable {
        case set(committed: Bool)
        /// Not a settable text role, set refused, or the value did not stick — the caller
        /// falls back to focusing the control and typing keystrokes.
        case fallback(role: String)
    }

    /// Roles whose AXValue is a plain string we can overwrite directly.
    static let valueSettableRoles: Set<String> = ["AXTextField", "AXTextArea"]

    /// Try to replace a text field's value through AX. A rejected or non-sticking set is
    /// not an error: SwiftUI fields often accept the call yet keep their @Binding, so the
    /// readback is the only honest signal.
    static func setValueViaAX(pid: pid_t, element e: AXElement, text: String) async throws -> AXSetOutcome {
        enum First: Sendable {
            case landed(committed: Bool)
            case pending(role: String)
            case rejected(role: String)
        }
        let lane = AXExecutor.app(pid)
        let first: First = await lane.run {
            let role = e.role ?? ""
            guard valueSettableRoles.contains(role), e.setAttribute(kAXValueAttribute, value: text as CFString) else {
                return .rejected(role: role)
            }
            return e.stringValue == text ? .landed(committed: commit(e)) : .pending(role: role)
        }
        switch first {
        case .landed(let committed):
            return .set(committed: committed)
        case .rejected(let role):
            return .fallback(role: role)
        case .pending(let role):
            // Some SwiftUI fields apply an AX value-set asynchronously, so an immediate
            // readback can be a stale negative. One short beat before falling back avoids
            // a needless keyboard pass; the beat is taken off the lane so other work on
            // this app is not blocked behind it.
            try await AXExecutor.pause(0.05)
            return await lane.run { e.stringValue == text ? .set(committed: commit(e)) : .fallback(role: role) }
        }
    }

    /// Roles where "replace the existing text" is well-defined. Anything else (a web
    /// area, a group, a document view) holds content the caller never asked to wipe.
    static let clearableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    enum ClearDecision: Equatable, Sendable {
        case notRequested
        case clear
        case skipped(reason: String)
    }

    /// Whether the keyboard fallback may wipe the field before typing.
    ///
    /// The old fallback sent Cmd+A, ForwardDelete to the app whenever `append` was false —
    /// with no selector, or after AX refused focus, those keys went to whatever held the
    /// app's first responder: the user's document. Clearing needs three facts at once: an
    /// element was resolved, it is a text role, and focus on it is confirmed.
    static func clearDecision(append: Bool, role: String?, focusConfirmed: Bool) -> ClearDecision {
        if append { return .notRequested }
        guard let role else {
            return .skipped(reason: "no element was resolved, so there is no field to clear; the text goes in at the caret of whatever holds focus")
        }
        guard clearableRoles.contains(role) else {
            return .skipped(reason: "\(role.isEmpty ? "the element" : role) is not a text field, so its content was left alone")
        }
        guard focusConfirmed else {
            return .skipped(reason: "AX could not confirm focus on the field, and clearing without it would wipe whatever else holds focus")
        }
        return .clear
    }

    /// Replace-on-type without key chords: select the field's whole text through AX so the
    /// keystrokes that follow overwrite it, or empty its value. True only when readback
    /// confirms the effect.
    static func clearViaAX(_ e: AXElement) -> Bool {
        let current = e.stringValue
        if current?.isEmpty == true { return true }
        if let current {
            var range = CFRange(location: 0, length: current.utf16.count)
            if let axRange = AXValueCreate(.cfRange, &range),
               e.setAttribute(kAXSelectedTextRangeAttribute, value: axRange),
               selectedRange(e)?.length == range.length {
                return true
            }
        }
        guard e.setAttribute(kAXValueAttribute, value: "" as CFString) else { return false }
        return e.stringValue?.isEmpty == true
    }

    static func selectedRange(_ e: AXElement) -> CFRange? {
        guard let raw = e.readAttributes([kAXSelectedTextRangeAttribute])[kAXSelectedTextRangeAttribute],
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    // MARK: - Delivery

    enum Delivery<T: Sendable>: Sendable {
        case delivered(T)
        /// Foreground delivery was refused; the payload is the tool result to return.
        case refused(JSONValue)
    }

    /// Post synchronous input events for `pid`. Background (default): on the app's own
    /// lane, PID-targeted (`target` is the pid). Foreground: activate, verify the app is
    /// frontmost, and post globally (`target` is nil) under the foreground gate — if the
    /// app never comes forward nothing is posted, because a global event would land in
    /// whatever the user is looking at.
    static func deliver<T: Sendable>(pid: pid_t, foreground: Bool, _ body: @Sendable (_ target: pid_t?) -> T) async throws -> Delivery<T> {
        switch try await deliverChunked(pid: pid, foreground: foreground, chunks: 1, progress: { _ in "" }, onInterrupt: { _ in }, body: { target, _ in body(target) }) {
        case .delivered(let results): return .delivered(results[0])
        case .refused(let error): return .refused(error)
        }
    }

    /// `deliver` for input that takes long enough for the frontmost app to change under it:
    /// typed text, a drag. Background it is one lane hop, exactly as before. Foreground it
    /// is `chunks` separate posts with the target re-verified frontmost before each, and
    /// the call refuses (naming `progress(sent)` — what already went out) the moment it is
    /// not. `onInterrupt` runs if input was already under way (a drag's mouse-up), and
    /// always posts the way the chunks did: `target` is the pid, or nil for global.
    static func deliverChunked<T: Sendable>(
        pid: pid_t,
        foreground: Bool,
        chunks: Int,
        progress: @Sendable (_ chunksSent: Int) -> String,
        onInterrupt: @Sendable (_ target: pid_t?) -> Void,
        body: @Sendable (_ target: pid_t?, _ chunk: Int) -> T
    ) async throws -> Delivery<[T]> {
        guard foreground else {
            return .delivered(await AXExecutor.app(pid).run { (0..<max(chunks, 0)).map { body(pid, $0) } })
        }
        switch try await ForegroundInput.performChunked(
            pid: pid, chunks: chunks, onInterrupt: { onInterrupt(nil) }, body: { body(nil, $0) }
        ) {
        case .posted(let results):
            return .delivered(results)
        case .interrupted(let requested, let frontmost, let posted):
            let message = posted.isEmpty
                ? ForegroundInput.refusalMessage(requested: requested, frontmost: frontmost)
                : ForegroundInput.interruptionMessage(requested: requested, frontmost: frontmost, progress: progress(posted.count))
            return .refused(ToolResult.error(message))
        }
    }

    /// Shared tail of every coordinate-input tool: deliver, then (background only) warn
    /// when the point lies outside the app's windows.
    static func coordinateInput(
        pid: pid_t, x: Double, y: Double, foreground: Bool, echoPoint: Bool = false,
        _ post: @Sendable (_ target: pid_t?, _ point: CGPoint) -> Void
    ) async throws -> JSONValue {
        let point = CGPoint(x: x, y: y)
        if case .refused(let error) = try await deliver(pid: pid, foreground: foreground, { post($0, point) }) {
            return error
        }
        return await coordinateResult(pid: pid, x: x, y: y, foreground: foreground, echoPoint: echoPoint)
    }

    /// A drag, delivered so the user switching apps mid-gesture cannot send the rest of it
    /// (and the button release) into their own window. The duration is clamped to
    /// `0...InputSimulator.maxGestureDuration`; an interrupted foreground drag still
    /// releases the button.
    static func dragInput(
        pid: pid_t, from start: CGPoint, to end: CGPoint, duration: Double, foreground: Bool
    ) async throws -> JSONValue {
        let plan = InputSimulator.DragPlan(from: start, to: end, duration: duration)
        let stepChunks = plan.stepChunks
        let last = stepChunks.count - 1
        let delivery = try await deliverChunked(
            pid: pid, foreground: foreground, chunks: stepChunks.count,
            progress: { "\($0) of \(stepChunks.count) drag segments" },
            onInterrupt: { InputSimulator.release(plan, pid: $0) },
            body: { target, chunk in
                if chunk == 0 { InputSimulator.press(plan, pid: target) }
                InputSimulator.move(plan, steps: stepChunks[chunk], pid: target)
                if chunk == last { InputSimulator.release(plan, pid: target) }
            }
        )
        if case .refused(let error) = delivery { return error }
        return await coordinateResult(pid: pid, x: start.x, y: start.y, foreground: foreground, echoPoint: false)
    }

    private static func coordinateResult(pid: pid_t, x: Double, y: Double, foreground: Bool, echoPoint: Bool) async -> JSONValue {
        var extra: [String: JSONValue] = ["activated": .bool(foreground)]
        if echoPoint { extra["x"] = .double(x); extra["y"] = .double(y) }
        if !foreground, let warning = await offTargetWarning(pid: pid, x: x, y: y) {
            extra["warning"] = .string(warning)
        }
        return ToolResult.action(success: true, method: foreground ? "coordinate" : "coordinate-pid", extra: extra)
    }

    /// Characters per foreground typing chunk: ~25ms of keystrokes between frontmost
    /// re-checks, small enough that a mid-typing app switch loses a few characters, not
    /// the whole string.
    static let typeChunkCharacters = 24

    /// `text` cut into foreground typing chunks (always at least one, so an empty string
    /// still runs the focus/clear step that precedes typing).
    static func typingChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: typeChunkCharacters, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<end]))
            index = end
        }
        return chunks.isEmpty ? [""] : chunks
    }

    /// Whether `type_text` may post keystrokes. When the agent named a target, the
    /// keystrokes only go where it meant if AX confirmed focus on that element; posting
    /// them to a control we failed to focus lands them in whatever the app's first
    /// responder happens to be — the user's document — and reports success.
    static func keystrokesMayBePosted(targetResolved: Bool, focusConfirmed: Bool) -> Bool {
        !targetResolved || focusConfirmed
    }

    static let focusUnconfirmedError = "Could not focus the matched element (AX refused or did not confirm kAXFocused), so NOTHING was typed: keystrokes posted to an unfocused control land in whatever else holds the app's focus. Click the element first (a real click sets the app's first responder where an AX focus request did not), then call type_text again WITHOUT a selector to type at the caret — or pass foreground:true."

    // MARK: - Press

    /// AXPress returns `.success` on a DISABLED control — the press is accepted and does
    /// nothing, so click reported success for a button the app had greyed out. Role and
    /// enablement come in one batched read, taken in the same lane hop as the action.
    struct ElementProbe: Sendable {
        let role: String?
        let enabled: Bool
    }

    /// Call inside the element's lane. A missing AXEnabled counts as enabled, matching
    /// `AXElement.isEnabled`.
    static func probe(_ element: AXElement) -> ElementProbe {
        let attrs = element.readAttributes([kAXRoleAttribute, kAXEnabledAttribute])
        return ElementProbe(role: attrs[kAXRoleAttribute] as? String, enabled: (attrs[kAXEnabledAttribute] as? Bool) ?? true)
    }

    static func disabledError(role: String, action: String) -> JSONValue {
        ToolResult.error("\(role) is disabled, so '\(action)' would have been a no-op. Satisfy whatever the control requires first (a selection, a filled field, an active app), then retry.")
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
    static func verifyWrite(pid: pid_t, element: AXElement?, text: String, append: Bool) async throws -> WriteVerification {
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
            try await AXExecutor.pause(writeVerifyPollInterval)
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
            description: "Click a UI element (AX press action) or at screen coordinates. PREFER `elementId` from a prior snapshot/describe_screen — it acts on that exact element with no tree search, and it is both faster and more reliable than a selector. Fall back to selectors only for elements you have not snapshotted: role+title/identifier when known, labelContains when you see the text on-screen but don't know which AX attribute carries it (common with SwiftUI buttons that stash labels in AXDescription); a selector matching nothing in a rendered UI fails fast; one that may just not have rendered yet retries until `timeout`. Element searches default to the focused window (scope:'window'); pass scope:'app' to search every window of the app. The menu bar is NOT searched even then (closed menu items would match every 'Save'/'Close'): add includeMenus:true, or use an AXMenu* role, or use navigate_menu. Issuing several clicks? Send them as one `run_steps` call rather than one call each. BACKGROUND-SAFE BY DEFAULT: the element path uses AXPress and the coordinate path posts to the target PID — neither moves the user's mouse cursor, brings the app forward, nor steals keyboard focus. A DISABLED control is reported as an error, not a false success. Set foreground:true ONLY for apps that ignore targeted events (Electron/games) — that activates the app, verifies it actually became frontmost (error and nothing sent if not), and injects a global click (moves the real cursor). Auto-routes: CDP click for web refs, bpy select for Blender scene ids, idb tap for iOS; you do not pick the backend.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "elementId": .object(["type": .string("string"), "description": .string("Handle id (e.g. 'e7') from a prior snapshot/describe_screen — acts on that element directly, skipping the search")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (focused window, default) or 'app' (all windows; the menu bar only with includeMenus or an AXMenu* role)")]),
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
                    return try await coordinateInput(pid: pid, x: x, y: y, foreground: foreground, echoPoint: true) { target, point in
                        InputSimulator.click(at: point, pid: target)
                    }
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = try await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, searchRole, staleHandle): (AXElement, String?, Bool)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .busyHandle(let id):
                    return busyHandleError(id)
                case .handle(let e):
                    (element, searchRole, staleHandle) = (e, nil, false)
                case .found(let e, let r, _):
                    (element, searchRole, staleHandle) = (e, r, false)
                case .foundAfterStaleHandle(let e, let r, _):
                    (element, searchRole, staleHandle) = (e, r, true)
                }

                enum PressOutcome: Sendable {
                    case pressed(role: String)
                    case disabled(role: String)
                    case refused(role: String)
                }
                let outcome: PressOutcome = await AXExecutor.app(pid).run {
                    let state = probe(element)
                    let role = state.role ?? searchRole ?? "element"
                    guard state.enabled else { return .disabled(role: role) }
                    return element.press() ? .pressed(role: role) : .refused(role: role)
                }
                switch outcome {
                case .disabled(let role):
                    return disabledError(role: role, action: "AXPress")
                case .refused(let role):
                    return ToolResult.error("Found \(role) but the press action was refused — the element may not accept AXPress. Try clicking its coordinates (x/y from snapshot's frame) instead.")
                case .pressed(let role):
                    await noteActed(on: target, args: args)
                    return ToolResult.action(success: true, method: "accessibility", extra: [
                        "found": .bool(true),
                        "role": .string(role),
                        "staleHandle": .bool(staleHandle),
                    ])
                }
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
                    return try await coordinateInput(pid: pid, x: x, y: y, foreground: foreground) { target, point in
                        InputSimulator.doubleClick(at: point, pid: target)
                    }
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = try await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, searchRole): (AXElement, String?)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .busyHandle(let id):
                    return busyHandleError(id)
                case .handle(let e):
                    (element, searchRole) = (e, nil)
                case .found(let e, let r, _), .foundAfterStaleHandle(let e, let r, _):
                    (element, searchRole) = (e, r)
                }

                // Try AX double-press (background-safe for most standard controls).
                // Three distinct outcomes — the old CGPoint? return overloaded nil as
                // both "pressed fine" and "refused with no geometry", reporting the
                // latter as a false success.
                enum DoublePressOutcome: Sendable {
                    case pressed(role: String)
                    case disabled(role: String)
                    case fallback(CGPoint, role: String)
                    case refusedNoGeometry(role: String)
                }
                let outcome: DoublePressOutcome = await AXExecutor.app(pid).run {
                    let state = probe(element)
                    let role = state.role ?? searchRole ?? "element"
                    guard state.enabled else { return .disabled(role: role) }
                    let first = element.press()
                    let second = element.press()
                    if first && second { return .pressed(role: role) }
                    // AX press refused — compute the element center for a coordinate fallback.
                    guard let pos = element.position, let sz = element.size else {
                        return .refusedNoGeometry(role: role)
                    }
                    return .fallback(CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2), role: role)
                }

                switch outcome {
                case .disabled(let role):
                    return disabledError(role: role, action: "AXPress")
                case .refusedNoGeometry(let role):
                    return ToolResult.error("Found \(role) but the press action was refused and the element exposes no frame for a coordinate fallback. Re-snapshot and try its parent row/cell, or click by coordinates.")
                case .fallback(let pt, let role):
                    // AX press returned false; use coordinate-based double click as fallback.
                    // Background-safe: deliver to the target PID (no cursor warp, no
                    // activation). foreground:true restores activate + global HID.
                    if case .refused(let error) = try await deliver(pid: pid, foreground: foreground, { InputSimulator.doubleClick(at: pt, pid: $0) }) {
                        return error
                    }
                    await noteActed(on: target, args: args)
                    return ToolResult.action(success: true, method: foreground ? "coordinate-fallback" : "coordinate-fallback-pid", extra: [
                        "found": .bool(true), "role": .string(role), "activated": .bool(foreground),
                    ])
                case .pressed(let role):
                    await noteActed(on: target, args: args)
                    return ToolResult.action(success: true, method: "accessibility", extra: [
                        "found": .bool(true), "role": .string(role),
                    ])
                }
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
                    return try await coordinateInput(pid: pid, x: x, y: y, foreground: foreground) { target, point in
                        InputSimulator.rightClick(at: point, pid: target)
                    }
                }

                let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                let target = try await resolveTarget(pid: pid, args: args, timeout: timeout)

                let (element, searchRole): (AXElement, String?)
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .busyHandle(let id):
                    return busyHandleError(id)
                case .handle(let e):
                    (element, searchRole) = (e, nil)
                case .found(let e, let r, _), .foundAfterStaleHandle(let e, let r, _):
                    (element, searchRole) = (e, r)
                }

                enum ShowOutcome: Sendable {
                    case shown(role: String)
                    case disabled(role: String)
                    case refused(role: String)
                }
                let outcome: ShowOutcome = await AXExecutor.app(pid).run {
                    let state = probe(element)
                    let role = state.role ?? searchRole ?? "element"
                    guard state.enabled else { return .disabled(role: role) }
                    return element.showMenu() ? .shown(role: role) : .refused(role: role)
                }
                switch outcome {
                case .disabled(let role):
                    return disabledError(role: role, action: "AXShowMenu")
                case .refused(let role):
                    return ToolResult.error("Found \(role) but the showMenu action was refused")
                case .shown(let role):
                    await noteActed(on: target, args: args)
                    return ToolResult.action(success: true, method: "accessibility", extra: [
                        "found": .bool(true), "role": .string(role),
                    ])
                }
            }
        ))

        registry.register(.init(
            name: "type_text",
            description: "Type text into the focused element, or into a specific element matched by selector/elementId. BACKGROUND-SAFE BY DEFAULT: for AXTextField/AXTextArea the value is set directly via AX (replaces the field, no keystrokes, no focus steal); a search field additionally gets its action fired, because setting the string alone changes the text without running the search. When AX-set is rejected (e.g. some SwiftUI fields) the keyboard fallback focuses the control via AX (kAXFocusedAttribute, no app activation) and delivers keystrokes to the target PID — the user's keyboard focus and cursor are never disturbed. THE WRITE IS THEN READ BACK: `verified:true` means the text is observably in the field, an error means it demonstrably is not, and `verified:false` means the element exposes no readable value so you must confirm with read_text/assert_value (common for web content). By default the fallback replaces the field's existing text so re-running does not double it — but ONLY for a resolved text field (AXTextField/AXTextArea/AXComboBox) whose focus AX confirmed, and via AX (select-all through the selection range, or an emptied value), never by sending Cmd+A/Delete keys; with no selector, or any other element, nothing is cleared, the text is inserted at the caret, and the result says `cleared:false` with `clearSkipped` explaining why. Pass append:true to keep existing content on purpose. When a selector/elementId resolved an element but AX could not confirm focus on it, NOTHING is typed and the call errors — keystrokes to an unfocused control would land in whatever else holds the app's focus; click the element first, then type_text without a selector. Set foreground:true only for apps that ignore PID-targeted keys (activates the app and types via the global HID stream, in short chunks: the app is re-verified frontmost before each, and typing stops with an error naming how much went out if the user switched away).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "text": .object(["type": .string("string"), "description": .string("Text to type")]),
                    "append": .object(["type": .string("boolean"), "description": .string("Keyboard fallback only: when true, keep existing field content and append; when false (default), replace a resolved text field's content first so re-running does not double the text (never clears without a selector/elementId)")]),
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
                var focusElement: AXElement?
                var focusRole: String?
                var actedTarget: ResolvedTarget?
                if hasTarget {
                    let timeout = args?["timeout"]?.doubleValue ?? defaultFindTimeout
                    let target = try await resolveTarget(pid: pid, args: args, timeout: timeout)
                    switch target {
                    case .none:
                        return ToolResult.error("No element matched selector: \(describe(args))")
                    case .staleHandleNoFallback(let id):
                        return staleHandleError(id)
                    case .busyHandle(let id):
                        return busyHandleError(id)
                    case .handle(let e), .found(let e, _, _), .foundAfterStaleHandle(let e, _, _):
                        switch try await setValueViaAX(pid: pid, element: e, text: text) {
                        case .set(let committed):
                            await noteActed(on: target, args: args)
                            var extra: [String: JSONValue] = [
                                "typed": .string(text), "found": .bool(true), "verified": .bool(true),
                            ]
                            if committed { extra["committed"] = .bool(true) }
                            return ToolResult.action(success: true, method: "accessibility", extra: extra)
                        case .fallback(let role):
                            (focusElement, focusRole) = (e, role)
                            actedTarget = target
                        }
                    }
                }

                // Keyboard (CGEvent) fallback.
                //
                // Background-safe (default): focus the resolved control via AX
                // (kAXFocusedAttribute steers where text lands WITHOUT activating the
                // app), then deliver the keystrokes to the target PID via postToPid. No
                // cursor move, no app activation, no global HID.
                //
                // foreground:true: activate the app, confirm it is frontmost, and type
                // through the global HID stream — the escape hatch for apps that ignore
                // PID-targeted keys.
                let capturedFocus = focusElement
                let capturedRole = focusRole
                struct KeyboardDelivery: Sendable {
                    // Whether AX accepted the focus request matters: posting keystrokes to
                    // a control we could not focus sends them to whatever the app's first
                    // responder happens to be, which is exactly how "typed successfully"
                    // ends up in the wrong field.
                    let focusSet: Bool?
                    let clear: ClearDecision
                    let cleared: Bool
                    /// False when a resolved target's focus was not confirmed: nothing was posted.
                    let typed: Bool
                }
                // Foreground typing is posted in chunks with the target re-verified frontmost
                // before each (see `deliverChunked`); background it is one lane hop, as before.
                let pieces = foreground ? typingChunks(text) : [text]
                let delivery = try await deliverChunked(
                    pid: pid, foreground: foreground, chunks: pieces.count,
                    progress: { sent in "\(pieces.prefix(sent).reduce(0) { $0 + $1.count }) of \(text.count) characters" },
                    onInterrupt: { _ in },
                    body: { target, chunk -> KeyboardDelivery? in
                        guard chunk == 0 else {
                            InputSimulator.typeText(pieces[chunk], pid: target)
                            return nil
                        }
                        var focusSet: Bool?
                        var focusConfirmed = false
                        if let element = capturedFocus {
                            let accepted = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
                            focusSet = accepted
                            // A set that returns success but leaves the element unfocused still
                            // routes keys elsewhere; only an affirmative readback or an
                            // unreadable one (trusting the set) counts as confirmed.
                            focusConfirmed = accepted && (element.attribute(kAXFocusedAttribute) as Bool?) != false
                        }
                        // The error comes BEFORE the first keystroke: telling the agent
                        // afterwards that the text went in blind leaves it in the wrong field.
                        guard keystrokesMayBePosted(targetResolved: capturedFocus != nil, focusConfirmed: focusConfirmed) else {
                            return KeyboardDelivery(focusSet: focusSet, clear: .notRequested, cleared: false, typed: false)
                        }
                        // Clearing is the one destructive step, so it never uses key chords: a
                        // Cmd+A/ForwardDelete posted at an unresolved or unfocused target wipes
                        // whatever the app's first responder is — the user's document.
                        let decision = clearDecision(append: append, role: capturedFocus == nil ? nil : capturedRole, focusConfirmed: focusConfirmed)
                        var cleared = false
                        if case .clear = decision, let element = capturedFocus { cleared = clearViaAX(element) }
                        InputSimulator.typeText(pieces[0], pid: target)
                        return KeyboardDelivery(focusSet: focusSet, clear: decision, cleared: cleared, typed: true)
                    }
                )
                let sent: KeyboardDelivery
                switch delivery {
                case .refused(let error): return error
                case .delivered(let results):
                    guard let first = results.first, let value = first else {
                        return ToolResult.error("type_text delivered nothing")
                    }
                    sent = value
                }
                guard sent.typed else { return ToolResult.error(focusUnconfirmedError) }
                let focusSet = sent.focusSet

                // Without a clear the field still holds its old content, so "contains the
                // text" is the claim to verify, not "equals the text".
                let verification = try await verifyWrite(pid: pid, element: capturedFocus, text: text, append: append || !sent.cleared)
                var extra: [String: JSONValue] = [
                    "typed": .string(text),
                    "appended": .bool(append),
                    "activated": .bool(foreground),
                ]
                if let focusSet { extra["focused"] = .bool(focusSet) }
                var clearNote: String?
                if !append {
                    extra["cleared"] = .bool(sent.cleared)
                    switch sent.clear {
                    case .skipped(let reason): clearNote = reason
                    case .clear where !sent.cleared: clearNote = "AX refused to select or empty the field's existing text"
                    default: break
                    }
                    if let clearNote {
                        extra["clearSkipped"] = .string("Existing content was NOT cleared — \(clearNote). The text was inserted at the caret; pass a selector for a text field or click into it first to replace its content.")
                    }
                }

                switch verification {
                case .landed:
                    if let actedTarget { await noteActed(on: actedTarget, args: args) }
                    extra["verified"] = .bool(true)
                    return ToolResult.action(success: true, method: "keyboard", extra: extra)
                case .didNotLand(let observed):
                    return ToolResult.error("Typed \(text.count) character(s) into the matched element but the text did NOT land — the field still reads '\(observed)'. The keystrokes went to the app but not to this control: it may be read-only, may reject synthetic input, or another control holds the app's focus. Click the element first, then retry.")
                case .unverifiable:
                    extra["verified"] = .bool(false)
                    // Two different reasons for the same verdict, and telling the caller
                    // which one applies is the difference between a fixable call and a
                    // shrug: no selector means we never had an element to read back, so
                    // the fix is to name one.
                    extra["verificationNote"] = .string(capturedFocus == nil
                        ? "No selector was given, so the text went to whatever already held the app's focus and there was no element to read back. Pass a selector or elementId to get a verified write."
                        : "The element exposes no readable AXValue, so the write could not be confirmed. Verify with read_text, assert_value or screenshot_window before depending on it. Web content (Safari/Chrome) and canvas-drawn fields commonly behave this way.")
                    if let actedTarget { await noteActed(on: actedTarget, args: args) }
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
                let target = try await resolveTarget(pid: pid, args: args, timeout: timeout)

                let element: AXElement
                switch target {
                case .none:
                    return ToolResult.error("No element matched selector: \(describe(args))")
                case .staleHandleNoFallback(let id):
                    return staleHandleError(id)
                case .busyHandle(let id):
                    return busyHandleError(id)
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
                    return disabledError(role: described.role, action: action)
                }

                let performed = await AXExecutor.app(pid).run { element.performAction(action) }
                guard performed else {
                    return ToolResult.error("\(described.role) advertises '\(action)' but refused it. The control may require the app to be active, or its state may have changed since the snapshot — re-snapshot and retry.")
                }
                await noteActed(on: target, args: args)
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
                if case .refused(let error) = try await deliver(pid: pid, foreground: foreground, {
                    InputSimulator.sendShortcut(keyCode: keyCode, modifiers: flags, pid: $0)
                }) {
                    return error
                }
                return ToolResult.action(success: true, method: "keyboard", extra: [
                    "activated": .bool(foreground),
                    "key": .string(keyName),
                ])
            }
        ))
    }
}
