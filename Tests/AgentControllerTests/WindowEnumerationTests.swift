import XCTest
@testable import AccessibilityEngine
@testable import MCPTools

/// macOS hides windows on an inactive Space from an app element's `kAXWindows` and from
/// its `kAXChildren`, so `list_windows` reported zero windows for apps whose windows were
/// plainly on screen. The recovery tiers fix the count; these tests pin the property that
/// makes the recovery safe — a recovered window must never look addressable.
final class WindowEnumerationTests: XCTestCase {

    // MARK: - The index/source invariant

    func testOnlyAccessibilityWindowsCarryAnIndex() {
        XCTAssertEqual(WindowSource.accessibility(index: 3).index, 3)
        XCTAssertNil(WindowSource.focusedWindow.index)
        XCTAssertNil(WindowSource.windowServer.index)
    }

    func testSourceNamesAreTheWireStrings() {
        XCTAssertEqual(WindowSource.accessibility(index: 0).name, "accessibility")
        XCTAssertEqual(WindowSource.focusedWindow.name, "focusedWindow")
        XCTAssertEqual(WindowSource.windowServer.name, "windowServer")
    }

    /// The zero index is the dangerous one: `windowIndex: 0` is the default a caller
    /// reaches for, so a recovered window must not answer to it.
    func testRecoveredWindowsDoNotAnswerToIndexZero() {
        XCTAssertNotEqual(WindowSource.focusedWindow.index, 0)
        XCTAssertNotEqual(WindowSource.windowServer.index, 0)
    }

    // MARK: - Deduplication between tiers

    func testIdenticalFramesAreTheSameWindow() {
        let frame = CGRect(x: 0, y: 33, width: 1728, height: 1084)
        XCTAssertTrue(WindowManager.sameWindow(frame, frame))
    }

    /// AX and the window server round a frame differently by a fraction of a point, so an
    /// exact comparison would list one window twice.
    func testSubPixelDriftStillMatches() {
        XCTAssertTrue(WindowManager.sameWindow(
            CGRect(x: 0, y: 33, width: 1728, height: 1084),
            CGRect(x: 0.5, y: 34, width: 1727, height: 1085)))
    }

    func testDifferentWindowsDoNotMatch() {
        XCTAssertFalse(WindowManager.sameWindow(
            CGRect(x: 0, y: 33, width: 1728, height: 1084),
            CGRect(x: 0, y: 617, width: 500, height: 500)))
    }

    func testSameOriginDifferentSizeDoesNotMatch() {
        // Two windows stacked at the same corner are still two windows.
        XCTAssertFalse(WindowManager.sameWindow(
            CGRect(x: 0, y: 33, width: 1728, height: 1084),
            CGRect(x: 0, y: 33, width: 1728, height: 113)))
    }
}

/// `type_text` used to return `success: true` the moment the keystrokes were posted,
/// whether or not anything received them. These pin the tri-state that replaced it.
final class WriteVerificationTests: XCTestCase {

    /// No target element means no readback, and no readback means no claim — this must
    /// never collapse into "landed".
    func testNoElementIsUnverifiableNotSuccess() async {
        let verdict = await InteractionTools.verifyWrite(
            pid: ProcessInfo.processInfo.processIdentifier, element: nil, text: "hello", append: false)
        guard case .unverifiable = verdict else {
            return XCTFail("expected .unverifiable, got \(verdict)")
        }
    }

    /// The poll has to outlast a frame or two of event delivery, or every write on a busy
    /// app reports a false negative — but it must stay far under the find timeout, since
    /// it is paid on the success path too.
    func testVerifyDeadlineOutlastsEventDeliveryWithoutStalling() {
        XCTAssertGreaterThanOrEqual(InteractionTools.writeVerifyDeadline, 0.3)
        XCTAssertLessThan(InteractionTools.writeVerifyDeadline, InteractionTools.defaultFindTimeout / 4)
        XCTAssertLessThan(InteractionTools.writeVerifyPollInterval, InteractionTools.writeVerifyDeadline)
    }
}

/// A snapshot that walked the application element instead of a window returned hundreds
/// of menu items and called it a screen description. The root has to be reportable.
final class SnapshotRootTests: XCTestCase {

    func testRootNamesAreDistinctWireStrings() {
        let names = Set([
            SnapshotTools.WalkRoot.focusedWindow.rawValue,
            SnapshotTools.WalkRoot.firstWindow.rawValue,
            SnapshotTools.WalkRoot.application.rawValue,
        ])
        XCTAssertEqual(names.count, 3)
    }

    /// `application` is the degraded root, and the warning keys off exactly this value.
    func testApplicationIsTheDegradedRoot() {
        XCTAssertEqual(SnapshotTools.WalkRoot.application.rawValue, "application")
    }
}
