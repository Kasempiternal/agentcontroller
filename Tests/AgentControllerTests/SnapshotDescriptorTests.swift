import XCTest
import ApplicationServices
import MCPServer
@testable import AccessibilityEngine
@testable import MCPTools

/// snapshot now builds each descriptor from the node's single batched read. The output
/// shape agents depend on must not move.
final class SnapshotDescriptorTests: XCTestCase {
    private func point(_ x: Double, _ y: Double) -> CFTypeRef {
        var p = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &p)!
    }

    private func size(_ w: Double, _ h: Double) -> CFTypeRef {
        var s = CGSize(width: w, height: h)
        return AXValueCreate(.cgSize, &s)!
    }

    func testDescriptorHasTheDocumentedShape() {
        let fields = SnapshotTools.descriptorFields(from: [
            "AXRole": "AXButton" as CFString,
            "AXTitle": "Save" as CFString,
            "AXEnabled": kCFBooleanFalse,
            "AXPosition": point(10, 20),
            "AXSize": size(80, 24),
        ])
        XCTAssertEqual(fields, [
            "role": .string("AXButton"),
            "enabled": .bool(false),
            "label": .string("Save"),
            "frame": .object(["x": .double(10), "y": .double(20), "w": .double(80), "h": .double(24)]),
        ])
    }

    func testDefaultsWhenAttributesAreMissing() {
        XCTAssertEqual(SnapshotTools.descriptorFields(from: [:]),
                       ["role": .string("unknown"), "enabled": .bool(true)])
    }

    func testFrameNeedsBothPositionAndSize() {
        let onlyPosition = SnapshotTools.descriptorFields(from: ["AXRole": "AXGroup" as CFString, "AXPosition": point(1, 2)])
        XCTAssertNil(onlyPosition["frame"])
    }

    func testLabelFallsBackTitleThenDescriptionThenValueThenIdentifier() {
        XCTAssertEqual(SnapshotTools.label(from: ["AXTitle": "T" as CFString, "AXDescription": "D" as CFString,
                                                  "AXValue": "V" as CFString, "AXIdentifier": "I" as CFString]), "T")
        XCTAssertEqual(SnapshotTools.label(from: ["AXTitle": "" as CFString, "AXDescription": "D" as CFString,
                                                  "AXValue": "V" as CFString, "AXIdentifier": "I" as CFString]), "D")
        XCTAssertEqual(SnapshotTools.label(from: ["AXValue": "V" as CFString, "AXIdentifier": "I" as CFString]), "V")
        XCTAssertEqual(SnapshotTools.label(from: ["AXValue": "" as CFString, "AXIdentifier": "I" as CFString]), "I")
        XCTAssertNil(SnapshotTools.label(from: [:]))
    }

    func testNonStringValuesBecomeLabels() {
        XCTAssertEqual(SnapshotTools.label(from: ["AXValue": NSNumber(value: 1)]), "1")
        XCTAssertEqual(SnapshotTools.label(from: ["AXValue": kCFBooleanFalse]), "0")
    }

    // MARK: - Qualification

    func testInteractiveRoleSkipsTheActionNamesCall() {
        var asked = false
        let result = SnapshotTools.qualifies(role: "AXButton", actions: { asked = true; return [] }())
        XCTAssertTrue(result)
        XCTAssertFalse(asked, "actionNames is an IPC call; a known controly role must not pay for it")
    }

    func testOtherRolesQualifyOnlyThroughRealActions() {
        XCTAssertTrue(SnapshotTools.qualifies(role: "AXGroup", actions: ["AXPress"]))
        XCTAssertFalse(SnapshotTools.qualifies(role: "AXStaticText", actions: ["AXShowMenu", "AXScrollToVisible"]),
                       "WebKit hangs these on every node")
        XCTAssertFalse(SnapshotTools.qualifies(role: nil, actions: []))
    }
}
