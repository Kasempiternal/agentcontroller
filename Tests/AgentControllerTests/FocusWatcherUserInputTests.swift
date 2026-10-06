import XCTest
import CoreGraphics
@testable import AccessibilityEngine

/// A user who Cmd-Tabs or clicks to a driven app inside the attribution window used to be
/// restored away from. A fresh physical click or keystroke marks the activation as theirs.
final class FocusWatcherUserInputTests: XCTestCase {
    private let driven: Set<pid_t> = [100]

    private func stolen(sinceInput: TimeInterval?) -> Bool {
        FocusWatcher.isStolenFocus(
            activatedPID: 100, drivenPIDs: driven,
            expected: false, guardEnabled: true,
            secondsSinceLastDispatch: 2,
            secondsSinceUserInput: sinceInput
        )
    }

    func testActivationRightAfterUserInputIsTheUsersOwn() {
        XCTAssertFalse(stolen(sinceInput: 0.05))
        XCTAssertFalse(stolen(sinceInput: FocusWatcher.userInputGrace - 0.01))
    }

    func testActivationWithNoRecentInputIsStillAnAgentSteal() {
        XCTAssertTrue(stolen(sinceInput: FocusWatcher.userInputGrace))
        XCTAssertTrue(stolen(sinceInput: 12))
        XCTAssertTrue(stolen(sinceInput: .infinity))
    }

    func testOmittingUserInputKeepsTheOriginalRule() {
        XCTAssertTrue(stolen(sinceInput: nil))
    }

    /// Cmd-Tab activates when Cmd is RELEASED, after however long the switcher was held open;
    /// a Dock click activates on mouse-UP. Presses alone (and half a second) missed both.
    func testTheGraceOutlastsTheGapBetweenAnInputAndTheActivationItCauses() {
        XCTAssertGreaterThanOrEqual(FocusWatcher.userInputGrace, 2)
        XCTAssertFalse(stolen(sinceInput: 1.5))
        XCTAssertTrue(stolen(sinceInput: FocusWatcher.userInputGrace + 0.5))
    }

    func testReleasesScrollsAndModifierChangesCountAsTheUsersInput() {
        let counted = Set(FocusWatcher.userInputEvents.map(\.rawValue))
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
                     .scrollWheel, .keyDown, .keyUp, .flagsChanged] {
            XCTAssertTrue(counted.contains(type.rawValue), "\(type) is physical input that can end in an activation")
        }
    }

    func testUserInputClockIsReadable() {
        let seconds = FocusWatcher.secondsSinceUserInput()
        XCTAssertGreaterThanOrEqual(seconds, 0)
    }
}
