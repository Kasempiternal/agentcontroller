import XCTest
import MCPServer
@testable import AccessibilityEngine

/// `get_element_tree` used to be bounded by depth only, so a wide tree meant tens of
/// thousands of IPC round-trips. The budget is breadth-first and testable on a synthetic tree.
final class TreeBudgetTests: XCTestCase {
    /// A complete tree where node `n` has children `branching*n+1 ... branching*n+branching`.
    private func build(branching: Int, maxDepth: Int, budget: Int, totalNodes: Int = 10_000) -> (JSONValue, reads: Int) {
        var reads = 0
        let tree = AXElementTree.assemble(root: 0, maxDepth: maxDepth, nodeBudget: budget) { (n: Int) in
            reads += 1
            let kids = (1...branching).map { branching * n + $0 }.filter { $0 < totalNodes }
            return (["role": .string("AXGroup"), "id": .int(n)], kids)
        }
        return (tree, reads)
    }

    private func count(_ node: JSONValue) -> Int {
        1 + (node["children"]?.arrayValue ?? []).reduce(0) { $0 + count($1) }
    }

    func testBudgetBoundsReadsAndNodes() {
        let (tree, reads) = build(branching: 10, maxDepth: 50, budget: 200)
        XCTAssertEqual(reads, 200)
        XCTAssertEqual(count(tree), 200)
    }

    func testUnderBudgetTreeIsCompleteAndUnmarked() {
        let (tree, reads) = build(branching: 3, maxDepth: 2, budget: 6_000)
        XCTAssertEqual(reads, 1 + 3 + 9)
        XCTAssertNil(tree["nodeBudgetReached"])
        XCTAssertNil(tree["truncated"])
        XCTAssertEqual(tree["childCount"]?.intValue, 3)
    }

    func testBudgetCutsDeepestLevelsFirst() {
        // Budget 1 + 3 + 9 = 13 admits exactly the top three levels of a 3-ary tree.
        let (tree, _) = build(branching: 3, maxDepth: 10, budget: 13)
        let level2 = (tree["children"]?.arrayValue ?? []).flatMap { $0["children"]?.arrayValue ?? [] }
        XCTAssertEqual(level2.count, 9, "shallow levels must be complete before any deep node is read")
        for node in level2 {
            XCTAssertNil(node["children"], "no level-3 node fits in the budget")
            XCTAssertEqual(node["childCount"]?.intValue, 3, "unexpanded nodes keep their real child count")
            XCTAssertEqual(node["truncated"]?.boolValue, true)
        }
    }

    func testBudgetHitIsReportedOnTheRootWithAHint() {
        let (tree, _) = build(branching: 5, maxDepth: 10, budget: 50)
        XCTAssertEqual(tree["nodeBudgetReached"]?.intValue, 50)
        XCTAssertNotNil(tree["hint"]?.stringValue)
    }

    func testPartiallyExpandedParentKeepsFullChildCountAndFlagsTruncation() {
        // Root reads, then only 2 of its 5 children fit.
        let (tree, reads) = build(branching: 5, maxDepth: 3, budget: 3)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(tree["children"]?.arrayValue?.count, 2)
        XCTAssertEqual(tree["childCount"]?.intValue, 5)
        XCTAssertEqual(tree["truncated"]?.boolValue, true)
    }

    func testChildOrderIsPreserved() {
        let (tree, _) = build(branching: 4, maxDepth: 1, budget: 100)
        let ids = (tree["children"]?.arrayValue ?? []).compactMap { $0["id"]?.intValue }
        XCTAssertEqual(ids, [1, 2, 3, 4])
    }

    func testDepthLimitStillMarksTruncated() {
        let (tree, _) = build(branching: 2, maxDepth: 1, budget: 6_000)
        for child in tree["children"]?.arrayValue ?? [] {
            XCTAssertEqual(child["truncated"]?.boolValue, true)
            XCTAssertEqual(child["childCount"]?.intValue, 2)
            XCTAssertNil(child["children"])
        }
        XCTAssertNil(tree["nodeBudgetReached"], "a depth cut is not a budget cut")
    }
}
