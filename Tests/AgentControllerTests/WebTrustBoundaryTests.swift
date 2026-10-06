import XCTest
import MCPServer
#if canImport(Darwin)
import Darwin
#endif
@testable import MCPTools

/// What a debug port, a web page and an agent's arguments must not be able to make the
/// server do: send a session's traffic anywhere but the loopback port that was probed,
/// pass a process that is not the user's off as their Chrome, act on a node of a page the
/// element id was not read from, or crash the process (and every session with it) with a
/// number.
final class WebTrustBoundaryTests: XCTestCase {
    private var chrome: FakeChrome!
    private var saved: [String: String?] = [:]

    override func setUp() async throws {
        chrome = try FakeChrome()
        try chrome.start()
        for (key, value) in [
            ChromeLauncher.debugPortsEnv: "\(chrome.port)",
            // No private headless fallback: every call here reaches the fake or fails.
            "AGENTCONTROLLER_CHROME": "/nonexistent/agentcontroller-test-chrome",
        ] {
            saved[key] = .some(ProcessInfo.processInfo.environment[key])
            setenv(key, value, 1)
        }
        await ProbeCache.shared.reset()
    }

    override func tearDown() async throws {
        await WebCDPBackend.shared.shutdown()
        await ProbeCache.shared.reset()
        chrome.stop()
        for (key, old) in saved {
            if let old { setenv(key, old, 1) } else { unsetenv(key) }
        }
        saved.removeAll()
    }

    // MARK: - Fixtures

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String
        init(_ value: String) { stored = value }
        var value: String { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    }

    /// One tab on `url` whose main-frame document is whatever `document` holds when asked,
    /// with one password field (backendNodeId 3) — or no elements at all.
    private func servePage(_ url: String, document: Box, withPasswordField: Bool = true) {
        chrome.serve("/json/list", "[\(chrome.pageEntry(id: "t1", url: url))]")
        chrome.respond { method, _ in
            switch method {
            case "Page.getFrameTree":
                return .object(["frameTree": .object(["frame": .object([
                    "id": .string("F"), "loaderId": .string(document.value), "url": .string(url),
                ])])])
            case "Runtime.evaluate":
                return .object(["result": .object(["type": .string("string"), "value": .string(url)])])
            case "Accessibility.getFullAXTree":
                guard withPasswordField else { return .object(["nodes": .array([])]) }
                return .object(["nodes": .array([.object([
                    "nodeId": .string("1"), "ignored": .bool(false),
                    "role": .object(["value": .string("textbox")]),
                    "name": .object(["value": .string("Password")]),
                    "backendDOMNodeId": .int(3),
                ])])])
            case "DOM.resolveNode":
                return .object(["object": .object(["objectId": .string("node-3")])])
            case "DOM.getContentQuads":
                return .object(["quads": .array([.array([10, 10, 110, 10, 110, 40, 10, 40].map { .double($0) })])])
            case "Page.getLayoutMetrics":
                return .object(["cssLayoutViewport": .object(["clientWidth": .int(800), "clientHeight": .int(600)])])
            default:
                return .object([:])
            }
        }
    }

    private func assertStale(_ body: () async throws -> Void, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected a stale-id error", line: line)
        } catch {
            XCTAssertEqual(error as? CDPError, .stale, "\(error)", line: line)
        }
    }

    // MARK: - The socket a debug port advertises

    func testOnlyASocketOnTheProbedLoopbackPortIsAccepted() {
        let port: UInt16 = 9222
        XCTAssertEqual(ChromeLauncher.debuggerSocketURL("ws://127.0.0.1:9222/devtools/page/AB12", port: port)?.absoluteString,
                       "ws://127.0.0.1:9222/devtools/page/AB12")
        XCTAssertEqual(ChromeLauncher.debuggerSocketURL("ws://localhost:9222/devtools/page/AB12", port: port)?.absoluteString,
                       "ws://127.0.0.1:9222/devtools/page/AB12", "localhost may resolve to ::1, where someone else can listen")
        for advertised in [
            "ws://attacker.example:9222/devtools/page/AB12",
            "ws://203.0.113.7:9222/devtools/page/AB12",
            "ws://127.0.0.1:9223/devtools/page/AB12",
            "ws://127.0.0.1/devtools/page/AB12",
            "ws://127.0.0.1:9222@attacker.example/devtools/page/AB12",
            "ws://user@127.0.0.1:9222/devtools/page/AB12",
            "wss://127.0.0.1:9222/devtools/page/AB12",
            "http://127.0.0.1:9222/devtools/page/AB12",
            "ws://[::1]:9222/devtools/page/AB12",
            "not a url",
        ] {
            XCTAssertNil(ChromeLauncher.debuggerSocketURL(advertised, port: port), advertised)
        }
    }

    func testASessionNeverOpensASocketTheDebugPortPointsElsewhere() async throws {
        let elsewhere = try LoopbackWebSocketServer()
        let heard = Box("")
        elsewhere.handler = { text, reply in
            heard.set(heard.value + text)
            if let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?["id"]?.intValue {
                reply(#"{"id":\#(id),"result":{}}"#)
            }
        }
        try elsewhere.start()
        defer { elsewhere.stop() }
        chrome.serve("/json/list", #"[{"id":"t1","type":"page","url":"https://example.test/","webSocketDebuggerUrl":"ws://127.0.0.1:\#(elsewhere.port)/devtools/page/t1"}]"#)
        chrome.serve("/json/version", #"{"Browser":"Chrome/154.0.0.0","webSocketDebuggerUrl":"ws://127.0.0.1:\#(elsewhere.port)/devtools/browser/b"}"#)

        do {
            _ = try await WebCDPBackend.shared.snapshot(identity: TargetIdentity(raw: "https://example.test/"), interactiveOnly: true)
            XCTFail("a debug port whose sockets are all elsewhere offers nothing to attach to")
        } catch {}
        XCTAssertEqual(heard.value, "", "the session's commands went to the socket the debug port named")
    }

    // MARK: - Whose debug port it is

    func testOnlyAListenerOfThisUserOn127001PassesForTheUsersChrome() throws {
        XCTAssertTrue(ChromeLauncher.listenerBelongsToCurrentUser(port: chrome.port))

        // Ours, but on ::1 only: a connection to 127.0.0.1 on that port reaches someone else.
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var only6: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only6, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && Darwin.listen(fd, 1) == 0 && Darwin.getsockname(fd, $0, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let v6Port = UInt16(bigEndian: address.sin6_port)
        XCTAssertFalse(ChromeLauncher.listenerBelongsToCurrentUser(port: v6Port))

        Darwin.close(fd)
        XCTAssertFalse(ChromeLauncher.listenerBelongsToCurrentUser(port: v6Port), "nothing listens there at all")
    }

    // MARK: - Element ids belong to one document

    func testAnElementIdFromAPageTheTabHasLeftActsOnNothing() async throws {
        let document = Box("loader-bank")
        let url = "https://bank.test/login"
        servePage(url, document: document)
        let page = try await WebCDPBackend.shared.snapshot(identity: TargetIdentity(raw: url), interactiveOnly: true)
        let password = try XCTUnwrap(page.refs.first)

        // Control: on the page it was read from, the id types.
        try await WebCDPBackend.shared.typeText(ref: password, text: "hunter2")
        XCTAssertTrue(chrome.methods.contains("Input.insertText"), "\(chrome.methods)")

        // The tab goes to another site. Chrome numbers nodes per renderer process, so the
        // old backendNodeId now resolves to whatever node has that number over there.
        document.set("loader-elsewhere")
        chrome.forgetMethods()
        await assertStale { try await WebCDPBackend.shared.typeText(ref: password, text: "hunter2") }
        await assertStale { try await WebCDPBackend.shared.click(ref: password) }
        await assertStale { _ = try await WebCDPBackend.shared.readText(ref: password) }
        let acted = chrome.methods.filter { $0.hasPrefix("Input.") || $0 == "Runtime.callFunctionOn" }
        XCTAssertEqual(acted, [], "an id read from one page was acted on in another")
    }

    // MARK: - Numbers that used to crash the server

    func testANumberNoIntCanHoldIsNotAnInt() {
        XCTAssertNil(JSONValue.double(1e300).intValue)
        XCTAssertNil(JSONValue.double(-.infinity).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
        XCTAssertNil(JSONValue.double(9.3e18).intValue)
        XCTAssertEqual(JSONValue.double(3.9).intValue, 3)
        XCTAssertEqual(JSONValue.double(-3.9).intValue, -3)
        XCTAssertEqual(JSONValue.int(.max).intValue, .max)
        // A frame from a debug-port peer is parsed straight off the socket.
        XCTAssertEqual(CDPFrame.parse(Data(#"{"id":1e300,"result":{}}"#.utf8)), .other)
    }

    func testAbsurdNumbersFromTheAgentGetAnAnswerNotACrash() async throws {
        let url = "https://example.test/"
        servePage(url, document: Box("loader-1"), withPasswordField: false)
        for extra: [String: JSONValue] in [
            ["maxResults": .int(-1)],
            ["maxResults": .double(1e300)],
            ["index": .double(1e300)],
        ] {
            var arguments: [String: JSONValue] = ["url": .string(url), "role": .string("button")]
            arguments.merge(extra) { $1 }
            let result = await BackendRouter.dispatch(name: "find_elements", arguments: .object(arguments))
            XCTAssertNotNil(result, "\(extra)")
            XCTAssertNotEqual(result?["isError"]?.boolValue, true, "\(extra): \(String(describing: result))")
        }

        // Converting a 1e300s poll interval to a Duration trapped right after the first pass.
        chrome.forgetMethods()
        let waiting = Task {
            await BackendRouter.dispatch(name: "wait_for_element", arguments: .object([
                "url": .string(url), "labelContains": .string("never there"),
                "timeout": .double(1e300), "pollInterval": .double(1e300),
            ]))
        }
        let polled = await eventually { self.chrome.methods.contains("Accessibility.getFullAXTree") }
        XCTAssertTrue(polled, "the wait never made its first pass")
        try await Task.sleep(nanoseconds: 300_000_000)
        waiting.cancel()
        let result = await waiting.value
        XCTAssertNotNil(result, "a cancelled wait still answers")
    }
}
