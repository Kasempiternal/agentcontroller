import XCTest
@testable import MCPServer

/// Every client numbers its JSON-RPC ids from 0, so a cancel only means something inside one
/// client's namespace. Clients that send no `X-AC-Client` share a single namespace, which made
/// an anonymous `notifications/cancelled` for id 1 stop some other anonymous client's id 1.
final class CancelNamespaceTests: XCTestCase {

    func testAnAnonymousCancelCannotStopAnotherAnonymousCall() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        let call = Task { await handler.handleRequest(Wire.call(1, "slow", tag: "other-clients-call"), clientId: nil) }
        _ = await eventually { provider.started.contains("other-clients-call") }

        let ack = await handler.handleRequest(Wire.cancel(1), clientId: nil)
        XCTAssertNil(ack)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(provider.cancelled.isEmpty, "a cancel with no session id reached a call it cannot name")

        // Hanging up still ends it: that path needs no id.
        call.cancel()
        _ = await call.value
        let ended = await eventually { provider.cancelled.contains("other-clients-call") }
        XCTAssertTrue(ended)
    }

    func testAnAnonymousCancelLeavesNoTombstoneThatCouldKillALaterAnonymousCall() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        _ = await handler.handleRequest(Wire.cancel(7), clientId: nil)
        let reply = Task { await handler.handleRequest(Wire.call(7, "echo", tag: "later"), clientId: nil) }
        let data = await reply.value
        XCTAssertNotNil(data, "a stray anonymous cancel must not pre-cancel the next anonymous request with that id")
        XCTAssertEqual(provider.finished, ["later"])
    }

    func testANamedClientCanStillCancelItsOwnCall() async {
        let provider = FakeProvider()
        let handler = MCPProtocolHandler(toolProvider: provider)
        let call = Task { await handler.handleRequest(Wire.call(1, "slow", tag: "mine"), clientId: "session-a") }
        _ = await eventually { provider.started.contains("mine") }
        _ = await handler.handleRequest(Wire.cancel(1), clientId: "session-a")
        let reply = await call.value
        XCTAssertNil(reply)
        XCTAssertEqual(provider.cancelled, ["mine"])
    }
}
