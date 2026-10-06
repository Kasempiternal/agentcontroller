import XCTest
import MCPServer
@testable import CLICore

/// The pure parts of `agentcontroller mcp` (line framing, id recovery, the in-flight cap, the
/// endpoint cache) and the relay itself wired to a real `HTTPServer` over loopback.
final class MCPBridgeTests: XCTestCase {

    // MARK: - Line framing

    func testFramerSplitsOnNewlinesAndKeepsTheTail() {
        var framer = LineFramer()
        XCTAssertEqual(framer.push(Data("{\"a\":1}\n{\"b\"".utf8)).map(text), ["{\"a\":1}"])
        XCTAssertEqual(framer.push(Data(":2}\n".utf8)).map(text), ["{\"b\":2}"])
        XCTAssertNil(framer.finish())
    }

    func testFramerHandlesALineSplitAcrossManyChunks() {
        var framer = LineFramer()
        let line = String(repeating: "x", count: 300_000)
        var lines: [String] = []
        let data = Data((line + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 65_536, data.count)
            lines += framer.push(data[offset..<end]).map(text)
            offset = end
        }
        XCTAssertEqual(lines, [line])
    }

    func testFramerDropsBlankLinesAndStripsCR() {
        var framer = LineFramer()
        XCTAssertEqual(framer.push(Data("\n  \r\n{\"a\":1}\r\n\n".utf8)).map(text), ["{\"a\":1}"])
    }

    func testFramerDeliversAnUnterminatedFinalLine() {
        var framer = LineFramer()
        XCTAssertEqual(framer.push(Data("{\"a\":1}\n{\"last\":true}".utf8)).map(text), ["{\"a\":1}"])
        XCTAssertEqual(framer.finish().map(text), "{\"last\":true}")
    }

    func testFramerKeepsMultibyteCharactersIntactAcrossChunks() {
        var framer = LineFramer()
        let bytes = Array("{\"t\":\"héllo 🚀\"}\n".utf8)
        let cut = bytes.firstIndex(of: 0xC3)! + 1   // between the two bytes of "é"
        XCTAssertEqual(framer.push(Data(bytes[..<cut])).count, 0)
        XCTAssertEqual(framer.push(Data(bytes[cut...])).map(text), ["{\"t\":\"héllo 🚀\"}"])
    }

    // MARK: - Id recovery

    func testEnvelopeRecoversIntegerAndStringIDs() {
        XCTAssertEqual(MCPLine.envelope(of: Data(#"{"jsonrpc":"2.0","id":12,"method":"tools/call"}"#.utf8)),
                       .init(id: "12", method: "tools/call"))
        XCTAssertEqual(MCPLine.envelope(of: Data(#"{"id":"a\"b","method":"ping"}"#.utf8)).id, #""a\"b""#)
    }

    func testNotificationHasNoID() {
        XCTAssertNil(MCPLine.envelope(of: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)).id)
        XCTAssertNil(MCPLine.envelope(of: Data(#"{"id":null,"method":"x"}"#.utf8)).id)
    }

    /// A nested "id" (an element id inside the arguments) must not be mistaken for the request's.
    func testEnvelopeIgnoresNestedIDs() {
        let line = #"{"params":{"arguments":{"id":"e9"}},"id":3,"method":"tools/call"}"#
        XCTAssertEqual(MCPLine.envelope(of: Data(line.utf8)).id, "3")
    }

    func testBooleanIDIsNotAnID() {
        XCTAssertNil(MCPLine.envelope(of: Data(#"{"id":true,"method":"x"}"#.utf8)).id)
    }

    func testEnvelopeScrapesTheIDFromATruncatedLine() {
        XCTAssertEqual(MCPLine.envelope(of: Data(#"{"jsonrpc":"2.0","id":8,"method":"tools/ca"#.utf8)).id, "8")
        XCTAssertNil(MCPLine.envelope(of: Data("garbage".utf8)).id)
    }

    func testErrorLineIsValidJSONRPCUnderTheGivenID() throws {
        let line = MCPLine.errorLine(id: #""a\"b""#, code: -32000, message: "no \"server\"\nhere")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(parsed["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(parsed["id"] as? String, #"a"b"#)
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(error["message"] as? String, "no \"server\"\nhere")
        XCTAssertFalse(line.contains(0x0A), "an error reply is one line")
    }

    func testToolCallDetection() {
        XCTAssertTrue(MCPLine.mayBeToolCall(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#.utf8)))
        XCTAssertFalse(MCPLine.mayBeToolCall(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)))
        XCTAssertFalse(MCPLine.mayBeToolCall(Data(#"{"method":"notifications/cancelled","params":{"requestId":1}}"#.utf8)))
    }

    func testSingleLineReplacesRawLineBreaksOnly() {
        XCTAssertEqual(MCPLine.singleLine(Data("{\"a\":\r\n1}".utf8)), Data("{\"a\":  1}".utf8))
        let clean = Data(#"{"a":"x\ny"}"#.utf8)   // escaped newline inside a string is untouched
        XCTAssertEqual(MCPLine.singleLine(clean), clean)
    }

    // MARK: - In-flight cap

    func testDispatcherAdmitsUpToTheLimitAndQueuesTheRestInOrder() {
        let dispatcher = BoundedDispatcher(limit: 2)
        let order = Recorder<Int>()
        var dones: [Int: () -> Void] = [:]
        for i in 1...4 {
            dispatcher.submit(gated: true) { done in
                order.add(i)
                dones[i] = done
            }
        }
        XCTAssertEqual(order.values, [1, 2])
        XCTAssertEqual(dispatcher.inFlight, 2)
        XCTAssertEqual(dispatcher.queued, 2)

        dones[2]!()
        XCTAssertEqual(order.values, [1, 2, 3], "the oldest waiter takes the freed slot")
        dones[1]!()
        XCTAssertEqual(order.values, [1, 2, 3, 4])
        XCTAssertEqual(dispatcher.queued, 0)
    }

    /// A saturated cap must not delay a ping or a cancel: only `tools/call` is gated.
    func testUngatedWorkBypassesAFullCap() {
        let dispatcher = BoundedDispatcher(limit: 1)
        dispatcher.submit(gated: true) { _ in }
        let ran = Counter()
        dispatcher.submit(gated: false) { _ in ran.bump() }
        XCTAssertEqual(ran.value, 1)
        XCTAssertEqual(dispatcher.inFlight, 1)
    }

    func testCallingDoneTwiceFreesOnlyOneSlot() {
        let dispatcher = BoundedDispatcher(limit: 1)
        var first: (() -> Void)?
        dispatcher.submit(gated: true) { first = $0 }
        let started = Counter()
        dispatcher.submit(gated: true) { _ in started.bump() }
        first!()
        first!()
        XCTAssertEqual(started.value, 1)
        XCTAssertEqual(dispatcher.inFlight, 1)
    }

    // MARK: - Endpoint cache

    private func tempFiles(port: String?, token: String?) throws -> (String, String, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ac-ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let portFile = dir.appendingPathComponent("port").path
        let tokenFile = dir.appendingPathComponent("token").path
        if let port { try port.write(toFile: portFile, atomically: true, encoding: .utf8) }
        if let token { try token.write(toFile: tokenFile, atomically: true, encoding: .utf8) }
        return (portFile, tokenFile, { try? FileManager.default.removeItem(at: dir) })
    }

    func testResolveCachesUntilToldOtherwise() throws {
        let reads = Counter()
        let cache = EndpointCache(startupWait: 0) { reads.bump(); return Endpoint(port: "1", token: "t") }
        _ = try cache.resolve()
        _ = try cache.resolve()
        XCTAssertEqual(reads.value, 1, "the files are read once, not per request")
    }

    func testResolveWaitsForTheFilesToAppear() throws {
        let (portFile, tokenFile, cleanup) = try tempFiles(port: nil, token: nil)
        defer { cleanup() }
        let cache = EndpointCache(startupWait: 5, pollInterval: 0.02) {
            try Endpoint.discover(portFile: portFile, tokenFile: tokenFile)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try? "4242".write(toFile: portFile, atomically: true, encoding: .utf8)
            try? "secret\n".write(toFile: tokenFile, atomically: true, encoding: .utf8)
        }
        let started = Date()
        let endpoint = try cache.resolve()
        XCTAssertEqual(endpoint, Endpoint(port: "4242", token: "secret"))
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.15)
    }

    func testResolveGivesUpOnceTheStartupWindowCloses() {
        let cache = EndpointCache(startupWait: 0.1, pollInterval: 0.02) { throw Endpoint.Failure.notRunning }
        XCTAssertThrowsError(try cache.resolve())
    }

    func testRefreshReturnsChangedEndpointAndNilForAnUnchangedOne() throws {
        let box = Recorder<Endpoint>()
        let old = Endpoint(port: "1", token: "old")
        let cache = EndpointCache(startupWait: 0) { box.values.last ?? old }
        box.add(old)
        XCTAssertEqual(try cache.resolve(), old)

        XCTAssertNil(cache.refresh(replacing: old), "same files, same failure: nothing to retry with")

        let new = Endpoint(port: "2", token: "new")
        box.add(new)
        XCTAssertEqual(cache.refresh(replacing: old), new)
        XCTAssertEqual(try cache.resolve(), new, "the refreshed endpoint is now the cached one")
    }

    // MARK: - The relay against a real server

    private final class Collector: LineOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [Data] = []
        func writeLine(_ body: Data) { lock.lock(); _lines.append(body); lock.unlock() }
        func flush() {}
        var lines: [Data] { lock.lock(); defer { lock.unlock() }; return _lines }
        func ids() -> [JSONValue] { lines.map { Wire.decode($0)["id"] ?? .null } }
    }

    private struct Rig {
        let server: HTTPServer
        let port: UInt16
        let token: String
        let provider: FakeProvider
        let clientsSeen: Recorder<String?>
    }

    private func makeRig() async throws -> Rig {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        let clients = Recorder<String?>()
        let server = HTTPServer { body, clientId in
            clients.add(clientId)
            return await handler.handleRequest(body, clientId: clientId)
        }
        let port = try await server.start()
        return Rig(server: server, port: port, token: await server.authToken, provider: provider, clientsSeen: clients)
    }

    private func bridge(_ rig: Rig, output: LineOutput, token: String? = nil, port: UInt16? = nil) -> MCPBridge {
        let endpoint = Endpoint(port: String(port ?? rig.port), token: token ?? rig.token)
        return MCPBridge(cache: EndpointCache(startupWait: 0) { endpoint }, output: output)
    }

    func testRelayAnswersRequestsAndStaysSilentForNotifications() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }
        let out = Collector()
        let relay = bridge(rig, output: out)

        relay.accept(Wire.request(1, "ping"))
        relay.accept(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        relay.accept(Wire.call(2, "echo", tag: "hello"))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 5))

        XCTAssertEqual(Set(out.ids()), [.int(1), .int(2)], "one reply per request, none for the notification")
        let echo = out.lines.map(Wire.decode).first { $0["id"] == .int(2) }
        XCTAssertEqual(echo?["result"]?["tag"]?.stringValue, "hello")
        XCTAssertEqual(rig.clientsSeen.values.compactMap { $0 }.count, 3, "every request carries X-AC-Client")
        XCTAssertEqual(Set(rig.clientsSeen.values.compactMap { $0 }).count, 1, "one bridge is one client")
    }

    /// The head-of-line blocking the bash bridge's serial loop had: a slow call must not stop a
    /// ping from being relayed and answered.
    func testSlowCallDoesNotBlockLaterRequests() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }
        let out = Collector()
        let relay = bridge(rig, output: out)

        relay.accept(Wire.call(1, "slow", tag: "slow"))
        let started = await eventually { rig.provider.started.contains("slow") }
        XCTAssertTrue(started)
        relay.accept(Wire.request(2, "ping"))

        let answered = await eventually { out.ids().contains(.int(2)) }
        XCTAssertTrue(answered, "ping was stuck behind the slow call")
        XCTAssertFalse(out.ids().contains(.int(1)))

        relay.accept(Wire.cancel(1))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 5))
    }

    /// Cancel travels bridge to server on its own connection while the call holds another, and
    /// the tool must actually stop — the whole point of the cancellation work.
    func testCancelNotificationStopsTheToolOverTheWire() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }
        let out = Collector()
        let relay = bridge(rig, output: out)

        relay.accept(Wire.call(1, "slow", tag: "victim"))
        _ = await eventually { rig.provider.started.contains("victim") }
        relay.accept(Wire.cancel(1))

        XCTAssertTrue(relay.waitUntilIdle(timeout: 5), "the cancelled call never completed")
        XCTAssertEqual(rig.provider.cancelled, ["victim"])
        XCTAssertTrue(out.lines.isEmpty, "a cancelled request is not answered")
    }

    /// Two bridges, both numbering from 1: cancelling one's call must leave the other running.
    func testCancelDoesNotCrossBridges() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }
        let outA = Collector(), outB = Collector()
        let a = bridge(rig, output: outA), b = bridge(rig, output: outB)

        a.accept(Wire.call(1, "slow", tag: "A"))
        b.accept(Wire.call(1, "slow", tag: "B"))
        let both = await eventually { Set(rig.provider.started) == ["A", "B"] }
        XCTAssertTrue(both)

        a.accept(Wire.cancel(1))
        XCTAssertTrue(a.waitUntilIdle(timeout: 5))
        XCTAssertEqual(rig.provider.cancelled, ["A"])

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(rig.provider.cancelled, ["A"], "B's call was cancelled by A's notification")

        b.accept(Wire.cancel(1))
        XCTAssertTrue(b.waitUntilIdle(timeout: 5))
        XCTAssertEqual(Set(rig.provider.cancelled), ["A", "B"])
    }

    func testStaleTokenIsRefreshedAndRetried() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }
        let out = Collector()
        let stale = Endpoint(port: String(rig.port), token: "stale")
        let fresh = Endpoint(port: String(rig.port), token: rig.token)
        let reads = Counter()
        let cache = EndpointCache(startupWait: 0) {
            reads.bump()
            return reads.value == 1 ? stale : fresh
        }
        let relay = MCPBridge(cache: cache, output: out)

        relay.accept(Wire.request(1, "ping"))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 5))
        XCTAssertEqual(out.ids(), [.int(1)])
        XCTAssertNotNil(Wire.decode(out.lines[0])["result"])
    }

    func testRefusedConnectionReReadsThePortAndRetries() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }
        let out = Collector()
        let dead = Endpoint(port: "1", token: rig.token)   // nothing listens on port 1
        let live = Endpoint(port: String(rig.port), token: rig.token)
        let reads = Counter()
        let cache = EndpointCache(startupWait: 0) {
            reads.bump()
            return reads.value == 1 ? dead : live
        }
        let relay = MCPBridge(cache: cache, output: out)

        relay.accept(Wire.request(7, "ping"))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 10))
        XCTAssertEqual(out.ids(), [.int(7)])
    }

    /// With the app gone for good, the client must be told under its own id, and a
    /// notification must stay silent.
    func testUnreachableServerAnswersRequestsWithAnErrorUnderTheirID() async throws {
        let out = Collector()
        let dead = Endpoint(port: "1", token: "t")
        let relay = MCPBridge(cache: EndpointCache(startupWait: 0) { dead }, output: out)

        relay.accept(Data(#"{"jsonrpc":"2.0","id":"req-9","method":"tools/call","params":{}}"#.utf8))
        relay.accept(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 10))

        XCTAssertEqual(out.lines.count, 1)
        let reply = Wire.decode(out.lines[0])
        XCTAssertEqual(reply["id"]?.stringValue, "req-9")
        XCTAssertEqual(reply["error"]?["code"]?.intValue, -32000)
    }

    func testMissingEndpointFilesAnswerWithAnErrorRatherThanHanging() async throws {
        let out = Collector()
        let relay = MCPBridge(
            cache: EndpointCache(startupWait: 0.05, pollInterval: 0.01) { throw Endpoint.Failure.notRunning },
            output: out)
        relay.accept(Wire.request(3, "ping"))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 5))
        XCTAssertEqual(out.ids(), [.int(3)])
        XCTAssertTrue(Wire.decode(out.lines[0])["error"]?["message"]?.stringValue?.contains("not running") == true)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}
