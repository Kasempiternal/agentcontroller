import XCTest
import MCPServer

/// 3.1.0: every client reads the autonomy mandate in the server instructions.
final class AutonomyTests: XCTestCase {

    func testServerInstructionsOpenWithTheAutonomyMandate() async {
        let handler = MCPProtocolHandler(toolProvider: FakeProvider())
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)
        let reply = await handler.handleRequest(request, clientId: "t")
        let text = reply.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(text.contains("AUTONOMY"), "the mandate is in the instructions every client receives")
        XCTAssertTrue(text.contains("Never hand the user a step you can perform"))
        XCTAssertTrue(text.contains("Prompt the user ONLY"))
    }
}
