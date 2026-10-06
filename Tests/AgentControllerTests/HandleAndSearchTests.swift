import XCTest
import ApplicationServices
import MCPServer
@testable import AccessibilityEngine
@testable import MCPTools

/// A4: an app that is running with no windows is conclusively not showing the element.
/// A5: an element handle survives the control relabelling itself after the agent's own
/// action, and an app that does not answer is "busy", not "stale". A6: the click tool no
/// longer promises that scope:'app' searches the menu bar.
final class HandleAndSearchTests: XCTestCase {

    // MARK: - A4: windowless apps

    private func probe(visited: Int, noWindows: Bool = false, rootUnreadable: Bool = false) -> AXSearchProbe {
        AXSearchProbe(nodesVisited: visited, nearMisses: 0, oneAway: 0, criteriaCount: 1,
                      unreadableNodes: rootUnreadable ? visited : 0,
                      rootUnreadable: rootUnreadable, appHasNoWindows: noWindows)
    }

    func testAnApplicationRootWhoseWindowListReadBackEmptyIsConclusiveAbsence() {
        let walk = probe(visited: 1, noWindows: true)
        XCTAssertTrue(walk.isConclusive)
        XCTAssertEqual(NotVisibleJudge.observe(found: false, probe: walk, processAlive: true), .absent)
    }

    func testAOneNodeWalkThatSawNoEmptyWindowListIsStillInconclusive() {
        guard case .inconclusive = NotVisibleJudge.observe(found: false, probe: probe(visited: 1), processAlive: true) else {
            return XCTFail("one visited node with no answer about windows says nothing")
        }
    }

    func testAnUnreadableRootIsNeverConclusiveEvenIfWindowsSeemEmpty() {
        let walk = probe(visited: 1, noWindows: true, rootUnreadable: true)
        XCTAssertFalse(walk.isConclusive)
        guard case .inconclusive = NotVisibleJudge.observe(found: false, probe: walk, processAlive: true) else {
            return XCTFail("a hung app's empty read is not an answer")
        }
    }

    func testADeadProcessIsStillInconclusiveForAWindowlessProbe() {
        guard case .inconclusive = NotVisibleJudge.observe(found: false, probe: probe(visited: 1, noWindows: true), processAlive: false) else {
            return XCTFail("an exited app is an error, not a pass")
        }
    }

    // MARK: - A5: handles that follow the agent's own action

    private func fingerprint(_ name: String?, id: String? = nil, role: String? = "AXButton") -> AXElementFingerprint {
        AXElementFingerprint(role: role, name: name, identifier: id)
    }

    func testAnUnchangedFingerprintIsCurrent() {
        XCTAssertEqual(ElementHandleStore.verdict(
            registered: fingerprint("Play"), live: fingerprint("Play"), actedAt: nil, now: Date()), .current)
    }

    func testARenameWithoutAnActionIsStale() {
        XCTAssertEqual(ElementHandleStore.verdict(
            registered: fingerprint("Delete Alice"), live: fingerprint("Delete Bob"), actedAt: nil, now: Date()), .stale)
    }

    func testARenameRightAfterTheAgentActedOnThatHandleIsFollowed() {
        let now = Date()
        XCTAssertEqual(ElementHandleStore.verdict(
            registered: fingerprint("Play"), live: fingerprint("Pause"), actedAt: now.addingTimeInterval(-0.5), now: now), .refresh)
    }

    func testTheLeniencyExpires() {
        let now = Date()
        let late = now.addingTimeInterval(-(ElementHandleStore.selfChangeWindow + 0.1))
        XCTAssertEqual(ElementHandleStore.verdict(
            registered: fingerprint("Play"), live: fingerprint("Pause"), actedAt: late, now: now), .stale)
    }

    func testARoleOrIdentifierChangeIsNeverFollowedEvenAfterAnAction() {
        let now = Date()
        let acted = now.addingTimeInterval(-0.1)
        XCTAssertEqual(ElementHandleStore.verdict(
            registered: fingerprint("Row", id: "row-1"), live: fingerprint("Row", id: "row-2"), actedAt: acted, now: now), .stale)
        XCTAssertEqual(ElementHandleStore.verdict(
            registered: fingerprint("Row"), live: fingerprint("Row", role: "AXStaticText"), actedAt: acted, now: now), .stale)
    }

    func testAHandleForAnExitedAppIsStaleNotBusy() async {
        let deadPID: pid_t = 2_147_483_000
        let ids = await ElementHandleStore.shared.replace(with: [AXElement.application(pid: deadPID, timeout: 0.5)], pid: deadPID)
        guard case .stale = await ElementHandleStore.shared.lookup(ids[0]) else {
            return XCTFail("a process that is gone needs a re-snapshot, not a retry")
        }
    }

    func testAnUnknownHandleIsStale() async {
        guard case .stale = await ElementHandleStore.shared.lookup("e-never-minted") else {
            return XCTFail("unknown ids are stale")
        }
    }

    func testBusyAndStaleHandleErrorsGiveOppositeAdvice() {
        func text(_ result: JSONValue) -> String { result["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }
        let stale = text(InteractionTools.staleHandleError("e5"))
        let busy = text(InteractionTools.busyHandleError("e5"))
        XCTAssertTrue(stale.contains("Re-run snapshot"), stale)
        XCTAssertTrue(busy.contains("retry"), busy)
        XCTAssertTrue(busy.contains("NOT known to be stale"), busy)
    }

    // MARK: - A6: scope text

    func testClickNoLongerPromisesThatScopeAppSearchesTheMenuBar() throws {
        let click = try XCTUnwrap(ToolRegistry().listTools().first { $0["name"]?.stringValue == "click" })
        let description = try XCTUnwrap(click["description"]?.stringValue)
        let scope = try XCTUnwrap(click["inputSchema"]?["properties"]?["scope"]?["description"]?.stringValue)
        for text in [description, scope] {
            XCTAssertFalse(text.contains("all windows + menu bar"), text)
            XCTAssertTrue(text.contains("includeMenus"), text)
        }
        XCTAssertTrue(scope.contains("AXMenu*"), scope)
    }
}
