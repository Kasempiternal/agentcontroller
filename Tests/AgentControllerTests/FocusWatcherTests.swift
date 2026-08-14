import XCTest
@testable import AccessibilityEngine
@testable import MCPTools
import MCPServer

/// The FocusWatcher closes the channel-independence gap in Focus Guard: an
/// agent refused `foreground:true` was observed switching to shell `osascript`
/// activation. These tests exercise the pure attribution rule and the result
/// plumbing only — no AX APIs, no NSWorkspace observers — so they run headless
/// in CI without accessibility permissions.
final class FocusWatcherTests: XCTestCase {
    private let driven: Set<pid_t> = [100, 200]

    func testActivationOfDrivenAppShortlyAfterDispatchIsStolen() {
        XCTAssertTrue(FocusWatcher.isStolenFocus(
            activatedPID: 100, drivenPIDs: driven,
            expected: false, guardEnabled: true,
            secondsSinceLastDispatch: 2
        ))
    }

    func testGuardOffNeverRestores() {
        XCTAssertFalse(FocusWatcher.isStolenFocus(
            activatedPID: 100, drivenPIDs: driven,
            expected: false, guardEnabled: false,
            secondsSinceLastDispatch: 2
        ))
    }

    func testNonDrivenAppIsNeverStolen() {
        // The user switching to their own apps must never trigger a restore.
        XCTAssertFalse(FocusWatcher.isStolenFocus(
            activatedPID: 999, drivenPIDs: driven,
            expected: false, guardEnabled: true,
            secondsSinceLastDispatch: 1
        ))
    }

    func testExpectedServerActivationIsNotStolen() {
        XCTAssertFalse(FocusWatcher.isStolenFocus(
            activatedPID: 100, drivenPIDs: driven,
            expected: true, guardEnabled: true,
            secondsSinceLastDispatch: 1
        ))
    }

    func testUserClickOutsideAttributionWindowIsNotStolen() {
        // A quiet run: the human deliberately bringing the QA app forward must
        // not be fought.
        XCTAssertFalse(FocusWatcher.isStolenFocus(
            activatedPID: 100, drivenPIDs: driven,
            expected: false, guardEnabled: true,
            secondsSinceLastDispatch: FocusWatcher.attributionWindow + 1
        ))
    }

    func testNoDispatchYetIsNotStolen() {
        XCTAssertFalse(FocusWatcher.isStolenFocus(
            activatedPID: 100, drivenPIDs: driven,
            expected: false, guardEnabled: true,
            secondsSinceLastDispatch: nil
        ))
    }

    func testIncidentMessageResteersTheAgent() {
        let msg = FocusWatcher.incidentMessage(appName: "TestApp")
        // Must name the bypass so the model recognizes what it did…
        XCTAssertTrue(msg.contains("osascript"))
        // …and name the approved alternatives so it self-corrects in-band.
        XCTAssertTrue(msg.contains("background-safe"))
        XCTAssertTrue(msg.contains("launch_app"))
        XCTAssertTrue(msg.contains("TestApp"))
    }

    // MARK: - Result plumbing

    func testAppendingNoticeAddsTextItemAndPreservesPayload() {
        let original = ToolResult.json(.object(["success": .bool(true)]))
        let appended = ToolResult.appendingNotice("warning text", to: original)
        let content = appended["content"]?.arrayValue ?? []
        XCTAssertEqual(content.count, 2)
        XCTAssertTrue(content.first?["text"]?.stringValue?.contains("success") ?? false)
        XCTAssertEqual(content.last?["text"]?.stringValue, "warning text")
    }

    func testAppendingNoticePreservesErrorFlag() {
        let original = ToolResult.error("boom")
        let appended = ToolResult.appendingNotice("warning text", to: original)
        XCTAssertEqual(appended["isError"]?.boolValue, true)
        XCTAssertEqual(appended["content"]?.arrayValue?.count, 2)
    }
}
