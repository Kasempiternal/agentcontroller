import XCTest
@testable import AccessibilityEngine
@testable import MCPTools

/// The type_text keyboard fallback used to send Cmd+A, ForwardDelete to the app whenever
/// `append` was false — with no selector, or after AX refused focus, those keys landed on
/// the app's first responder and wiped the user's document. The decision to clear is now a
/// pure function of three facts; these pin every combination.
final class TypeTextSafetyTests: XCTestCase {

    private func isSkipped(_ d: InteractionTools.ClearDecision) -> Bool {
        if case .skipped = d { return true }
        return false
    }

    func testAppendNeverClears() {
        for role in [nil, "AXTextField", "AXGroup"] as [String?] {
            for focused in [true, false] {
                XCTAssertEqual(InteractionTools.clearDecision(append: true, role: role, focusConfirmed: focused), .notRequested)
            }
        }
    }

    func testNoResolvedElementNeverClears() {
        // The document-wiping case: no selector, so there is nothing to clear but the
        // app's first responder.
        XCTAssertTrue(isSkipped(InteractionTools.clearDecision(append: false, role: nil, focusConfirmed: true)))
        XCTAssertTrue(isSkipped(InteractionTools.clearDecision(append: false, role: nil, focusConfirmed: false)))
    }

    func testNonTextRolesAreNeverCleared() {
        for role in ["AXWebArea", "AXGroup", "AXScrollArea", "AXStaticText", "AXButton", ""] {
            XCTAssertTrue(isSkipped(InteractionTools.clearDecision(append: false, role: role, focusConfirmed: true)), role)
        }
    }

    func testUnconfirmedFocusNeverClearsEvenATextField() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertTrue(isSkipped(InteractionTools.clearDecision(append: false, role: role, focusConfirmed: false)), role)
        }
    }

    func testTextRoleWithConfirmedFocusClears() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertEqual(InteractionTools.clearDecision(append: false, role: role, focusConfirmed: true), .clear, role)
        }
    }

    func testSkipReasonsNameTheCause() {
        guard case .skipped(let noElement) = InteractionTools.clearDecision(append: false, role: nil, focusConfirmed: true),
              case .skipped(let notText) = InteractionTools.clearDecision(append: false, role: "AXWebArea", focusConfirmed: true),
              case .skipped(let noFocus) = InteractionTools.clearDecision(append: false, role: "AXTextField", focusConfirmed: false)
        else { return XCTFail("expected three skips") }
        XCTAssertTrue(noElement.contains("no element was resolved"), noElement)
        XCTAssertTrue(notText.contains("AXWebArea"), notText)
        XCTAssertTrue(noFocus.contains("confirm focus"), noFocus)
    }

    // MARK: - Shared interaction helpers

    func testDisabledErrorIsAnErrorNamingRoleAndAction() throws {
        let result = InteractionTools.disabledError(role: "AXButton", action: "AXPress")
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("AXButton is disabled"), text)
        XCTAssertTrue(text.contains("'AXPress'"), text)
    }

    func testBackgroundDeliveryTargetsThePidOnTheAppLane() async throws {
        let outcome = try await InteractionTools.deliver(pid: 4242, foreground: false) { target in target }
        guard case .delivered(let target) = outcome else { return XCTFail("background delivery must never be refused") }
        XCTAssertEqual(target, 4242)
    }

    func testComplexTypeTagNamesTheShapeWithoutWalkingIt() {
        XCTAssertEqual(InspectionTools.complexTypeTag(of: [1, 2, 3] as CFArray), "[array 3]")
        XCTAssertEqual(InspectionTools.complexTypeTag(of: AXUIElementCreateSystemWide()), "[axelement]")
        var point = CGPoint(x: 1, y: 2)
        let value = AXValueCreate(.cgPoint, &point)!
        XCTAssertEqual(InspectionTools.complexTypeTag(of: value), "[axvalue point]")
    }
}
