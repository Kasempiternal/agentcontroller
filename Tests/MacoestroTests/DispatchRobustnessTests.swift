import XCTest
@testable import AccessibilityEngine
@testable import MCPTools
import MCPServer

/// The dispatch layer must survive spec-legal-but-hostile inputs: `arguments`
/// is OPTIONAL in MCP `tools/call`, and flow steps may throw. Neither may ever
/// crash the process or discard sibling results. All tests are headless-safe:
/// every call fails at parameter/PID resolution, before any AX API.
final class DispatchRobustnessTests: XCTestCase {
    private var originalGuardState = true

    override func setUp() {
        super.setUp()
        originalGuardState = FocusGuard.isEnabled
        FocusGuard.setEnabled(true)
    }

    override func tearDown() {
        FocusGuard.setEnabled(originalGuardState)
        super.tearDown()
    }

    private func resultText(_ value: JSONValue) -> String {
        value["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    /// One tools/call with absent `arguments` used to force-unwrap nil in the
    /// handler and take down the entire server. It must now surface as a
    /// normal missing-parameter error.
    func testNilArgumentsDoesNotCrash() async {
        let registry = ToolRegistry()
        do {
            _ = try await registry.callTool(name: "click", arguments: nil)
            XCTFail("click without arguments should throw missingParameter")
        } catch let error as ToolError {
            XCTAssertEqual(error.errorDescription, "Missing required parameter: app")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNilArgumentsAcrossRepresentativeTools() async {
        let registry = ToolRegistry()
        // One tool per handler file that requires parameters — the point is
        // that NONE of them trap on nil args.
        for tool in ["type_text", "screenshot_window", "assert_visible",
                     "navigate_menu", "set_window_bounds", "read_text",
                     "wait_for_element", "scroll", "hide_app"] {
            do {
                let result = try await registry.callTool(name: tool, arguments: nil)
                // Tools that report errors as isError results instead of
                // throwing are fine too — surviving the call is the contract.
                XCTAssertNotNil(result, "\(tool) returned nothing for nil args")
            } catch {
                XCTAssertTrue(error is ToolError,
                              "\(tool) threw a non-ToolError for nil args: \(error)")
            }
        }
    }

    /// A step whose handler THROWS must be recorded as a failed step; the
    /// steps before and after it must keep their results.
    func testRunStepsRecordsThrowingStepInsteadOfAborting() async throws {
        let registry = ToolRegistry()
        let steps: JSONValue = .array([
            .object(["tool": .string("nonexistent_tool")]),                // isError result
            .object(["tool": .string("click")]),                          // throws (no app)
            .object(["tool": .string("list_flows")]),                     // succeeds, AX-free
        ])
        let result = try await registry.callTool(
            name: "run_steps",
            arguments: .object(["steps": steps, "stopOnError": .bool(false)])
        )
        let text = resultText(result)
        XCTAssertFalse(text.isEmpty)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(parsed["ran"]?.intValue, 3, "all three steps must be recorded")
        let results = parsed["results"]?.arrayValue ?? []
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0]["isError"]?.boolValue, true)
        XCTAssertEqual(results[1]["isError"]?.boolValue, true,
                       "the throwing step must be recorded as a failed step")
        XCTAssertEqual(results[2]["isError"]?.boolValue, false)
    }

    func testRunStepsStopOnErrorStillStopsOnThrow() async throws {
        let registry = ToolRegistry()
        let steps: JSONValue = .array([
            .object(["tool": .string("click")]),          // throws (no app)
            .object(["tool": .string("list_flows")]),     // must NOT run
        ])
        let result = try await registry.callTool(
            name: "run_steps",
            arguments: .object(["steps": steps, "stopOnError": .bool(true)])
        )
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(parsed["ran"]?.intValue, 1)
        XCTAssertEqual(parsed["failedAt"]?.intValue, 0)
    }
}
