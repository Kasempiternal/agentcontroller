import XCTest
@testable import AccessibilityEngine
@testable import MCPTools
import MCPServer

/// Focus Guard is the hard guarantee behind "background by default": the tool
/// dispatcher must refuse every focus-stealing call while the guard is on.
/// These tests exercise the dispatch-level gate only — no AX APIs are touched,
/// so they run headless in CI without accessibility permissions.
final class FocusGuardTests: XCTestCase {
    private var originalState = true

    override func setUp() {
        super.setUp()
        originalState = FocusGuard.isEnabled
    }

    override func tearDown() {
        FocusGuard.setEnabled(originalState)
        super.tearDown()
    }

    private func isErrorResult(_ value: JSONValue) -> Bool {
        value["isError"]?.boolValue == true
    }

    private func resultText(_ value: JSONValue) -> String {
        value["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    func testActivateAppRefusedWhileGuardOn() async throws {
        FocusGuard.setEnabled(true)
        let registry = ToolRegistry()
        let result = try await registry.callTool(
            name: "activate_app",
            arguments: .object(["app": .string("com.example.NotRunning")])
        )
        XCTAssertTrue(isErrorResult(result))
        XCTAssertTrue(resultText(result).contains("Focus Guard"))
        // The denial must re-steer the agent, not just refuse.
        XCTAssertTrue(resultText(result).contains("background"))
    }

    func testForegroundTrueRefusedWhileGuardOn() async throws {
        FocusGuard.setEnabled(true)
        let registry = ToolRegistry()
        let result = try await registry.callTool(
            name: "click",
            arguments: .object([
                "app": .string("com.example.NotRunning"),
                "x": .double(10), "y": .double(10),
                "foreground": .bool(true),
            ])
        )
        XCTAssertTrue(isErrorResult(result))
        XCTAssertTrue(resultText(result).contains("Focus Guard"))
        XCTAssertTrue(resultText(result).contains("click"))
    }

    func testForegroundFalseNotGatedByGuard() async throws {
        // foreground:false (or absent) must never be intercepted by the guard.
        // Use an app string that cannot resolve so the handler exits at PID
        // resolution — before any AX call — keeping the test headless-safe.
        FocusGuard.setEnabled(true)
        let registry = ToolRegistry()
        do {
            let result = try await registry.callTool(
                name: "click",
                arguments: .object([
                    "app": .string("com.example.definitely-not-running-\(UUID().uuidString)"),
                    "x": .double(10), "y": .double(10),
                ])
            )
            XCTAssertFalse(resultText(result).contains("Focus Guard"))
        } catch {
            // ToolError.appNotFound is the expected handler-level outcome; the
            // point is it reached the handler instead of the guard.
            XCTAssertTrue("\(error)".contains("appNotFound") || error is ToolError)
        }
    }

    func testActivateAppReachesHandlerWhileGuardOff() async throws {
        FocusGuard.setEnabled(false)
        let registry = ToolRegistry()
        let result = try await registry.callTool(
            name: "activate_app",
            arguments: .object(["app": .string("com.example.definitely-not-running-\(UUID().uuidString)")])
        )
        // Guard off → the handler runs and reports app-not-found (an error, but
        // NOT the Focus Guard denial).
        XCTAssertTrue(isErrorResult(result))
        XCTAssertFalse(resultText(result).contains("Focus Guard"))
    }

    func testPersistenceRoundTrip() {
        FocusGuard.setEnabled(false)
        XCTAssertFalse(FocusGuard.isEnabled)
        FocusGuard.setEnabled(true)
        XCTAssertTrue(FocusGuard.isEnabled)
    }
}
