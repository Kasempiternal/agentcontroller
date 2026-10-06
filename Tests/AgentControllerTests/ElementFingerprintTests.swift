import XCTest
import ApplicationServices
@testable import AccessibilityEngine

/// A recycled table cell keeps a live AXUIElement ref, so liveness cannot tell the
/// control a snapshot registered from the one that reuses the ref. The fingerprint can.
final class ElementFingerprintTests: XCTestCase {
    private func attrs(role: String? = "AXButton", title: String? = nil,
                       description: String? = nil, identifier: String? = nil) -> [String: CFTypeRef] {
        var out: [String: CFTypeRef] = [:]
        if let role { out["AXRole"] = role as CFString }
        if let title { out["AXTitle"] = title as CFString }
        if let description { out["AXDescription"] = description as CFString }
        if let identifier { out["AXIdentifier"] = identifier as CFString }
        return out
    }

    func testTitleWinsAndDescriptionIsTheFallbackName() {
        XCTAssertEqual(AXElementFingerprint(attributes: attrs(title: "Save", description: "disk")).name, "Save")
        XCTAssertEqual(AXElementFingerprint(attributes: attrs(title: "", description: "Delete row 3")).name, "Delete row 3")
        XCTAssertNil(AXElementFingerprint(attributes: attrs()).name)
    }

    func testEmptyStringsNormalizeToNil() {
        let fp = AXElementFingerprint(role: "AXCell", name: "", identifier: "")
        XCTAssertNil(fp.name)
        XCTAssertNil(fp.identifier)
        XCTAssertEqual(fp, AXElementFingerprint(role: "AXCell", name: nil, identifier: nil))
    }

    func testSameControlIsNotStale() {
        let registered = AXElementFingerprint(attributes: attrs(title: "Save", identifier: "save-btn"))
        let live = AXElementFingerprint(attributes: attrs(title: "Save", identifier: "save-btn"))
        XCTAssertFalse(registered.isStale(comparedTo: live))
    }

    func testReusedCellWithDifferentNameIsStale() {
        let registered = AXElementFingerprint(attributes: attrs(role: "AXButton", description: "Delete Alice"))
        let live = AXElementFingerprint(attributes: attrs(role: "AXButton", description: "Delete Bob"))
        XCTAssertTrue(registered.isStale(comparedTo: live))
    }

    func testDifferentIdentifierOrRoleIsStale() {
        let base = AXElementFingerprint(attributes: attrs(title: "Row", identifier: "row-1"))
        XCTAssertTrue(base.isStale(comparedTo: AXElementFingerprint(attributes: attrs(title: "Row", identifier: "row-2"))))
        XCTAssertTrue(base.isStale(comparedTo: AXElementFingerprint(attributes: attrs(role: "AXStaticText", title: "Row", identifier: "row-1"))))
    }

    func testUnreadableElementHasNoFingerprint() {
        let dead = AXElement.application(pid: 2_147_483_000, timeout: 0.5)
        XCTAssertNil(AXElementFingerprint(reading: dead))
    }

    // MARK: - Store

    func testHandleForAnExitedProcessDoesNotResolve() async {
        let store = ElementHandleStore.shared
        let deadPID: pid_t = 2_147_483_000
        let element = AXElement.application(pid: deadPID, timeout: 0.5)
        let ids = await store.replace(with: [element], pid: deadPID)
        let resolved = await store.resolve(ids[0])
        XCTAssertNil(resolved)
    }

    func testHandleDoesNotResolveForADifferentPid() async {
        let store = ElementHandleStore.shared
        let me = getpid()
        let element = AXElement.application(pid: me, timeout: 0.5)
        let ids = await store.replace(with: [element], pid: me)
        let resolved = await store.resolve(ids[0], pid: me + 1)
        XCTAssertNil(resolved)
    }

    func testUnknownIdDoesNotResolve() async {
        let resolved = await ElementHandleStore.shared.resolve("e-never-minted")
        XCTAssertNil(resolved)
    }
}
