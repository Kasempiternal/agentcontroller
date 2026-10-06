import XCTest
@testable import MCPTools
import MCPServer
#if canImport(Darwin)
import Darwin
#endif

/// Transport-level behaviour of the web/Blender/iOS backends, against real sockets and
/// real subprocesses. Each test pins one failure that was measured on the old code.
final class BackendTransportTests: XCTestCase {
    // MARK: - Socket timeout (H2)

    /// Packing 1000ms+ into tv_usec is rejected by the kernel with EDOM and the old code
    /// never checked, so recv had no timeout at all.
    func testSocketTimeoutKeepsMicrosecondsBelowOneSecond() {
        let tv = SocketProbe.socketTimeout(ms: 1_500)
        XCTAssertEqual(tv.tv_sec, 1)
        XCTAssertEqual(tv.tv_usec, 500_000)
        XCTAssertEqual(SocketProbe.socketTimeout(ms: 250).tv_sec, 0)
        XCTAssertEqual(SocketProbe.socketTimeout(ms: 250).tv_usec, 250_000)
        XCTAssertEqual(SocketProbe.socketTimeout(ms: 8_000).tv_sec, 8)
        XCTAssertEqual(SocketProbe.socketTimeout(ms: 8_000).tv_usec, 0)
        // A zero timeout means "block forever" to the kernel.
        XCTAssertGreaterThan(SocketProbe.socketTimeout(ms: 0).tv_usec, 0)
    }

    func testKernelAcceptsNewTimevalAndRejectsOldOne() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var good = SocketProbe.socketTimeout(ms: 1_500)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &good, socklen_t(MemoryLayout<timeval>.size)), 0)
        var old = timeval(tv_sec: 0, tv_usec: 1_500 * 1000)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &old, socklen_t(MemoryLayout<timeval>.size)), -1)
        XCTAssertEqual(errno, EDOM)
    }

    func testRoundTripToSilentServerTimesOutInsteadOfHanging() async throws {
        let server = try SilentTCPServer()
        try server.start()
        defer { server.stop() }
        let started = Date()
        do {
            _ = try await SocketProbe.roundTripAsync(port: server.port, payload: Data("ping\0".utf8), timeoutMs: 1_200, readUntilNull: true)
            XCTFail("a silent server must not produce a reply")
        } catch SocketProbe.ProbeError.timeout {
            // expected
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 1.0)
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testBareConnectProbeReturnsWithoutWaitingOutTheTimeout() throws {
        let server = try SilentTCPServer()
        try server.start()
        defer { server.stop() }
        let started = Date()
        XCTAssertTrue(SocketProbe.connect(port: server.port, timeoutMs: 2_000))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    // MARK: - Blender handshake (H2)

    /// The handshake used to run on an actor around blocking sockets, so N hung ports cost
    /// N timeouts back to back. Off the actor they overlap.
    func testHandshakeOverHungPortsOverlapsInsteadOfQueueing() async throws {
        let hung = try (0..<6).map { _ in try SilentTCPServer() }
        try hung.forEach { try $0.start() }
        defer { hung.forEach { $0.stop() } }
        let started = Date()
        let found = await BlenderBackend.handshake(ports: hung.map(\.port))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(found.isEmpty)
        // Each port costs ~0.5s (250ms Lab + 250ms WebSocket); serialised that is 3s+.
        XCTAssertLessThan(elapsed, 2.0, "hung ports are being probed one after another")
    }

    func testHandshakeFindsCommunityWebSocketServer() async throws {
        let server = try LoopbackWebSocketServer()
        server.handler = { _, reply in reply(#"{"status":"success","result":{"objects":3}}"#) }
        try server.start()
        defer { server.stop() }
        let found = await BlenderBackend.handshake(ports: [server.port])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, .blenderWS)
        XCTAssertEqual(found.first?.port, server.port)

        let reply = try await BlenderBackend.execute(endpoint: found[0], code: "result=1")
        XCTAssertEqual(reply["result"]?["objects"]?.intValue, 3)
    }

    /// Measured on the old code: a 250ms timeout returned after 6.02s because the pending
    /// receive() could not be interrupted.
    func testWebSocketRoundTripTimeoutActuallyFires() async throws {
        let server = try LoopbackWebSocketServer()
        server.handler = { _, _ in } // never answers
        try server.start()
        defer { server.stop() }
        let started = Date()
        do {
            _ = try await WebSocketIO.roundTrip(url: server.url, text: "{}", timeoutMs: 250)
            XCTFail("expected a timeout")
        } catch let error as ToolError {
            guard case .timedOut = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    // MARK: - Subprocess draining (H4)

    func testProcessRunnerReturnsOutputBeyondThePipeBuffer() async throws {
        let out = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes | head -c 400000"],
            timeout: 10
        )
        XCTAssertEqual(out.status, 0)
        XCTAssertEqual(out.stdout.count, 400_000)
    }

    func testProcessRunnerReadsStdinFreeCatOfLargeFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: 1_000_000).write(to: file)
        let out = try await ProcessRunner.run(executable: "/bin/cat", arguments: [file.path], timeout: 10)
        XCTAssertEqual(out.stdout.count, 1_000_000)
    }

    func testProcessRunnerDrainsStderrAndStdoutTogether() async throws {
        let out = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes out | head -c 200000; yes err | head -c 200000 >&2; exit 3"],
            timeout: 10
        )
        XCTAssertEqual(out.status, 3)
        XCTAssertEqual(out.stdout.count, 200_000)
        XCTAssertEqual(out.stderr.count, 200_000)
    }

    func testProcessRunnerTimesOutAndKillsTheChild() async throws {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.4)
            XCTFail("expected a timeout")
        } catch is ProcessRunner.Failure {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0)
    }

    func testProcessRunnerReportsLaunchFailure() async {
        do {
            _ = try await ProcessRunner.run(executable: "/nonexistent/binary", arguments: [], timeout: 2)
            XCTFail("expected a launch error")
        } catch {
            // any error is fine; it must not hang
        }
    }

    func testProcessRunnerDoesNotWaitForAGrandchildHoldingThePipe() async throws {
        let started = Date()
        let out = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo done; (sleep 5 &) ; exit 0"],
            timeout: 10,
            graceAfterExit: 0.3
        )
        XCTAssertEqual(out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "done")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0)
    }

    // MARK: - CDP frame demux (H3)

    func testFrameParsingSeparatesResponsesFailuresAndEvents() {
        let response = CDPFrame.parse(Data(#"{"id":7,"result":{"ok":true}}"#.utf8))
        XCTAssertEqual(response, .response(id: 7, result: .object(["ok": .bool(true)])))

        let failure = CDPFrame.parse(Data(#"{"id":8,"error":{"code":-32000,"message":"No node with given id found"}}"#.utf8))
        XCTAssertEqual(failure, .failure(id: 8, message: "No node with given id found"))

        XCTAssertEqual(CDPFrame.parse(Data(#"{"method":"Page.loadEventFired","params":{"timestamp":1.5}}"#.utf8)), .event(method: "Page.loadEventFired"))
        // Key order is Chrome's, not a contract: the slow path must still classify it.
        XCTAssertEqual(CDPFrame.parse(Data(#"{"params":{},"method":"Page.frameNavigated"}"#.utf8)), .event(method: "Page.frameNavigated"))
        XCTAssertEqual(CDPFrame.parse(Data("not json".utf8)), .other)
    }

    func testEventFramesAreClassifiedWithoutDecodingTheirPayload() {
        // Invalid JSON after the method name: only a payload-skipping peek can classify it.
        let truncated = Data(#"{"method":"Runtime.consoleAPICalled","params":{"args":[{"type":"str"#.utf8)
        XCTAssertEqual(CDPFrame.parse(truncated), .event(method: "Runtime.consoleAPICalled"))
    }

    func testRemoteNodeErrorsMapToStaleId() {
        XCTAssertEqual(CDPError.fromRemote(message: "No node with given id found"), .stale)
        XCTAssertEqual(CDPError.fromRemote(message: "Could not find node with given id"), .stale)
        XCTAssertEqual(CDPError.fromRemote(message: "Node is detached from document"), .stale)
        XCTAssertEqual(CDPError.fromRemote(message: "Invalid parameters"), .remote("Invalid parameters"))
        XCTAssertTrue(CDPError.stale.localizedDescription.contains("snapshot"))
    }

    // MARK: - CDPConnection against a real WebSocket server

    private func answer(_ id: Int, _ body: String = "{}") -> String { #"{"id":\#(id),"result":\#(body)}"# }

    private func request(_ text: String) -> (id: Int, method: String)? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let id = json["id"]?.intValue, let method = json["method"]?.stringValue else { return nil }
        return (id, method)
    }

    /// Concurrent sends used to steal each other's responses: each called receive() itself.
    func testConcurrentRequestsGetTheirOwnResponsesEvenWhenAnsweredInReverse() async throws {
        let server = try LoopbackWebSocketServer()
        let held = Locked<[(Int, String)]>([])
        server.handler = { [self] text, reply in
            guard let (id, method) = request(text) else { return }
            if method == "Page.enable" { return reply(answer(id)) }
            let count = held.withValue { $0.append((id, method)); return $0.count }
            if count == 3 {
                for (heldID, heldMethod) in held.value.reversed() {
                    reply(answer(heldID, #"{"method":"\#(heldMethod)"}"#))
                }
            }
        }
        try server.start()
        defer { server.stop() }
        let connection = CDPConnection(url: server.url)
        try await connection.open()
        async let a = connection.send(method: "First.call")
        async let b = connection.send(method: "Second.call")
        async let c = connection.send(method: "Third.call")
        let (ra, rb, rc) = try await (a, b, c)
        XCTAssertEqual(ra["method"]?.stringValue, "First.call")
        XCTAssertEqual(rb["method"]?.stringValue, "Second.call")
        XCTAssertEqual(rc["method"]?.stringValue, "Third.call")
        await connection.close()
    }

    /// URLSessionWebSocketTask kills the socket on a message over 1 MiB unless told otherwise.
    func testDefaultWebSocketTaskRejectsMessagesOverOneMiB() async throws {
        let server = try LoopbackWebSocketServer()
        server.handler = { _, reply in reply(String(repeating: "x", count: 3_000_000)) }
        try server.start()
        defer { server.stop() }
        let task = URLSession.shared.webSocketTask(with: server.url)
        task.resume()
        try await task.send(.string("go"))
        do {
            _ = try await task.receive()
            XCTFail("the 1 MiB platform default was expected to reject a 3 MB frame")
        } catch {
            // This is the premise behind CDPConnection.maximumMessageSize.
        }
        task.cancel(with: .goingAway, reason: nil)
    }

    func testConnectionReceivesMessagesLargerThanTheDefaultLimit() async throws {
        let server = try LoopbackWebSocketServer()
        let blob = String(repeating: "y", count: 3_000_000)
        server.handler = { [self] text, reply in
            guard let (id, method) = request(text) else { return }
            reply(method == "Accessibility.getFullAXTree" ? answer(id, #"{"nodes":"\#(blob)"}"#) : answer(id))
        }
        try server.start()
        defer { server.stop() }
        let connection = CDPConnection(url: server.url)
        try await connection.open()
        let tree = try await connection.send(method: "Accessibility.getFullAXTree")
        XCTAssertEqual(tree["nodes"]?.stringValue?.count, 3_000_000)
        // Still alive afterwards — the old failure left a dead connection cached.
        _ = try await connection.send(method: "Runtime.evaluate")
        let isOpen = await connection.isOpen
        XCTAssertTrue(isOpen)
        await connection.close()
    }

    func testRequestTimeoutFiresAndLeavesTheConnectionUsable() async throws {
        let server = try LoopbackWebSocketServer()
        server.handler = { [self] text, reply in
            guard let (id, method) = request(text) else { return }
            if method != "Never.reply" { reply(answer(id)) }
        }
        try server.start()
        defer { server.stop() }
        let connection = CDPConnection(url: server.url)
        try await connection.open()
        let started = Date()
        do {
            _ = try await connection.send(method: "Never.reply", timeout: 0.3)
            XCTFail("expected a timeout")
        } catch let error as CDPError {
            guard case .timeout(let method, _) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(method, "Never.reply")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        _ = try await connection.send(method: "Runtime.evaluate")
        await connection.close()
    }

    func testEventArrivingBeforeItsCommandResponseIsNotMissed() async throws {
        let server = try LoopbackWebSocketServer()
        server.handler = { [self] text, reply in
            guard let (id, method) = request(text) else { return }
            if method == "Page.navigate" {
                reply(#"{"method":"Page.loadEventFired","params":{"timestamp":1}}"#)
                reply(answer(id, #"{"loaderId":"L1"}"#))
            } else {
                reply(answer(id))
            }
        }
        try server.start()
        defer { server.stop() }
        let connection = CDPConnection(url: server.url)
        try await connection.open()
        let token = await connection.armEvent("Page.loadEventFired")
        let result = try await connection.send(method: "Page.navigate")
        XCTAssertEqual(result["loaderId"]?.stringValue, "L1")
        let fired = await connection.awaitEvent(token, timeout: 2)
        XCTAssertTrue(fired)

        let never = await connection.armEvent("Page.neverComes")
        let started = Date()
        let timedOut = await connection.awaitEvent(never, timeout: 0.25)
        XCTAssertFalse(timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        await connection.close()
    }

    func testSocketDropFailsPendingRequestsAsTransportErrors() async throws {
        let server = try LoopbackWebSocketServer()
        server.handler = { [self] text, reply in
            guard let (id, method) = request(text) else { return }
            if method == "Die" { server.closeAll() } else { reply(answer(id)) }
        }
        try server.start()
        defer { server.stop() }
        let connection = CDPConnection(url: server.url)
        try await connection.open()
        do {
            _ = try await connection.send(method: "Die", timeout: 5)
            XCTFail("expected the dropped socket to fail the request")
        } catch let error as CDPError {
            XCTAssertTrue(error.isTransport, "\(error)")
        }
        let isOpen = await connection.isOpen
        XCTAssertFalse(isOpen)
        do {
            _ = try await connection.send(method: "Runtime.evaluate")
            XCTFail("a closed connection must not accept requests")
        } catch let error as CDPError {
            XCTAssertTrue(error.isTransport)
        }
    }

    // MARK: - Handle store / capability bookkeeping

    func testReplacingWithZeroRefsRetiresThePreviousIds() async {
        let store = RoutedHandleStore()
        let scope = RoutedScope.cdp("https://zero-refs.test/\(UUID().uuidString)")
        let other = RoutedScope.cdp("https://other.test/\(UUID().uuidString)")
        let ref = RoutedRef.cdp(sessionKey: "a", document: "d", backendNodeId: 1, role: "button", label: "x")

        let mineIDs = await store.replace(refs: [ref], scope: scope)
        let theirIDs = await store.replace(refs: [ref], scope: other)
        let resolvedMine = await store.resolve(mineIDs[0])
        XCTAssertNotNil(resolvedMine)

        let none = await store.replace(refs: [], scope: scope)
        XCTAssertTrue(none.isEmpty)
        let afterMine = await store.resolve(mineIDs[0])
        let afterTheirs = await store.resolve(theirIDs[0])
        XCTAssertNil(afterMine, "an emptied page must not keep serving its old ids")
        XCTAssertNotNil(afterTheirs, "another session's ids are untouched")
    }

    func testEverySupportedToolIsOneTheRouterConsiders() {
        for backend: CapabilityRecord.Backend in [.cdp, .blenderLab, .blenderWS, .iosSim] {
            XCTAssertTrue(
                backend.supportedTools.isSubset(of: CapabilityRecord.routableTools),
                "\(backend.rawValue) claims tools the router never routes: \(backend.supportedTools.subtracting(CapabilityRecord.routableTools))"
            )
        }
        XCTAssertTrue(CapabilityRecord.Backend.ax.supportedTools.isEmpty)
    }

    func testUnsupportedToolsAreNotClaimedAndGetAnActionableMessage() {
        let web = CapabilityRecord(target: "https://x.test", backend: .cdp, reason: "")
        XCTAssertTrue(web.handles(tool: "snapshot"))
        XCTAssertFalse(web.handles(tool: "scroll"))
        XCTAssertFalse(web.handles(tool: "drag_drop"))
        let message = CapabilityRecord.unsupportedMessage(tool: "scroll", backend: .cdp)
        XCTAssertTrue(message.contains("not supported on web targets"), message)
        XCTAssertTrue(message.contains("run_app_code"), message)
        let blender = CapabilityRecord(target: "Blender", backend: .blenderLab, reason: "")
        XCTAssertTrue(blender.handles(tool: "run_app_code"))
        XCTAssertFalse(blender.handles(tool: "type_text"))
        let sim = CapabilityRecord(target: "booted", backend: .iosSim, reason: "")
        XCTAssertFalse(sim.handles(tool: "double_click"), "a double tap is not a single tap")
    }

    func testProbeCacheLifetimesAndInvalidation() async {
        let cache = ProbeCache()
        let long = CapabilityRecord(target: "Blender", backend: .blenderLab, reason: "")
        let short = CapabilityRecord(target: "Blender", backend: .ax, reason: "")
        let start = Date()
        await cache.set("a", long, at: start)
        await cache.set("b", short, at: start)
        let laterA = await cache.get("a", now: start.addingTimeInterval(20))
        let laterB = await cache.get("b", now: start.addingTimeInterval(20))
        XCTAssertNotNil(laterA, "a Blender verdict lives 30s")
        XCTAssertNil(laterB, "a fallback verdict is rechecked within 2s")
        let expiredA = await cache.get("a", now: start.addingTimeInterval(31))
        XCTAssertNil(expiredA)

        await cache.set("c", CapabilityRecord(target: "x", backend: .blenderWS, reason: ""), at: start)
        await cache.invalidate(backend: .blenderLab)
        let afterC = await cache.get("c", now: start)
        XCTAssertNil(afterC, "Lab and community Blender share one family")
    }

    func testBlenderEndpointRoundTripsThroughTheCapabilityRecord() {
        var record = CapabilityRecord(target: "Blender", backend: .blenderWS, reason: "r")
        record.endpoint = "127.0.0.1:9877"
        let endpoint = BlenderEndpoint(record: record)
        XCTAssertEqual(endpoint?.port, 9877)
        XCTAssertEqual(endpoint?.host, "127.0.0.1")
        XCTAssertEqual(endpoint?.kind, .blenderWS)
        XCTAssertEqual(endpoint?.address, "127.0.0.1:9877")
        XCTAssertNil(BlenderEndpoint(record: CapabilityRecord(target: "x", backend: .ax, reason: "")))
    }
}

/// Minimal lock-protected box for state shared with server callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
}
