import Foundation
import MCPServer
#if canImport(Darwin)
import Darwin
#endif

actor WebCDPBackend {
    static let shared = WebCDPBackend()

    struct Session: Sendable {
        var key: String
        var debuggerURL: URL
        var browserURL: String
        var headless: Bool
        var attached: Bool
    }

    private var connections: [String: CDPConnection] = [:]
    private var sessions: [String: Session] = [:]
    private var ownedChrome: (process: Process, port: UInt16)?

    func inspectAvailability() -> (binary: String?, debugPort: UInt16?, attached: Bool) {
        let binary = ChromeLauncher.findBinary()
        if let port = ChromeLauncher.findExistingDebugPort() {
            return (binary, port, true)
        }
        if let owned = ownedChrome, owned.process.isRunning {
            return (binary, owned.port, false)
        }
        return (binary, nil, false)
    }

    func session(for identity: TargetIdentity, headless: Bool) async throws -> Session {
        let key = identity.url?.absoluteString ?? identity.raw
        if let existing = sessions[key], connections[key] != nil {
            if let url = identity.url, existing.browserURL != url.absoluteString {
                _ = try await navigate(session: existing, url: url)
            }
            return existing
        }
        let session = try await connect(identity: identity, headless: headless)
        sessions[key] = session
        return session
    }

    func snapshot(identity: TargetIdentity, interactiveOnly: Bool) async throws -> (JSONValue, [RoutedRef]) {
        let session = try await session(for: identity, headless: true)
        if let url = identity.url {
            _ = try await navigate(session: session, url: url)
        }
        let conn = try connection(for: session)
        _ = try await conn.send(method: "Accessibility.enable")
        let tree = try await conn.send(method: "Accessibility.getFullAXTree")
        let nodes = tree["nodes"]?.arrayValue ?? []
        let refs = CDPAccessibility.flatten(nodes: nodes, interactiveOnly: interactiveOnly, sessionKey: session.key)
        return (tree, refs)
    }

    func click(ref: RoutedRef) async throws {
        guard case .cdp(let key, let backendNodeId, _, _) = ref else {
            throw ToolError.actionFailed("Not a CDP element")
        }
        let conn = try connection(forKey: key)
        let resolved = try await conn.send(
            method: "DOM.resolveNode",
            params: .object(["backendNodeId": .int(backendNodeId)])
        )
        guard let objectId = resolved["object"]?["objectId"]?.stringValue else {
            throw ToolError.actionFailed("DOM.resolveNode did not return an objectId")
        }
        _ = try await conn.send(
            method: "Runtime.callFunctionOn",
            params: .object([
                "objectId": .string(objectId),
                "functionDeclaration": .string("function(){ this.click(); if (this.focus) this.focus(); }"),
                "returnByValue": .bool(true),
            ])
        )
    }

    func typeText(ref: RoutedRef, text: String) async throws {
        guard case .cdp(let key, let backendNodeId, _, _) = ref else {
            throw ToolError.actionFailed("Not a CDP element")
        }
        let conn = try connection(forKey: key)
        let resolved = try await conn.send(
            method: "DOM.resolveNode",
            params: .object(["backendNodeId": .int(backendNodeId)])
        )
        guard let objectId = resolved["object"]?["objectId"]?.stringValue else {
            throw ToolError.actionFailed("DOM.resolveNode did not return an objectId")
        }
        _ = try await conn.send(
            method: "Runtime.callFunctionOn",
            params: .object([
                "objectId": .string(objectId),
                "functionDeclaration": .string(
                    "function(t){ this.focus(); if ('value' in this){ this.value=t; this.dispatchEvent(new Event('input',{bubbles:true})); this.dispatchEvent(new Event('change',{bubbles:true})); } else if (this.isContentEditable){ this.textContent=t; } }"
                ),
                "arguments": .array([.object(["value": .string(text)])]),
                "returnByValue": .bool(true),
            ])
        )
    }

    func evaluate(identity: TargetIdentity, expression: String) async throws -> JSONValue {
        let session = try await session(for: identity, headless: true)
        let conn = try connection(for: session)
        return try await conn.send(
            method: "Runtime.evaluate",
            params: .object([
                "expression": .string(expression),
                "returnByValue": .bool(true),
                "awaitPromise": .bool(true),
            ])
        )
    }

    func screenshot(identity: TargetIdentity) async throws -> Data {
        let session = try await session(for: identity, headless: true)
        let conn = try connection(for: session)
        let result = try await conn.send(
            method: "Page.captureScreenshot",
            params: .object([
                "format": .string("jpeg"),
                "quality": .int(70),
            ])
        )
        guard let b64 = result["data"]?.stringValue, let data = Data(base64Encoded: b64) else {
            throw ToolError.actionFailed("Page.captureScreenshot returned no data")
        }
        return data
    }

    func readText(ref: RoutedRef) async throws -> String {
        guard case .cdp(let key, let backendNodeId, _, label) = ref else { return "" }
        let conn = try connection(forKey: key)
        let resolved = try await conn.send(
            method: "DOM.resolveNode",
            params: .object(["backendNodeId": .int(backendNodeId)])
        )
        guard let objectId = resolved["object"]?["objectId"]?.stringValue else { return label }
        let result = try await conn.send(
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

    func navigate(session: Session, url: URL) async throws -> JSONValue {
        let conn = try connection(for: session)
        _ = try await conn.send(method: "Page.enable")
        return try await conn.send(
            method: "Page.navigate",
            params: .object(["url": .string(url.absoluteString)])
        )
    }

    private func connect(identity: TargetIdentity, headless: Bool) async throws -> Session {
        let key = identity.url?.absoluteString ?? identity.raw
        if let port = ChromeLauncher.findExistingDebugPort(),
           let page = try? ChromeLauncher.pickPage(port: port, preferring: identity.url) {
            let conn = CDPConnection(url: page.webSocketDebuggerURL)
            try await conn.open()
            connections[key] = conn
            return Session(key: key, debuggerURL: page.webSocketDebuggerURL, browserURL: page.url, headless: false, attached: true)
        }
        guard ChromeLauncher.findBinary() != nil else {
            throw ToolError.actionFailed("No Chromium browser found. Install Chrome/Chromium/Edge, or launch Chrome with --remote-debugging-port=9222 to attach to a user session.")
        }
        let launched = try await ChromeLauncher.launchOwned(headless: headless)
        ownedChrome = (launched.process, launched.port)
        guard let page = try ChromeLauncher.pickPage(port: launched.port, preferring: identity.url) else {
            throw ToolError.actionFailed("Chrome launched but no DevTools page target was listed")
        }
        let conn = CDPConnection(url: page.webSocketDebuggerURL)
        try await conn.open()
        connections[key] = conn
        if let url = identity.url {
            _ = try await conn.send(method: "Page.enable")
            _ = try await conn.send(method: "Page.navigate", params: .object(["url": .string(url.absoluteString)]))
            try? await Task.sleep(for: .milliseconds(300))
        }
        return Session(key: key, debuggerURL: page.webSocketDebuggerURL, browserURL: page.url, headless: headless, attached: false)
    }

    private func connection(for session: Session) throws -> CDPConnection {
        try connection(forKey: session.key)
    }

    private func connection(forKey key: String) throws -> CDPConnection {
        guard let conn = connections[key] ?? connections.values.first else {
            throw ToolError.actionFailed("No CDP session. Call snapshot on a URL first.")
        }
        return conn
    }
}

enum CDPAccessibility {
    static let interactiveRoles: Set<String> = [
        "button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox",
        "slider", "tab", "menuitem", "switch", "option", "treeitem", "spinbutton",
        "listbox", "menuitemcheckbox", "menuitemradio", "textfield",
    ]

    static func flatten(nodes: [JSONValue], interactiveOnly: Bool, sessionKey: String = "page") -> [RoutedRef] {
        var refs: [RoutedRef] = []
        for node in nodes {
            if node["ignored"]?.boolValue == true { continue }
            let role = axAtom(node["role"]) ?? "generic"
            let name = axAtom(node["name"]) ?? ""
            if interactiveOnly && !interactiveRoles.contains(role.lowercased()) { continue }
            guard let backend = node["backendDOMNodeId"]?.intValue, backend > 0 else { continue }
            refs.append(.cdp(sessionKey: sessionKey, backendNodeId: backend, role: role, label: name))
        }
        return refs
    }

    static func compactElements(ids: [String], refs: [RoutedRef]) -> [JSONValue] {
        zip(ids, refs).map { id, ref in
            guard case .cdp(_, _, let role, let label) = ref else {
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

enum ChromeLauncher {
    struct PageTarget {
        var url: String
        var webSocketDebuggerURL: URL
    }

    static func findBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["AGENTCONTROLLER_CHROME"] {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/usr/bin/google-chrome",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func findExistingDebugPort() -> UInt16? {
        for port: UInt16 in [9222, 9229, 9333] {
            if let _ = try? listPages(port: port), SocketProbe.connect(port: port, timeoutMs: 80) {
                return port
            }
        }
        return nil
    }

    static func listPages(port: UInt16) throws -> [PageTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            throw ToolError.actionFailed("bad debug URL")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let items = json.arrayValue ?? []
        return items.compactMap { item in
            guard let ws = item["webSocketDebuggerUrl"]?.stringValue,
                  let wsURL = URL(string: ws) else { return nil }
            let type = item["type"]?.stringValue ?? "page"
            guard type == "page" || type == "webview" else { return nil }
            return PageTarget(url: item["url"]?.stringValue ?? "", webSocketDebuggerURL: wsURL)
        }
    }

    static func pickPage(port: UInt16, preferring url: URL?) throws -> PageTarget? {
        let pages = try listPages(port: port)
        if let url {
            let target = url.absoluteString
            if let match = pages.first(where: { $0.url.hasPrefix(target) || target.hasPrefix($0.url) }) {
                return match
            }
        }
        return pages.first
    }

    static func launchOwned(headless: Bool) async throws -> (process: Process, port: UInt16) {
        guard let binary = findBinary() else {
            throw ToolError.actionFailed("No Chromium browser found")
        }
        let port = try freePort()
        let profile = cacheDir().appendingPathComponent("cdp-profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-extensions",
            "about:blank",
        ]
        if headless {
            args.insert("--headless=new", at: 0)
        }
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if (try? listPages(port: port)) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return (process, port)
    }

    private static func cacheDir() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentController")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentController")
    }

    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError.actionFailed("socket") }
        defer { close(fd) }
        var soAddr = sockaddr_in()
        soAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        soAddr.sin_family = sa_family_t(AF_INET)
        soAddr.sin_port = 0
        let pton = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &soAddr.sin_addr) }
        guard pton == 1 else { throw ToolError.actionFailed("inet_pton") }
        let bindRC: Int32 = withUnsafePointer(to: &soAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else { throw ToolError.actionFailed("bind") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &soAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: soAddr.sin_port)
    }
}

actor CDPConnection {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var nextID = 1

    init(url: URL) {
        self.url = url
    }

    func open() async throws {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        _ = try await send(method: "Runtime.enable")
        _ = try await send(method: "Page.enable")
    }

    func send(method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard let task else { throw ToolError.actionFailed("CDP socket closed") }
        let id = nextID
        nextID += 1
        let envelope = JSONValue.object([
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ])
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.actionFailed("CDP encode failed")
        }
        try await task.send(.string(text))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            guard json["id"]?.intValue == id else { continue }
            if let error = json["error"] {
                let msg = error["message"]?.stringValue ?? "CDP error"
                throw ToolError.actionFailed(msg)
            }
            return json["result"] ?? .object([:])
        }
        throw ToolError.timedOut(method)
    }
}
