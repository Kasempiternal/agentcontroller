import XCTest
@testable import MCPTools

/// scroll_until_visible used `break` inside a `switch`, which only leaves the switch: once
/// maxScrolls was spent the loop re-ran full tree searches back to back until the deadline.
final class ScrollLoopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testScrollsWhileBothBudgetsRemain() {
        XCTAssertTrue(ScrollTools.canScrollAgain(scrolls: 0, maxScrolls: 20, now: now, deadline: now.addingTimeInterval(5)))
        XCTAssertTrue(ScrollTools.canScrollAgain(scrolls: 19, maxScrolls: 20, now: now, deadline: now.addingTimeInterval(5)))
    }

    func testStopsWhenMaxScrollsIsSpentEvenWithTimeLeft() {
        XCTAssertFalse(ScrollTools.canScrollAgain(scrolls: 20, maxScrolls: 20, now: now, deadline: now.addingTimeInterval(19)))
        XCTAssertFalse(ScrollTools.canScrollAgain(scrolls: 21, maxScrolls: 20, now: now, deadline: now.addingTimeInterval(19)))
    }

    func testStopsAtTheDeadlineEvenWithScrollsLeft() {
        XCTAssertFalse(ScrollTools.canScrollAgain(scrolls: 0, maxScrolls: 20, now: now, deadline: now))
        XCTAssertFalse(ScrollTools.canScrollAgain(scrolls: 3, maxScrolls: 20, now: now, deadline: now.addingTimeInterval(-1)))
    }

    func testZeroMaxScrollsMeansLookOnce() {
        XCTAssertFalse(ScrollTools.canScrollAgain(scrolls: 0, maxScrolls: 0, now: now, deadline: now.addingTimeInterval(20)))
    }

    /// The loop must terminate in exactly maxScrolls+1 looks, however long the deadline.
    func testLoopTerminatesAfterMaxScrollsPlusOneLooks() {
        var looks = 0
        var scrolls = 0
        let deadline = now.addingTimeInterval(20)
        while true {
            looks += 1
            guard ScrollTools.canScrollAgain(scrolls: scrolls, maxScrolls: 5, now: now, deadline: deadline) else { break }
            scrolls += 1
        }
        XCTAssertEqual(looks, 6)
        XCTAssertEqual(scrolls, 5)
    }

    func testVisibilityCarriesTheWheelTarget() {
        XCTAssertNil(ScrollTools.Visibility.visible.center)
        XCTAssertEqual(ScrollTools.Visibility.offscreen(center: CGPoint(x: 5, y: 6)).center, CGPoint(x: 5, y: 6))
        XCTAssertEqual(ScrollTools.Visibility.notFound(center: CGPoint(x: 1, y: 2)).center, CGPoint(x: 1, y: 2))
        XCTAssertNil(ScrollTools.Visibility.notFound(center: nil).center, "no known window frame must stay nil, never a (400,400) guess")
    }
}
