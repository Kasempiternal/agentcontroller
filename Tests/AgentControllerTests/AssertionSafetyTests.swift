import XCTest
import MCPServer
@testable import AccessibilityEngine
@testable import MCPTools

/// assert_not_visible used to PASS whenever a search returned nothing — including when the
/// selector had no matcher at all, the app had quit, or the app was hung. These tests pin
/// the rules that make a pass mean "the UI was read and the element was not there".
final class AssertionSafetyTests: XCTestCase {

    // MARK: - Selector must contain a matcher

    private func criteria(_ args: JSONValue) -> AXElementSearchCriteria {
        AXElementSearchCriteria(from: args, maxResults: 1)
    }

    func testMisspelledSelectorKeyIsAnErrorNamingTheTypo() {
        let args: JSONValue = .object(["app": .string("Notes"), "titel": .string("Save")])
        let problem = AssertTools.selectorProblem(tool: "assert_not_visible", args: args, criteria: criteria(args))
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("titel") == true)
        XCTAssertTrue(problem?.contains("assert_not_visible") == true)
        XCTAssertTrue(problem?.contains("titleContains") == true, "must list the valid matcher keys")
    }

    func testNonStringMatcherIsFlaggedAsIgnored() {
        let args: JSONValue = .object(["app": .string("Notes"), "value": .int(3)])
        let problem = AssertTools.selectorProblem(tool: "assert_value", args: args, criteria: criteria(args))
        XCTAssertTrue(problem?.contains("not strings: value") == true, problem ?? "nil")
    }

    func testIndexAloneIsNotASelector() {
        let args: JSONValue = .object(["app": .string("Notes"), "index": .int(0)])
        XCTAssertNotNil(AssertTools.selectorProblem(tool: "assert_visible", args: args, criteria: criteria(args)))
    }

    func testRealMatcherPassesTheGuard() {
        let args: JSONValue = .object(["app": .string("Notes"), "labelContains": .string("Save")])
        XCTAssertNil(AssertTools.selectorProblem(tool: "assert_not_visible", args: args, criteria: criteria(args)))
    }

    // MARK: - When may assert_not_visible pass

    private let trustworthy = AXSearchProbe(nodesVisited: 120, nearMisses: 0, oneAway: 0, criteriaCount: 1)

    func testOneEmptyWalkIsNotAPass() {
        var judge = NotVisibleJudge()
        XCTAssertFalse(judge.record(.absent))
        XCTAssertTrue(judge.record(.absent))
    }

    func testAnInterveningHitResetsTheConfirmation() {
        var judge = NotVisibleJudge()
        XCTAssertFalse(judge.record(.absent))
        XCTAssertFalse(judge.record(.present))
        XCTAssertFalse(judge.record(.absent))
        XCTAssertTrue(judge.record(.absent))
    }

    func testInconclusiveWalksNeverPassHoweverManyThereAre() {
        var judge = NotVisibleJudge()
        for _ in 0..<10 { XCTAssertFalse(judge.record(.inconclusive("hung"))) }
        XCTAssertEqual(judge.consecutiveAbsent, 0)
    }

    func testAnInconclusiveWalkBreaksTheStreak() {
        var judge = NotVisibleJudge()
        _ = judge.record(.absent)
        XCTAssertFalse(judge.record(.inconclusive("hung")))
        XCTAssertFalse(judge.record(.absent))
    }

    func testObserveTreatsADeadProcessAsInconclusive() {
        let observation = NotVisibleJudge.observe(found: false, probe: trustworthy, processAlive: false)
        guard case .inconclusive(let reason) = observation else { return XCTFail("\(observation)") }
        XCTAssertTrue(reason.contains("exited"))
    }

    func testObserveTreatsAWalkThatSawNothingAsInconclusive() {
        for visited in 0...1 {
            let probe = AXSearchProbe(nodesVisited: visited, nearMisses: 0, oneAway: 0, criteriaCount: 1)
            guard case .inconclusive = NotVisibleJudge.observe(found: false, probe: probe, processAlive: true) else {
                return XCTFail("a walk that visited \(visited) node(s) must not count as absence")
            }
        }
    }

    func testObserveTreatsAnUnreadableRootAsInconclusive() {
        // A hung app: the root read fails, but the walk still "visited" the root and
        // possibly windows reported by a cached parent.
        let probe = AXSearchProbe(nodesVisited: 5, nearMisses: 0, oneAway: 0, criteriaCount: 1,
                                  unreadableNodes: 5, rootUnreadable: true)
        guard case .inconclusive(let reason) = NotVisibleJudge.observe(found: false, probe: probe, processAlive: true) else {
            return XCTFail("unreadable root must be inconclusive")
        }
        XCTAssertTrue(reason.contains("did not answer"))
    }

    func testObserveRequiresMostOfTheTouchedTreeToBeReadable() {
        let mostlyUnreadable = AXSearchProbe(nodesVisited: 100, nearMisses: 0, oneAway: 0, criteriaCount: 1,
                                             unreadableNodes: 30)
        let barelyUnreadable = AXSearchProbe(nodesVisited: 100, nearMisses: 0, oneAway: 0, criteriaCount: 1,
                                             unreadableNodes: 20)
        XCTAssertEqual(NotVisibleJudge.observe(found: false, probe: barelyUnreadable, processAlive: true), .absent)
        guard case .inconclusive = NotVisibleJudge.observe(found: false, probe: mostlyUnreadable, processAlive: true) else {
            return XCTFail("30% unreadable is not a trustworthy miss")
        }
    }

    func testObserveSaysPresentWheneverTheElementWasFound() {
        XCTAssertEqual(NotVisibleJudge.observe(found: true, probe: .empty, processAlive: true), .present)
    }

    func testConclusiveProbeBoundary() {
        XCTAssertFalse(AXSearchProbe.empty.isConclusive)
        XCTAssertTrue(AXSearchProbe(nodesVisited: 2, nearMisses: 0, oneAway: 0, criteriaCount: 1).isConclusive)
    }

    // MARK: - assert_value checked

    private func snapshot(checked: Bool?) -> AssertValueSnapshot {
        AssertValueSnapshot(found: true, valueString: "hello", title: nil, label: nil,
                            isEnabled: true, isFocused: false, checked: checked)
    }

    private func failure(_ snap: AssertValueSnapshot, checked: Bool) -> String? {
        AssertTools.evaluate(snap: snap, equals: nil, contains: nil, enabled: nil, focused: nil, checked: checked)
    }

    func testCheckedFalseDoesNotPassOnAnElementWithNoCheckedState() {
        let message = failure(snapshot(checked: nil), checked: false)
        XCTAssertNotNil(message, "an element with no checked state is not 'unchecked'")
        XCTAssertTrue(message?.contains("no checked state") == true)
        XCTAssertNotNil(failure(snapshot(checked: nil), checked: true))
    }

    func testCheckedStillMatchesRealToggleState() {
        XCTAssertNil(failure(snapshot(checked: true), checked: true))
        XCTAssertNil(failure(snapshot(checked: false), checked: false))
        XCTAssertNotNil(failure(snapshot(checked: false), checked: true))
        XCTAssertTrue(failure(snapshot(checked: true), checked: false)?.contains("got true") == true)
    }
}

/// Searches rooted at an application element used to match closed menu-bar items.
final class MenuScopeTests: XCTestCase {

    func testMenuBarIsSkippedUnlessAskedFor() {
        XCTAssertFalse(AXElementSearchCriteria(title: "Save").walksMenuBar)
        XCTAssertFalse(AXElementSearchCriteria(role: "AXButton", title: "Save").walksMenuBar)
        XCTAssertTrue(AXElementSearchCriteria(title: "Save", includeMenus: true).walksMenuBar)
    }

    func testAskingForAMenuRoleImpliesTheMenuBar() {
        for role in ["AXMenuItem", "AXMenuBarItem", "AXMenu", "AXMenuButton"] {
            XCTAssertTrue(AXElementSearchCriteria(role: role).walksMenuBar, role)
        }
        XCTAssertFalse(AXElementSearchCriteria(role: "AXPopUpButton").walksMenuBar)
    }

    func testIncludeMenusArgumentReachesTheCriteria() {
        let on = AXElementSearchCriteria(from: .object(["title": .string("Save"), "includeMenus": .bool(true)]), maxResults: 1)
        let off = AXElementSearchCriteria(from: .object(["title": .string("Save")]), maxResults: 1)
        XCTAssertTrue(on.includeMenus)
        XCTAssertFalse(off.includeMenus)
    }

    func testIncludeMenusIsAdvertisedAsABoolean() {
        XCTAssertEqual(SelectorSchema.properties["includeMenus"]?["type"]?.stringValue, "boolean")
    }

    // MARK: - Attributes fetched per search

    func testOnlyCriteriaThatNeedAttributesFetchThem() {
        let button = AXElementSearch.matchAttributes(for: AXElementSearchCriteria(role: "AXButton", titleContains: "Save"))
        XCTAssertFalse(button.contains("AXValue"), "full text-area contents must not cross IPC for a button search")
        XCTAssertFalse(button.contains("AXDescription"))
        XCTAssertFalse(button.contains("AXHelp"))
        for needed in ["AXRole", "AXTitle", "AXIdentifier", "AXChildren"] {
            XCTAssertTrue(button.contains(needed), needed)
        }

        let byValue = AXElementSearch.matchAttributes(for: AXElementSearchCriteria(value: "42"))
        XCTAssertTrue(byValue.contains("AXValue"))
        XCTAssertFalse(byValue.contains("AXHelp"))

        let byDescription = AXElementSearch.matchAttributes(for: AXElementSearchCriteria(descriptionContains: "x"))
        XCTAssertTrue(byDescription.contains("AXDescription"))
        XCTAssertFalse(byDescription.contains("AXValue"))

        let byLabel = AXElementSearch.matchAttributes(for: AXElementSearchCriteria(labelContains: "x"))
        for needed in ["AXValue", "AXDescription", "AXHelp", "AXTitle"] {
            XCTAssertTrue(byLabel.contains(needed), needed)
        }
    }
}
