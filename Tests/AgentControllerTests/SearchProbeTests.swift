import XCTest
@testable import AccessibilityEngine
@testable import MCPTools

/// The fail-fast rule separates "this control has not rendered yet" (worth
/// waiting out) from "this selector describes nothing in this app" (a 4-second
/// wait for an answer that cannot change). All tests are headless-safe: the
/// rule and the criteria arithmetic are pure functions of the probe.
final class SearchProbeTests: XCTestCase {

    // MARK: - searchIsHopeless

    func testEmptyWalkIsNeverHopeless() {
        // Near-zero nodes means the UI had not rendered — precisely when waiting pays.
        XCTAssertFalse(InteractionTools.searchIsHopeless(.empty))
        XCTAssertFalse(InteractionTools.searchIsHopeless(
            AXSearchProbe(nodesVisited: 3, nearMisses: 0, oneAway: 0, criteriaCount: 1)))
    }

    func testRenderedUIWithNothingCloseIsHopeless() {
        XCTAssertTrue(InteractionTools.searchIsHopeless(
            AXSearchProbe(nodesVisited: 200, nearMisses: 0, oneAway: 0, criteriaCount: 1)))
    }

    func testOneAwayKeepsTheFullTimeout() {
        // An element satisfying every criterion but one is probably the target
        // mid-update — the conservative side of the asymmetry.
        XCTAssertFalse(InteractionTools.searchIsHopeless(
            AXSearchProbe(nodesVisited: 200, nearMisses: 5, oneAway: 1, criteriaCount: 2)))
    }

    func testNearMissesAloneDoNotBlockHopeless() {
        // role+title where the role exists but the title never will: every
        // same-role element is a near miss, but with 3+ criteria none is one
        // away. Still hopeless.
        XCTAssertTrue(InteractionTools.searchIsHopeless(
            AXSearchProbe(nodesVisited: 500, nearMisses: 40, oneAway: 0, criteriaCount: 3)))
    }

    func testThresholdBoundary() {
        XCTAssertFalse(InteractionTools.searchIsHopeless(
            AXSearchProbe(nodesVisited: InteractionTools.hopelessMinNodesVisited - 1,
                          nearMisses: 0, oneAway: 0, criteriaCount: 1)))
        XCTAssertTrue(InteractionTools.searchIsHopeless(
            AXSearchProbe(nodesVisited: InteractionTools.hopelessMinNodesVisited,
                          nearMisses: 0, oneAway: 0, criteriaCount: 1)))
    }

    func testGraceIsFarShorterThanTheDefaultTimeout() {
        XCTAssertLessThan(InteractionTools.hopelessGraceSeconds,
                          InteractionTools.defaultFindTimeout / 4)
    }

    // MARK: - criteriaCount

    func testCriteriaCountMatchesSetMatchers() {
        XCTAssertEqual(AXElementSearchCriteria().criteriaCount, 0)
        XCTAssertEqual(AXElementSearchCriteria(role: "AXButton").criteriaCount, 1)
        XCTAssertEqual(
            AXElementSearchCriteria(role: "AXButton", title: "Save", labelContains: "Sav").criteriaCount, 3)
    }

    func testHasAnyMatcherTracksCriteriaCount() {
        XCTAssertFalse(AXElementSearchCriteria().hasAnyMatcher)
        XCTAssertTrue(AXElementSearchCriteria(identifier: "save-button").hasAnyMatcher)
        // `index` disambiguates matches; it is not itself a matcher.
        var indexOnly = AXElementSearchCriteria()
        indexOnly.index = 2
        XCTAssertFalse(indexOnly.hasAnyMatcher)
    }
}
