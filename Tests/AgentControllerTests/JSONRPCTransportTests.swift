import XCTest
@testable import MCPServer

/// The server half of the transport: what a JSON-RPC client sees when a request is malformed,
/// carries a non-finite number, or is abandoned half-way. Each test pins a failure that was
/// measured against the live app before it was fixed.
final class JSONRPCTransportTests: XCTestCase {

    private func respond(_ raw: String, provider: MCPToolProvider = FakeProvider(), client: String? = nil) async -> String {
        let data = await MCPProtocolHandler(toolProvider: provider).handleRequest(Data(raw.utf8), clientId: client)
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    // MARK: - Errors carry the request id

    /// Valid JSON that is not a request must come back as Invalid Request under the id the
    /// client sent: an id-less error cannot be matched to anything, so the call just times out.
    func testInvalidRequestEchoesTheRequestID() async {
        let numeric = Wire.decode(Data((await respond(#"{"jsonrpc":"2.0","id":7,"method":5}"#)).utf8))
        XCTAssertEqual(numeric["error"]?["code"]?.intValue, -32600)
        XCTAssertEqual(numeric["id"]?.intValue, 7)

        let textual = Wire.decode(Data((await respond(#"{"jsonrpc":"2.0","id":"abc","params":{}}"#)).utf8))
        XCTAssertEqual(textual["error"]?["code"]?.intValue, -32600)
        XCTAssertEqual(textual["id"]?.stringValue, "abc")
    }

    func testUnparseableInputIsAParseErrorWithExplicitNullID() async {
        let text = await respond("this is not json")
        XCTAssertTrue(text.contains(#""id":null"#), "an absent id must be written as null, got: \(text)")
        XCTAssertEqual(Wire.decode(Data(text.utf8))["error"]?["code"]?.intValue, -32700)
    }

    func testBatchArrayIsInvalidRequestNotParseError() async {
        let text = await respond(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual(Wire.decode(Data(text.utf8))["error"]?["code"]?.intValue, -32600)
        XCTAssertTrue(text.contains(#""id":null"#))
    }

    func testUnknownMethodEchoesID() async {
        let reply = Wire.decode(Data((await respond(#"{"jsonrpc":"2.0","id":42,"method":"nope"}"#)).utf8))
        XCTAssertEqual(reply["error"]?["code"]?.intValue, -32601)
        XCTAssertEqual(reply["id"]?.intValue, 42)
    }

    func testNilIDEncodesAsExplicitNull() throws {
        let data = try JSONEncoder().encode(JSONRPCResponse.failure(.parseError, id: nil))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""id":null"#))
    }

    // MARK: - Non-finite numbers

    func testNonFiniteDoublesEncodeAsNull() throws {
        let value: JSONValue = .object([
            "a": .double(.nan), "b": .double(.infinity), "c": .double(-.infinity),
            "d": .double(1.5), "nested": .array([.double(.nan), .int(2)]),
        ])
        let decoded = Wire.decode(try JSONEncoder().encode(value))
        XCTAssertEqual(decoded["a"], .null)
        XCTAssertEqual(decoded["b"], .null)
        XCTAssertEqual(decoded["c"], .null)
        XCTAssertEqual(decoded["d"]?.doubleValue, 1.5, "finite siblings must survive")
        XCTAssertEqual(decoded["nested"]?.arrayValue?.last?.intValue, 2)
    }

    /// Before the fix this returned an EMPTY body: JSONEncoder threw on the NaN, the handler
    /// swallowed it with `try?`, and the client waited for a reply that never came.
    func testToolResultWithNaNStillProducesAReplyUnderTheRequestID() async {
        let text = await respond(Wire.callString(9, "nan"))
        XCTAssertFalse(text.isEmpty, "a non-finite number must not turn the reply into an empty body")
        let reply = Wire.decode(Data(text.utf8))
        XCTAssertEqual(reply["id"]?.intValue, 9)
        XCTAssertEqual(reply["result"]?["ok"]?.intValue, 1)
        XCTAssertEqual(reply["result"]?["ratio"], .null)
    }

    // MARK: - Cancellation registry

    private func key(_ client: String, _ id: Int) -> InFlightRegistry.Key {
        .init(client: client, id: .int(id))
    }

    func testCancelAfterRegisterInvokesTheCancel() async {
        let registry = InFlightRegistry()
        let hits = Counter()
        let token = await registry.register(key("a", 1)) { hits.bump() }
        XCTAssertNotNil(token)
        await registry.cancel(key("a", 1))
        XCTAssertEqual(hits.value, 1)
    }

    /// The cancel notification can overtake the request it names. It must not be lost.
    func testCancelBeforeRegisterCancelsTheLateArrival() async {
        let registry = InFlightRegistry()
        let hits = Counter()
        await registry.cancel(key("a", 1))
        let token = await registry.register(key("a", 1)) { hits.bump() }
        XCTAssertNil(token, "a request whose cancel already arrived must not be admitted")
        XCTAssertEqual(hits.value, 1)
        let tombstones = await registry.tombstoneCount
        XCTAssertEqual(tombstones, 0, "the tombstone is consumed by the request it was for")
    }

    /// Every session numbers its ids from 0; a cancel for client A's id 1 must not touch B's.
    func testCancelIsIsolatedPerClient() async {
        let registry = InFlightRegistry()
        let a = Counter(), b = Counter()
        _ = await registry.register(key("A", 1)) { a.bump() }
        _ = await registry.register(key("B", 1)) { b.bump() }
        await registry.cancel(key("A", 1))
        XCTAssertEqual(a.value, 1)
        XCTAssertEqual(b.value, 0)
    }

    func testTombstoneDoesNotLeakAcrossClients() async {
        let registry = InFlightRegistry()
        let hits = Counter()
        await registry.cancel(key("A", 1))
        let token = await registry.register(key("B", 1)) { hits.bump() }
        XCTAssertNotNil(token)
        XCTAssertEqual(hits.value, 0)
    }

    func testExpiredTombstoneIsIgnored() async throws {
        let registry = InFlightRegistry(tombstoneTTL: 0.05)
        let hits = Counter()
        await registry.cancel(key("a", 1))
        try await Task.sleep(nanoseconds: 120_000_000)
        let token = await registry.register(key("a", 1)) { hits.bump() }
        XCTAssertNotNil(token, "a cancel older than the TTL belongs to a request that is never coming")
        XCTAssertEqual(hits.value, 0)
    }

    func testFinishWithStaleTokenKeepsTheNewerRegistration() async {
        let registry = InFlightRegistry()
        let old = await registry.register(key("a", 1)) {}
        let new = await registry.register(key("a", 1)) {}
        await registry.finish(key("a", 1), token: old!)
        var running = await registry.runningCount
        XCTAssertEqual(running, 1)
        await registry.finish(key("a", 1), token: new!)
        running = await registry.runningCount
        XCTAssertEqual(running, 0)
    }

    func testTombstonesAreBounded() async {
        let registry = InFlightRegistry()
        for i in 0..<1000 { await registry.cancel(key("a", i)) }
        let count = await registry.tombstoneCount
        XCTAssertLessThanOrEqual(count, 256)
    }

    // MARK: - Cancellation through the protocol handler

    func testCancelNotificationStopsTheRunningToolAndSuppressesItsReply() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        let call = Task { await handler.handleRequest(Wire.call(1, "slow", tag: "one"), clientId: "A") }
        let started = await eventually { provider.started.contains("one") }
        XCTAssertTrue(started)

        let ack = await handler.handleRequest(Wire.cancel(1), clientId: "A")
        XCTAssertNil(ack, "a notification gets no response")

        let reply = await call.value
        XCTAssertNil(reply, "a cancelled request gets no response")
        XCTAssertEqual(provider.cancelled, ["one"])
    }

    func testCancelFromAnotherClientDoesNotReachTheCall() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        let call = Task { await handler.handleRequest(Wire.call(1, "slow", tag: "mine"), clientId: "A") }
        _ = await eventually { provider.started.contains("mine") }

        _ = await handler.handleRequest(Wire.cancel(1), clientId: "B")
        _ = await handler.handleRequest(Wire.cancel(1), clientId: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(provider.cancelled.isEmpty, "another session's cancel must not stop this call")

        _ = await handler.handleRequest(Wire.cancel(1), clientId: "A")
        _ = await call.value
        XCTAssertEqual(provider.cancelled, ["mine"])
    }

    func testCancelArrivingBeforeTheRequestPreventsItRunningToCompletion() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        _ = await handler.handleRequest(Wire.cancel(5), clientId: "A")
        let reply = await handler.handleRequest(Wire.call(5, "slow", tag: "late"), clientId: "A")
        XCTAssertNil(reply)
        XCTAssertTrue(provider.finished.isEmpty)
    }

    /// The HTTP layer cancels the handler's task when the client hangs up; the tool must see it.
    func testCancellingTheCallingTaskCancelsTheTool() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        let call = Task { await handler.handleRequest(Wire.call(1, "slow", tag: "dropped"), clientId: "A") }
        _ = await eventually { provider.started.contains("dropped") }
        call.cancel()
        let reply = await call.value
        XCTAssertNil(reply)
        let seen = await eventually { provider.cancelled.contains("dropped") }
        XCTAssertTrue(seen)
    }

    func testCompletedCallIsUnregisteredSoALaterCancelLeavesOnlyATombstone() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        let reply = await handler.handleRequest(Wire.call(1, "echo", tag: "quick"), clientId: "A")
        XCTAssertNotNil(reply)
        let ack = await handler.handleRequest(Wire.cancel(1), clientId: "A")
        XCTAssertNil(ack)
    }

    // MARK: - HTTP layer

    private func startServer(
        readDeadline: TimeInterval = 10,
        handler: @escaping HTTPServer.Handler
    ) async throws -> (HTTPServer, UInt16) {
        let server = HTTPServer(readDeadline: readDeadline, handler: handler)
        let port = try await server.start()
        return (server, port)
    }

    private func post(_ server: HTTPServer, port: UInt16, body: String, extraHeaders: String = "") async -> String {
        let token = await server.authToken
        return "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(extraHeaders)\r\n"
    }

    /// curl sends `Expect: 100-continue` for bodies over 1 MiB and waits for the interim reply
    /// before sending any of the body: 1.004s of dead air against 6ms once it is answered.
    func testExpectContinueIsAnsweredBeforeTheBodyArrives() async throws {
        let (server, port) = try await startServer { body, _ in Data("{}".utf8) }
        defer { Task { await server.stop() } }

        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let socket = try RawSocket(port: port)
        defer { socket.close() }
        socket.send(await post(server, port: port, body: body, extraHeaders: "Expect: 100-continue\r\n"))

        let started = Date()
        let interim = socket.receive(until: "100 Continue", timeout: 0.9)
        XCTAssertTrue(interim.contains("HTTP/1.1 100 Continue"), "no interim response within 0.9s: \(interim)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)

        socket.send(body)
        let final = socket.receive(until: "200 OK", timeout: 2)
        XCTAssertTrue(final.contains("200 OK"), final)
    }

    func testOverLimitBodyIsRejectedWithoutContinue() async throws {
        let (server, port) = try await startServer { _, _ in Data("{}".utf8) }
        defer { Task { await server.stop() } }

        let socket = try RawSocket(port: port)
        defer { socket.close() }
        let token = await server.authToken
        socket.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Length: \(64 * 1024 * 1024)\r\nExpect: 100-continue\r\n\r\n")
        let reply = socket.receive(until: "413", timeout: 2)
        XCTAssertTrue(reply.contains("413"), reply)
        XCTAssertFalse(reply.contains("100 Continue"), "a body that will be refused must not be invited")
    }

    /// A request that never finishes arriving used to hold its connection forever: the deadline
    /// timer fired, but the group still waited on a receive nothing would ever complete.
    func testStalledRequestIsDroppedAtTheReadDeadline() async throws {
        let (server, port) = try await startServer(readDeadline: 0.5) { _, _ in Data("{}".utf8) }
        defer { Task { await server.stop() } }

        let socket = try RawSocket(port: port)
        defer { socket.close() }
        socket.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n")   // headers never finish

        let started = Date()
        let outcome = socket.receive(timeout: 3)
        XCTAssertNotNil(outcome, "the server held a stalled connection open past its deadline")
        XCTAssertEqual(outcome?.count, 0, "the server should close without answering")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testClientIDHeaderReachesTheHandler() async throws {
        let seen = Recorder<String?>()
        let (server, port) = try await startServer { _, clientId in
            seen.add(clientId)
            return Data("{}".utf8)
        }
        defer { Task { await server.stop() } }

        for header in ["X-AC-Client: session-1\r\n", ""] {
            let socket = try RawSocket(port: port)
            socket.send(await post(server, port: port, body: "{}", extraHeaders: header) + "{}")
            _ = socket.receive(until: "200 OK", timeout: 2)
            socket.close()
        }
        XCTAssertEqual(seen.values.count, 2)
        XCTAssertTrue(seen.values.contains { $0 == "session-1" })
        XCTAssertTrue(seen.values.contains { $0 == nil })
    }

    /// A caller that gives up (curl --max-time, a killed bridge) must stop the work it asked for.
    func testClientDisconnectCancelsTheHandlerTask() async throws {
        let started = Counter(), cancelled = Counter()
        let (server, port) = try await startServer { _, _ in
            started.bump()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled.bump() }
            return nil
        }
        defer { Task { await server.stop() } }

        let socket = try RawSocket(port: port)
        socket.send(await post(server, port: port, body: "{}") + "{}")
        let running = await eventually { started.value == 1 }
        XCTAssertTrue(running)

        socket.close()
        let stopped = await eventually(timeout: 3) { cancelled.value == 1 }
        XCTAssertTrue(stopped, "the handler kept running for a client that is gone")
    }

    /// NWListener reports `.failed` after startup when its socket is torn down; the server used
    /// to ignore it and kept claiming a port nothing listened on. The failure itself cannot be
    /// provoked from a test, so this hands the server its own live listener as the one that died.
    /// While a dead listener's port is free, a bridge with the port cached can hand its
    /// bearer token to whatever grabbed it. The rebuilt listener must not accept that token.
    func testListenerRebuildRotatesTheTokenAndRejectsTheOldOne() async throws {
        let (server, _) = try await startServer { _, _ in Data("{}".utf8) }
        defer { Task { await server.stop() } }
        let oldToken = await server.authToken
        let announced = Recorder<String>()
        await server.setPortChangeHandler { _, token in announced.add(token) }

        let live = await server.listener
        let dead = try XCTUnwrap(live)
        await server.listenerFailed(dead)

        let newToken = await server.authToken
        XCTAssertNotEqual(newToken, oldToken)
        XCTAssertEqual(announced.values.last, newToken, "the token-file owner was not given the rotated token")

        let port = await server.assignedPort
        let body = "{}"
        let stale = try RawSocket(port: port)
        defer { stale.close() }
        stale.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(oldToken)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        XCTAssertTrue(stale.receive(until: "401", timeout: 3).contains("401"), "a pre-restart token still authenticated")

        let fresh = try RawSocket(port: port)
        defer { fresh.close() }
        fresh.send(await post(server, port: port, body: body) + body)
        XCTAssertTrue(fresh.receive(until: "200 OK", timeout: 3).contains("200 OK"))
    }

    func testListenerThatDiesIsRebuiltAndTheNewPortIsAnnounced() async throws {
        let (server, _) = try await startServer { _, _ in Data("{}".utf8) }
        defer { Task { await server.stop() } }
        let announced = Recorder<UInt16>()
        await server.setPortChangeHandler { port, _ in announced.add(port) }

        let live = await server.listener
        let dead = try XCTUnwrap(live)
        await server.listenerFailed(dead)

        let rebuilt = try XCTUnwrap(announced.values.last, "the port-file owner was never told the listener was rebuilt")
        XCTAssertEqual(announced.values.count, 1)
        let current = await server.assignedPort
        XCTAssertEqual(rebuilt, current)
        // The old port is preferred but not guaranteed (here the "dead" listener is still bound
        // while we ask), which is why the port is announced rather than assumed to be unchanged.

        let socket = try RawSocket(port: rebuilt)
        defer { socket.close() }
        socket.send(await post(server, port: rebuilt, body: "{}") + "{}")
        XCTAssertTrue(socket.receive(until: "200 OK", timeout: 3).contains("200 OK"))
    }

    func testRequestWithoutTokenIsStillRejected() async throws {
        let (server, port) = try await startServer { _, _ in Data("{}".utf8) }
        defer { Task { await server.stop() } }

        let socket = try RawSocket(port: port)
        defer { socket.close() }
        socket.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 2\r\n\r\n{}")
        XCTAssertTrue(socket.receive(until: "401", timeout: 2).contains("401"))
    }
}

extension Wire {
    /// `call` as a String, for tests that go through the string-based `respond` helper.
    static func callString(_ id: Int, _ tool: String) -> String {
        String(decoding: call(id, tool), as: UTF8.self)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
