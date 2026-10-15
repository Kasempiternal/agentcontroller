import XCTest
import MCPServer
@testable import MCPTools

/// 3.1.0: dead ends found in a week of agent sessions — a physical iPhone UDID answered with
/// "Missing required parameter: target", and a batch reply too large for the client to accept.
final class ToolFixesTests: XCTestCase {

    func testHardwareUDIDIsRecognisedAndNotTakenForASimulator() {
        XCTAssertTrue(TargetIdentity.isHardwareUDID("00008110-000A1B2C3D4E5F60"))
        XCTAssertFalse(TargetIdentity.isHardwareUDID("5A643D9A-2CFB-48E3-9F3B-0A8F1B1C2D3E"), "a simulator UUID")
        XCTAssertFalse(TargetIdentity.isHardwareUDID("booted"))
        XCTAssertFalse(TargetIdentity.isHardwareUDID("Safari"))
        XCTAssertNotNil(TargetIdentity.from(arguments: .object(["udid": .string("00008110-000A1B2C3D4E5F60")])),
                        "naming a current iPhone is no longer 'Missing required parameter: target'")
        let guidance = TargetIdentity.hardwareDeviceGuidance("00008110-000A1B2C3D4E5F60")
        XCTAssertTrue(guidance.contains("agentcontroller-ios"), guidance)
        XCTAssertTrue(guidance.contains("00008110-000A1B2C3D4E5F60"), guidance)
    }

    // MARK: - Reply budget

    func testOversizedBatchReplyIsTrimmedLargestStepFirst() {
        let big = String(repeating: "x", count: 150_000)
        let results: [JSONValue] = [
            .object(["tool": .string("click"), "isError": .bool(false), "result": .object(["success": .bool(true)])]),
            .object(["tool": .string("read_all_text"), "isError": .bool(false), "result": .string(big)]),
        ]
        let trimmed = FlowTools.withinBudget(results)
        XCTAssertEqual(trimmed[0], results[0], "small steps are untouched")
        XCTAssertEqual(trimmed[1]["result"]?["truncated"]?.boolValue, true)
        XCTAssertNotNil(trimmed[1]["result"]?["hint"]?.stringValue)
        XCTAssertEqual(FlowTools.withinBudget([results[0]]), [results[0]], "under budget: returned as is")
    }
}
