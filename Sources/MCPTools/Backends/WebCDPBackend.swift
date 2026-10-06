import Foundation
import MCPServer
import AccessibilityEngine

/// Chrome DevTools Protocol backend. One session = one page target, keyed by the URL the
/// agent named. Every session lives in the single headless Chromium this app owns (as its
/// own tab), or in a user Chrome that already exposes a debug port.
actor WebCDPBackend {
    static let shared = WebCDPBackend()

    struct Session: Sendable {
        var key: String
        var targetId: String
        var port: UInt16
        var debuggerURL: URL
        /// The page's CURRENT url, refreshed whenever it is read. It used to be written
        /// once at connect (always "about:blank" for a fresh Chromium) and then compared
        /// against the requested url, so every call looked like a navigation.
        var browserURL: String
        var headless: Bool
        var attached: Bool
        /// A tab in a user's Chrome that was theirs before this session: a page they already
        /// had open. Never navigated — `.ifDifferent` opens a separate tab instead — because
        /// loading something else into it destroys whatever they were doing there.
        var adopted: Bool
        /// False when the last navigation never reported its load event within the wait.
        var loaded: Bool
        var lastUsed: Date
    }

    enum Navigation {
        /// Navigate only when the session is created. Same url + later calls means "keep
        /// driving that page" — a click that moved it to another route must not be undone.
        case ifNew
        /// An explicit open: go to the url unless the page is already there.
        case ifDifferent
    }

    enum Presence {
        case present
        case absent
    }

    struct PageSnapshot: Sendable {
        var refs: [RoutedRef]
        var key: String
        var url: String?
        var loaded: Bool
    }

    struct QueryOutcome: Sendable {
        var refs: [RoutedRef]
        /// Indices into `refs`.
        var matched: [Int]
        var key: String
        var satisfied: Bool
        var elapsed: TimeInterval
    }

    /// Tabs this app opened. Beyond this many, the least recently used is closed so a
    /// long agent run over many urls doesn't grow Chromium without bound.
    static let maxOwnedSessions = 8
    static let loadTimeout: TimeInterval = 20

    private var connections: [String: CDPConnection] = [:]
    private var sessions: [String: Session] = [:]
    private var opening: [String: Task<Session, Error>] = [:]
    private var claimedTargets: Set<String> = []
    /// Tabs this backend opened in a user's Chrome. Everything else in an attached browser
    /// is the user's.
    private var createdTargets: Set<String> = []
    private var launching: Task<OwnedChrome, Error>?

    /// One session per page. A browser identity with a page hint is one session PER page
    /// (two pages open in the same Chrome are two sessions, not one tab read twice), and a
    /// `headless:true` call never shares a session with an attached one for the same URL.
    static func key(for identity: TargetIdentity) -> String {
        var key = identity.url?.absoluteString ?? identity.raw
        if identity.url == nil, let hint = identity.pageHint { key += "@" + hint.absoluteString }
        return identity.headless ? "headless:" + key : key
    }

    func inspectAvailability() async -> (binary: String?, debugPort: UInt16?, attached: Bool) {
        let binary = ChromeLauncher.findBinary()
        if let port = await ChromeLauncher.findExistingDebugPort() {
            return (binary, port, true)
        }
        if let owned = OwnedChromeRegistry.current, owned.isRunning {
            return (binary, owned.port, false)
        }
        return (binary, nil, false)
    }

    /// Close every socket and terminate the Chromium this app launched.
    func shutdown() async {
        for task in opening.values { task.cancel() }
        launching?.cancel()
        for connection in connections.values { await connection.close(reason: "shutdown") }
        opening.removeAll()
        connections.removeAll()
        sessions.removeAll()
        claimedTargets.removeAll()
        createdTargets.removeAll()
        OwnedChromeRegistry.take()?.terminate()
    }

    // MARK: - Sessions

    func session(
        for identity: TargetIdentity,
        navigation: Navigation = .ifNew,
        reusing targetId: String? = nil
    ) async throws -> Session {
        let key = Self.key(for: identity)
        var newTab = false
        if let existing = sessions[key], let connection = connections[key], await connection.isOpen {
            var session = existing
            session.lastUsed = Date()
            sessions[key] = session
            guard navigation == .ifDifferent, let url = identity.url else { return session }
            let current = try await currentURL(connection)
            switch CDPNavigation.reopenAction(adopted: session.adopted, currentURL: current, requested: url) {
            case .keep:
                session.browserURL = current
                sessions[key] = session
                return session
            case .navigate:
                session.loaded = try await navigate(connection, to: url)
                session.browserURL = (try? await currentURL(connection)) ?? url.absoluteString
                sessions[key] = session
                return session
            case .newTab:
                newTab = true
            }
        }
        // Join an open already under way before `forget`: it registers its connection
        // before its session, and forgetting here would close it mid-navigation.
        if !newTab, let inflight = opening[key] { return try await inflight.value }
        forget(key)
        let task = Task { try await self.open(identity: identity, reusing: targetId, newTab: newTab) }
        opening[key] = task
        defer { opening[key] = nil }
        return try await task.value
    }

    private func forget(_ key: String) {
        if let connection = connections.removeValue(forKey: key) {
            Task { await connection.close(reason: "dropped") }
        }
        if let session = sessions.removeValue(forKey: key) {
            claimedTargets.remove(session.targetId)
        }
    }

    private func open(identity: TargetIdentity, reusing targetId: String?, newTab: Bool) async throws -> Session {
        let key = Self.key(for: identity)
        let (port, attached) = try await endpoint(isolated: identity.headless)
        let pages = try await ChromeLauncher.listPages(port: port)
        let pick = try await pickTarget(
            pages, port: port, identity: identity, attached: attached, reusing: targetId, newTab: newTab
        )
        if !attached { try await evictIfNeeded(port: port) }
        let page = pick.page
        if attached && pick.created { createdTargets.insert(page.id) }

        let connection = CDPConnection(url: page.webSocketDebuggerURL)
        do {
            try await connection.open()
        } catch {
            if pick.created { await ChromeLauncher.closePage(port: port, id: page.id) }
            throw error
        }
        claimedTargets.insert(page.id)
        connections[key] = connection
        var session = Session(
            key: key, targetId: page.id, port: port, debuggerURL: page.webSocketDebuggerURL,
            browserURL: page.url, headless: !attached, attached: attached,
            adopted: attached && !createdTargets.contains(page.id), loaded: true, lastUsed: Date()
        )
        if let url = identity.url, pick.navigate {
            do {
                session.loaded = try await navigate(connection, to: url)
            } catch {
                forget(key)
                throw error
            }
        }
        if let current = try? await currentURL(connection) { session.browserURL = current }
        sessions[key] = session
        return session
    }

    /// `isolated` is an explicit `headless:true`: the page must not be loaded into whatever
    /// Chrome the user happens to have open with a debug port, so only the private headless
    /// Chromium this app owns is ever used. Without it, a user's Chrome is attached to when
    /// one is reachable.
    private func endpoint(isolated: Bool) async throws -> (port: UInt16, attached: Bool) {
        if !isolated, let port = await ChromeLauncher.findExistingDebugPort() { return (port, true) }
        guard ChromeLauncher.findBinary() != nil else {
            throw ToolError.actionFailed("No Chromium browser found. Install Chrome/Chromium/Edge, or launch Chrome with --remote-debugging-port=9222 to attach to a user session.")
        }
        return (try await ensureOwnedChrome(headless: true).port, false)
    }

    private func ensureOwnedChrome(headless: Bool) async throws -> OwnedChrome {
        if let chrome = OwnedChromeRegistry.current, chrome.isRunning { return chrome }
        if let inflight = launching { return try await inflight.value }
        let task = Task { try await ChromeLauncher.launchOwned(headless: headless) }
        launching = task
        defer { launching = nil }
        return try await task.value
    }

    private struct Pick {
        var page: ChromeLauncher.PageTarget
        /// The tab has to be taken to the identity's url.
        var navigate: Bool
        /// This call opened the tab.
        var created: Bool
    }

    private func pickTarget(
        _ pages: [ChromeLauncher.PageTarget],
        port: UInt16,
        identity: TargetIdentity,
        attached: Bool,
        reusing targetId: String?,
        newTab: Bool
    ) async throws -> Pick {
        // A dropped socket, not a dropped page: go back to the same tab, state intact.
        if let targetId, let page = pages.first(where: { $0.id == targetId }) {
            return Pick(page: page, navigate: false, created: false)
        }
        let free = pages.filter { !claimedTargets.contains($0.id) }
        guard let url = identity.url else {
            // An app identity (e.g. "com.google.Chrome") on a user browser. Whoever opened
            // the page said which one it is; guessing "the first tab" reads and drives
            // whatever the user happens to have in front.
            if let hint = identity.pageHint {
                guard let page = CDPNavigation.tab(in: free, for: hint) else {
                    throw ToolError.actionFailed("The attached Chrome has no unclaimed tab on \(hint.absoluteString) (the page may have redirected elsewhere). Nothing was read. Open the page again, or snapshot it by the URL it ended up on.")
                }
                return Pick(page: page, navigate: false, created: false)
            }
            guard let page = free.first ?? pages.first else {
                throw ToolError.actionFailed("Chrome has no page target to attach to")
            }
            return Pick(page: page, navigate: false, created: false)
        }
        if attached {
            // A user's tab already on this exact page is theirs and already loaded: use it
            // as-is. Never repurpose one that is not — navigating it would clobber their
            // work. The page goes in a new tab, opened in the background so the tab the
            // user is looking at does not change under them.
            if !newTab, let match = free.first(where: { CDPNavigation.pageMatches($0.url, requested: url) }) {
                return Pick(page: match, navigate: false, created: false)
            }
            return Pick(page: try await ChromeLauncher.newBackgroundPage(port: port), navigate: true, created: true)
        }
        if let blank = free.first(where: { $0.url == "about:blank" }) {
            return Pick(page: blank, navigate: true, created: false)
        }
        return Pick(page: try await ChromeLauncher.newPage(port: port), navigate: true, created: false)
    }

    private func evictIfNeeded(port: UInt16) async throws {
        guard sessions.count >= Self.maxOwnedSessions,
              let oldest = sessions.values.min(by: { $0.lastUsed < $1.lastUsed }) else { return }
        forget(oldest.key)
        await ChromeLauncher.closePage(port: port, id: oldest.targetId)
    }

    // MARK: - Navigation

    /// Navigate and wait for the page's load event. Returns false instead of throwing when
    /// the event never comes: a page that is slow (or never finishes loading) is still
    /// worth a snapshot of whatever rendered, and the caller says so in the result.
    private func navigate(_ connection: CDPConnection, to url: URL) async throws -> Bool {
        // Armed before the command: the event can beat the command's own response.
        let token = await connection.armEvent("Page.loadEventFired")
        let result: JSONValue
        do {
            result = try await connection.send(method: "Page.navigate", params: .object(["url": .string(url.absoluteString)]))
        } catch {
            await connection.disarmEvent(token)
            throw error
        }
        if let reason = result["errorText"]?.stringValue, !reason.isEmpty {
            await connection.disarmEvent(token)
            throw CDPError.navigationFailed(url: url.absoluteString, reason: reason)
        }
        // A same-document navigation (#fragment, pushState) has no loader and fires no load.
        guard result["loaderId"] != nil else {
            await connection.disarmEvent(token)
            return true
        }
        return await connection.awaitEvent(token, timeout: Self.loadTimeout)
    }

    private func currentURL(_ connection: CDPConnection) async throws -> String {
        let result = try await connection.send(
            method: "Runtime.evaluate",
            params: .object(["expression": .string("location.href"), "returnByValue": .bool(true)])
        )
        return result["result"]?["value"]?.stringValue ?? ""
    }

    // MARK: - Running against a session

    /// Runs `body` against the page, reconnecting once if the socket died. The dead
    /// connection used to stay cached, so one dropped socket failed every later call.
    private func perform<T>(
        _ identity: TargetIdentity,
        navigation: Navigation = .ifNew,
        _ body: (CDPConnection, Session) async throws -> T
    ) async throws -> T {
        let key = Self.key(for: identity)
        var reusing: String?
        for attempt in 0..<2 {
            do {
                let session = try await session(for: identity, navigation: navigation, reusing: reusing)
                guard let connection = connections[key] else { throw CDPError.transport("session was dropped") }
                return try await body(connection, session)
            } catch let error as CDPError where error.isTransport && attempt == 0 {
                reusing = sessions[key]?.targetId
                forget(key)
            }
        }
        throw CDPError.transport("could not reconnect")
    }

    /// Element operations act on the connection their snapshot came from. There is no
    /// "any connection" fallback: acting on a different page than the id came from is
    /// worse than failing.
    private func perform<T>(ref key: String, _ body: (CDPConnection) async throws -> T) async throws -> T {
        guard let connection = connections[key], await connection.isOpen else {
            forget(key)
            throw CDPError.stale
        }
        do {
            return try await body(connection)
        } catch let error as CDPError where error.isTransport {
            forget(key)
            throw error
        }
    }

    // MARK: - Snapshot and queries

    func snapshot(identity: TargetIdentity, interactiveOnly: Bool) async throws -> PageSnapshot {
        try await perform(identity) { connection, session in
            let document = try await documentId(connection)
            let refs = try await axRefs(connection, session: session, document: document, interactiveOnly: interactiveOnly)
            let url = try? await currentURL(connection)
            if let url { sessions[session.key]?.browserURL = url }
            return PageSnapshot(refs: refs, key: session.key, url: url ?? session.browserURL, loaded: session.loaded)
        }
    }

    /// `document` must be read BEFORE the tree: a navigation in between then leaves refs
    /// tagged with the old document, which fail as stale. Read after, they would carry the
    /// new document's id and pass as nodes of a page they never belonged to.
    private func axRefs(
        _ connection: CDPConnection,
        session: Session,
        document: String,
        interactiveOnly: Bool
    ) async throws -> [RoutedRef] {
        _ = try await connection.send(method: "Accessibility.enable")
        let tree = try await connection.send(method: "Accessibility.getFullAXTree", timeout: 30)
        return CDPAccessibility.flatten(
            nodes: tree["nodes"]?.arrayValue ?? [],
            interactiveOnly: interactiveOnly,
            sessionKey: session.key,
            document: document
        )
    }

    /// The main frame's loaderId: one per loaded document, unchanged by same-document
    /// navigations (pushState, #fragment).
    private func documentId(_ connection: CDPConnection) async throws -> String {
        let tree = try await connection.send(method: "Page.getFrameTree")
        guard let loader = tree["frameTree"]?["frame"]?["loaderId"]?.stringValue, !loader.isEmpty else {
            throw CDPError.remote("Page.getFrameTree reported no loaderId for the main frame")
        }
        return loader
    }

    /// Element ids are only good on the document they were read from. Chrome numbers DOM
    /// nodes per renderer process, and a cross-site navigation swaps the process: measured,
    /// the backendNodeId of a password field on one origin resolved, after the tab moved to
    /// another origin, to an unrelated <input> there. Without this, `type_text` on the old
    /// id typed into the other site and reported success. Callers check AFTER reading the
    /// node and BEFORE acting on it, so a navigation anywhere up to the check is caught.
    private func requireDocument(_ document: String, _ connection: CDPConnection) async throws {
        guard try await documentId(connection) == document else { throw CDPError.stale }
    }

    /// Polls the live page until `expect` holds or `timeout` passes. Always makes at least
    /// one pass, and never gives up before the deadline — a page that is still rendering is
    /// the normal case, not an error.
    func query(
        identity: TargetIdentity,
        selector: CDPSelector,
        expect: Presence,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws -> QueryOutcome {
        let started = Date()
        while true {
            var outcome = try await perform(identity) { connection, session -> QueryOutcome in
                let document = try await documentId(connection)
                var refs = try await axRefs(connection, session: session, document: document, interactiveOnly: false)
                var identified: Set<Int>?
                if let identifier = selector.identifier {
                    identified = try await backendNodeIds(forIdentifier: identifier, connection: connection)
                    // The element exists in the DOM even where the AX tree drops it (an
                    // ignored wrapper div); it still counts as found.
                    let known = Set(refs.compactMap { ref -> Int? in
                        if case .cdp(_, _, let id, _, _) = ref { return id } else { return nil }
                    })
                    for id in identified?.subtracting(known).sorted() ?? [] {
                        refs.append(.cdp(sessionKey: session.key, document: document, backendNodeId: id, role: "element", label: identifier))
                    }
                }
                let matched = selector.select(refs, identifiedNodes: identified)
                return QueryOutcome(refs: refs, matched: matched, key: session.key, satisfied: false, elapsed: 0)
            }
            outcome.elapsed = Date().timeIntervalSince(started)
            outcome.satisfied = expect == .present ? !outcome.matched.isEmpty : outcome.matched.isEmpty
            if outcome.satisfied || outcome.elapsed >= timeout { return outcome }
            // Not Task.sleep(for: .seconds(…)): the Duration conversion traps past ~1.7e20s,
            // and both numbers are the agent's (`timeout`/`pollInterval: 1e300` crashed the
            // server). `pause` caps the interval.
            try await AXExecutor.pause(min(pollInterval, max(timeout - outcome.elapsed, 0.05)))
        }
    }

    private func backendNodeIds(forIdentifier identifier: String, connection: CDPConnection) async throws -> Set<Int> {
        let document = try await connection.send(method: "DOM.getDocument", params: .object(["depth": .int(0)]))
        guard let root = document["root"]?["nodeId"]?.intValue else { return [] }
        let found = try await connection.send(
            method: "DOM.querySelectorAll",
            params: .object(["nodeId": .int(root), "selector": .string(CDPSelector.cssSelector(forIdentifier: identifier))])
        )
        var ids: Set<Int> = []
        for nodeId in (found["nodeIds"]?.arrayValue ?? []).compactMap(\.intValue).prefix(50) {
            let described = try await connection.send(method: "DOM.describeNode", params: .object(["nodeId": .int(nodeId)]))
            if let backend = described["node"]?["backendNodeId"]?.intValue { ids.insert(backend) }
        }
        return ids
    }

    // MARK: - Element actions

    /// Scroll into view, then a real pointer click at the element's centre. `this.click()`
    /// fired no pointer/mouse events (many widgets listen for those) and never scrolled;
    /// a double click needs the clickCount-2 press for the browser to emit `dblclick`.
    func click(ref: RoutedRef, clickCount: Int = 1) async throws {
        guard case .cdp(let key, let document, let backendNodeId, _, _) = ref else {
            throw ToolError.actionFailed("Not a CDP element")
        }
        try await perform(ref: key) { connection in
            let node = JSONValue.object(["backendNodeId": .int(backendNodeId)])
            _ = try await connection.send(method: "DOM.scrollIntoViewIfNeeded", params: node)
            let quads = try await connection.send(method: "DOM.getContentQuads", params: node)
            let metrics = try await connection.send(method: "Page.getLayoutMetrics")
            guard let point = CDPGeometry.clickPoint(
                quads: CDPGeometry.quads(from: quads),
                viewport: CDPGeometry.viewport(from: metrics)
            ) else {
                throw CDPError.notClickable("it has no visible area (display:none, zero size, or fully clipped)")
            }
            try await requireDocument(document, connection)
            try await mouse(connection, "mouseMoved", point, button: "none", buttons: 0, clickCount: 0)
            for press in 1...max(clickCount, 1) {
                try await mouse(connection, "mousePressed", point, button: "left", buttons: 1, clickCount: press)
                try await mouse(connection, "mouseReleased", point, button: "left", buttons: 0, clickCount: press)
            }
        }
    }

    private func mouse(
        _ connection: CDPConnection,
        _ type: String,
        _ point: CDPPoint,
        button: String,
        buttons: Int,
        clickCount: Int
    ) async throws {
        _ = try await connection.send(
            method: "Input.dispatchMouseEvent",
            params: .object([
                "type": .string(type),
                "x": .double(point.x),
                "y": .double(point.y),
                "button": .string(button),
                "buttons": .int(buttons),
                "clickCount": .int(clickCount),
            ])
        )
    }

    /// Focus, select the existing content, then insert the text through the input
    /// pipeline. Assigning `this.value` skips it: React-style controlled inputs track
    /// value through input events and reset the field on the next render.
    func typeText(ref: RoutedRef, text: String) async throws {
        guard case .cdp(let key, let document, let backendNodeId, _, _) = ref else {
            throw ToolError.actionFailed("Not a CDP element")
        }
        try await perform(ref: key) { connection in
            let objectId = try await resolve(connection, backendNodeId: backendNodeId)
            try await requireDocument(document, connection)
            let focused = try await connection.send(
                method: "Runtime.callFunctionOn",
                params: .object([
                    "objectId": .string(objectId),
                    "functionDeclaration": .string(
                        """
                        function(){
                          this.focus();
                          if ('value' in this && typeof this.select === 'function') { this.select(); }
                          else { const r = document.createRange(); r.selectNodeContents(this); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); }
                        }
                        """
                    ),
                    "returnByValue": .bool(true),
                ])
            )
            try Self.throwIfException(focused)
            if text.isEmpty {
                // insertText("") is a no-op in Chrome; deleting the selection is how a
                // field is cleared.
                for type in ["rawKeyDown", "keyUp"] {
                    _ = try await connection.send(
                        method: "Input.dispatchKeyEvent",
                        params: .object([
                            "type": .string(type), "key": .string("Backspace"), "code": .string("Backspace"),
                            "windowsVirtualKeyCode": .int(8),
                        ])
                    )
                }
            } else {
                _ = try await connection.send(method: "Input.insertText", params: .object(["text": .string(text)]))
            }
        }
    }

    func readText(ref: RoutedRef) async throws -> String {
        guard case .cdp(let key, let document, let backendNodeId, _, let label) = ref else { return "" }
        return try await perform(ref: key) { connection in
            let objectId = try await resolve(connection, backendNodeId: backendNodeId)
            try await requireDocument(document, connection)
            let result = try await connection.send(
                method: "Runtime.callFunctionOn",
                params: .object([
                    "objectId": .string(objectId),
                    "functionDeclaration": .string(
                        "function(){ return this.value !== undefined ? String(this.value) : (this.innerText || this.textContent || ''); }"
                    ),
                    "returnByValue": .bool(true),
                ])
            )
            return result["result"]?["value"]?.stringValue ?? label
        }
    }

    func readAllText(identity: TargetIdentity) async throws -> String {
        let result = try await evaluate(identity: identity, expression: "document.body ? document.body.innerText : ''")
        return result["result"]?["value"]?.stringValue ?? ""
    }

    private func resolve(_ connection: CDPConnection, backendNodeId: Int) async throws -> String {
        let resolved = try await connection.send(
            method: "DOM.resolveNode",
            params: .object(["backendNodeId": .int(backendNodeId)])
        )
        guard let objectId = resolved["object"]?["objectId"]?.stringValue else { throw CDPError.stale }
        return objectId
    }

    // MARK: - Page-level tools

    func evaluate(identity: TargetIdentity, expression: String) async throws -> JSONValue {
        try await perform(identity) { connection, _ in
            let result = try await connection.send(
                method: "Runtime.evaluate",
                params: .object([
                    "expression": .string(expression),
                    "returnByValue": .bool(true),
                    "awaitPromise": .bool(true),
                ]),
                timeout: 60
            )
            try Self.throwIfException(result)
            return result
        }
    }

    func screenshot(identity: TargetIdentity) async throws -> Data {
        try await perform(identity) { connection, _ in
            let result = try await connection.send(
                method: "Page.captureScreenshot",
                params: .object([
                    "format": .string("jpeg"),
                    "quality": .int(70),
                ]),
                timeout: 30
            )
            guard let b64 = result["data"]?.stringValue, let data = Data(base64Encoded: b64) else {
                throw ToolError.actionFailed("Page.captureScreenshot returned no data")
            }
            return data
        }
    }

    /// open_url on the private Chromium: go to the page unless it is already there.
    func openURL(identity: TargetIdentity) async throws -> Session {
        try await perform(identity, navigation: .ifDifferent) { _, session in session }
    }

    /// A JS exception comes back as a normal Runtime response with `exceptionDetails`, not
    /// a protocol error — without this, `run_app_code` reported a thrown script as success.
    static func throwIfException(_ result: JSONValue) throws {
        guard let details = result["exceptionDetails"] else { return }
        let text = details["exception"]?["description"]?.stringValue
            ?? details["exception"]?["value"]?.stringValue
            ?? details["text"]?.stringValue
            ?? "script threw"
        throw CDPError.javascript(text)
    }
}

// MARK: - Pure helpers

struct CDPPoint: Equatable {
    var x: Double
    var y: Double
}

enum CDPGeometry {
    /// `DOM.getContentQuads` → list of 8-number quads (x1,y1 … x4,y4), viewport CSS px.
    static func quads(from response: JSONValue) -> [[Double]] {
        (response["quads"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.doubleValue) }
    }

    static func viewport(from metrics: JSONValue) -> (width: Double, height: Double) {
        let layout = metrics["cssLayoutViewport"] ?? metrics["layoutViewport"]
        return (layout?["clientWidth"]?.doubleValue ?? 0, layout?["clientHeight"]?.doubleValue ?? 0)
    }

    /// Centre of the part of the first quad that is inside the viewport. CSS pixels all the
    /// way: Input.dispatchMouseEvent and DOM quads share the unit, so no device-pixel scale.
    /// An element taller than the viewport still gets a point that is actually on screen.
    static func clickPoint(quads: [[Double]], viewport: (width: Double, height: Double)) -> CDPPoint? {
        for quad in quads where quad.count == 8 {
            let xs = stride(from: 0, to: 8, by: 2).map { quad[$0] }
            let ys = stride(from: 1, to: 8, by: 2).map { quad[$0] }
            let left = max(xs.min() ?? 0, 0)
            let top = max(ys.min() ?? 0, 0)
            let right = viewport.width > 0 ? min(xs.max() ?? 0, viewport.width) : (xs.max() ?? 0)
            let bottom = viewport.height > 0 ? min(ys.max() ?? 0, viewport.height) : (ys.max() ?? 0)
            guard right - left > 1, bottom - top > 1 else { continue }
            return CDPPoint(x: (left + right) / 2, y: (top + bottom) / 2)
        }
        return nil
    }
}

enum CDPNavigation {
    /// Scheme/host lowercased, default port dropped, empty path → "/": the form Chrome
    /// reports in `location.href`, so a requested `https://example.com` equals the
    /// `https://example.com/` the page says it is on.
    static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        if parts.host != nil, parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? url.absoluteString
    }

    enum Reopen: Equatable {
        /// Already on the page.
        case keep
        /// Load the page into the session's own tab.
        case navigate
        /// The tab is the user's and is elsewhere: leave it alone and open the page in a
        /// tab of its own.
        case newTab
    }

    /// What an explicit open of `requested` does to a live session. A tab the user already
    /// had open is never navigated: loading another page into it destroys whatever they
    /// were doing there.
    static func reopenAction(adopted: Bool, currentURL: String?, requested: URL) -> Reopen {
        if isCurrent(currentURL, requested: requested) { return .keep }
        return adopted ? .newTab : .navigate
    }

    /// Is the page already at the requested url? (Not "on the same site" — see `pageMatches`.)
    static func isCurrent(_ current: String?, requested: URL) -> Bool {
        guard let current, let currentURL = URL(string: current) else { return false }
        return canonical(currentURL) == canonical(requested)
    }

    /// Does a user's already-open tab count as the page the agent asked for? Same origin,
    /// and the tab is at or below the requested path (for a bare origin: the front page).
    static func pageMatches(_ pageURL: String, requested: URL) -> Bool {
        guard let page = URL(string: pageURL) else { return false }
        guard requested.host != nil, page.host != nil else { return canonical(page) == canonical(requested) }
        guard let a = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: requested, resolvingAgainstBaseURL: false),
              a.scheme?.lowercased() == b.scheme?.lowercased(),
              a.host?.lowercased() == b.host?.lowercased(),
              effectivePort(a) == effectivePort(b) else { return false }
        let wanted = b.path.hasSuffix("/") ? String(b.path.dropLast()) : b.path
        // A bare origin asks for the site's front page. Reading it as "any page on the site"
        // handed an agent that asked for github.com the user's open private repository.
        if wanted.isEmpty { return a.path.isEmpty || a.path == "/" }
        return a.path == wanted || a.path.hasPrefix(wanted + "/")
    }

    /// The tab a browser identity's page hint points at: the one on exactly that page, else
    /// one at or below it. Nil when none is, which callers report rather than substituting
    /// some other tab.
    static func tab(in pages: [ChromeLauncher.PageTarget], for hint: URL) -> ChromeLauncher.PageTarget? {
        pages.first { isCurrent($0.url, requested: hint) } ?? pages.first { pageMatches($0.url, requested: hint) }
    }

    private static func effectivePort(_ parts: URLComponents) -> Int? {
        parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : parts.scheme?.lowercased() == "http" ? 80 : nil)
    }
}

/// What `assert_visible`, `wait_for_element` and `find_elements` look for on a web page.
struct CDPSelector: Equatable {
    var role: String?
    var identifier: String?
    var exactText: [String] = []
    var containsText: [String] = []
    var index: Int?

    /// Selector keys the AX tools accept that a CDP element ref cannot answer. Failing
    /// loudly beats ignoring one and reporting a pass for the wrong element.
    static let unsupportedKeys = ["value"]

    var isEmpty: Bool {
        role == nil && identifier == nil && exactText.isEmpty && containsText.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if let role { parts.append("role=\(role)") }
        if let identifier { parts.append("identifier=\(identifier)") }
        parts += exactText.map { "text=\($0)" }
        parts += containsText.map { "text~\($0)" }
        return parts.isEmpty ? "(any element)" : parts.joined(separator: ", ")
    }

    static func parse(_ arguments: JSONValue?) throws -> CDPSelector {
        for key in unsupportedKeys where arguments?[key] != nil {
            throw ToolError.invalidParameter("\(key) is not supported on web pages — use labelContains, role or identifier")
        }
        func text(_ key: String) -> String? {
            guard let value = arguments?[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        var selector = CDPSelector()
        selector.role = text("role")
        selector.identifier = text("identifier")
        selector.exactText = ["title", "description"].compactMap(text)
        selector.containsText = ["titleContains", "descriptionContains", "labelContains"].compactMap(text)
        selector.index = arguments?["index"]?.intValue
        return selector
    }

    /// Chrome reports "textbox"/"radio"; AX callers say AXTextField/AXRadioButton.
    static func normalizedRole(_ role: String) -> String {
        var value = role.lowercased()
        if value.hasPrefix("ax") { value = String(value.dropFirst(2)) }
        let aliases = ["textfield": "textbox", "searchfield": "searchbox", "radiobutton": "radio"]
        return aliases[value] ?? value
    }

    /// Indices of the refs that satisfy every criterion, in snapshot order. `identifiedNodes`
    /// is the set of DOM nodes carrying the requested identifier; nil when none was asked for.
    func select(_ refs: [RoutedRef], identifiedNodes: Set<Int>?) -> [Int] {
        var hits: [Int] = []
        for (position, ref) in refs.enumerated() {
            guard case .cdp(_, _, let node, let refRole, let label) = ref else { continue }
            if let role, Self.normalizedRole(role) != Self.normalizedRole(refRole) { continue }
            if let identifiedNodes, !identifiedNodes.contains(node) { continue }
            if exactText.contains(where: { $0.caseInsensitiveCompare(label) != .orderedSame }) { continue }
            if containsText.contains(where: { !label.localizedCaseInsensitiveContains($0) }) { continue }
            hits.append(position)
        }
        guard let index else { return hits }
        return hits.indices.contains(index) ? [hits[index]] : []
    }

    static func cssSelector(forIdentifier identifier: String) -> String {
        let quoted = identifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\a ")
        return ["id", "data-testid", "data-test-id", "data-test", "name"]
            .map { "[\($0)=\"\(quoted)\"]" }
            .joined(separator: ",")
    }
}

enum CDPAccessibility {
    static let interactiveRoles: Set<String> = [
        "button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox",
        "slider", "tab", "menuitem", "switch", "option", "treeitem", "spinbutton",
        "listbox", "menuitemcheckbox", "menuitemradio", "textfield",
    ]

    static func flatten(nodes: [JSONValue], interactiveOnly: Bool, sessionKey: String, document: String) -> [RoutedRef] {
        var refs: [RoutedRef] = []
        for node in nodes {
            if node["ignored"]?.boolValue == true { continue }
            let role = axAtom(node["role"]) ?? "generic"
            let name = axAtom(node["name"]) ?? ""
            if interactiveOnly && !interactiveRoles.contains(role.lowercased()) { continue }
            guard let backend = node["backendDOMNodeId"]?.intValue, backend > 0 else { continue }
            refs.append(.cdp(sessionKey: sessionKey, document: document, backendNodeId: backend, role: role, label: name))
        }
        return refs
    }

    static func compactElements(ids: [String], refs: [RoutedRef]) -> [JSONValue] {
        zip(ids, refs).map { id, ref in
            guard case .cdp(_, _, _, let role, let label) = ref else {
                return .object(["id": .string(id)])
            }
            var fields: [String: JSONValue] = [
                "id": .string(id),
                "role": .string(role),
                "enabled": .bool(true),
            ]
            if !label.isEmpty { fields["label"] = .string(label) }
            return .object(fields)
        }
    }

    private static func axAtom(_ value: JSONValue?) -> String? {
        if let s = value?.stringValue { return s }
        if let s = value?["value"]?.stringValue { return s }
        return nil
    }
}
