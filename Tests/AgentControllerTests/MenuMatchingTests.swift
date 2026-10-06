import XCTest
@testable import AccessibilityEngine

/// `navigate_menu` used a prefix rule in BOTH directions for every path segment, so
/// `["File", "Close Tab"]` pressed "Close" (the label is a prefix of the target) and an
/// empty segment matched the first item. Each pressed a real, wrong item and reported
/// success. These pin the corrected rules on plain label arrays — no app needed.
final class MenuMatchingTests: XCTestCase {

    private func match(_ name: String, _ labels: [String?], leaf: Bool) -> MenuLabelMatch {
        MenuNavigator.matchLabel(name, in: labels, isLeaf: leaf)
    }

    // MARK: - Leaf: exact only

    func testLeafDoesNotPressAPrefixOfTheRequestedLabel() {
        // The reported bug: "Close Tab" must not resolve to "Close".
        XCTAssertEqual(match("Close Tab", ["New", "Close", "Close All"], leaf: true), .none)
    }

    func testLeafDoesNotPressAnExtensionOfTheRequestedLabel() {
        XCTAssertEqual(match("Clos", ["Close", "Close Tab"], leaf: true), .none)
        XCTAssertEqual(match("Close T", ["Close", "Close Tab"], leaf: true), .none)
    }

    func testLeafPicksTheExactItemAmongPrefixSiblings() {
        let labels: [String?] = ["Close All", "Close", "Close Tab"]
        XCTAssertEqual(match("Close", labels, leaf: true), .match(index: 1))
        XCTAssertEqual(match("Close Tab", labels, leaf: true), .match(index: 2))
    }

    func testEmptyOrBlankSegmentNeverMatches() {
        let labels: [String?] = ["New", "Open"]
        for leaf in [true, false] {
            XCTAssertEqual(match("", labels, leaf: leaf), .none)
            XCTAssertEqual(match("   ", labels, leaf: leaf), .none)
            XCTAssertEqual(match("…", labels, leaf: leaf), .none)
        }
    }

    // MARK: - Normalization

    func testMatchingIgnoresCaseAndSurroundingAndInnerWhitespace() {
        XCTAssertEqual(match("  save   AS ", ["Save As"], leaf: true), .match(index: 0))
        XCTAssertEqual(match("Save As", ["Save\u{00A0}As"], leaf: true), .match(index: 0))
    }

    func testEllipsisFormsAreInterchangeable() {
        let labels: [String?] = ["Save As\u{2026}"]
        XCTAssertEqual(match("Save As...", labels, leaf: true), .match(index: 0))
        XCTAssertEqual(match("Save As\u{2026}", labels, leaf: true), .match(index: 0))
        XCTAssertEqual(match("Save As", labels, leaf: true), .match(index: 0))
        XCTAssertEqual(match("Save As\u{2026}", ["Save As..."], leaf: true), .match(index: 0))
    }

    func testExactEllipsisFormBeatsTheFoldedOne() {
        // "Print" and "Print…" can coexist; the caller's literal choice decides.
        let labels: [String?] = ["Print\u{2026}", "Print"]
        XCTAssertEqual(match("Print", labels, leaf: true), .match(index: 1))
        XCTAssertEqual(match("Print...", labels, leaf: true), .match(index: 0))
    }

    func testSeparatorsAreSkippedAndIndicesAreStable() {
        let labels: [String?] = [nil, "", "Copy", nil, "Paste"]
        XCTAssertEqual(match("Paste", labels, leaf: true), .match(index: 4))
        XCTAssertEqual(match("Copy", labels, leaf: true), .match(index: 2))
    }

    func testDuplicateExactLabelsResolveToTheFirst() {
        XCTAssertEqual(match("Close", ["Close", "Close"], leaf: true), .match(index: 0))
    }

    // MARK: - Intermediate: fuzzy only when unique

    func testIntermediateAcceptsAnUnambiguousAbbreviation() {
        XCTAssertEqual(match("Fi", ["Apple", "Safari", "File", "Edit"], leaf: false), .match(index: 2))
    }

    func testIntermediateFallsBackToContainsWhenNothingStartsWithIt() {
        XCTAssertEqual(match("Rec", ["File", "Open Recent"], leaf: false), .match(index: 1))
    }

    func testIntermediateAmbiguityIsReportedNotGuessed() {
        XCTAssertEqual(match("S", ["Safari", "Settings", "File"], leaf: false), .ambiguous(indices: [0, 1]))
        XCTAssertEqual(match("ile", ["File", "Profile", "Edit"], leaf: false), .ambiguous(indices: [0, 1]))
    }

    func testIntermediateNoLongerMatchesWhenTheTargetIsLongerThanTheLabel() {
        // The old reverse-prefix rule: target "File Menu" starts with label "File".
        XCTAssertEqual(match("File Menu", ["File", "Edit"], leaf: false), .none)
    }

    func testExactBeatsFuzzyAtIntermediateLevels() {
        XCTAssertEqual(match("Edit", ["Edit", "Edit Menu Extras"], leaf: false), .match(index: 0))
    }

    func testLeafNeverFuzzyEvenWhenUnique() {
        XCTAssertEqual(match("Fi", ["File"], leaf: true), .none)
        XCTAssertEqual(match("Fi", ["File"], leaf: false), .match(index: 0))
    }

    // MARK: - Miss messages

    func testNoMatchMessageListsTheAvailableLabels() {
        let miss = MenuMiss(segment: "Close Tab", level: "File", candidates: ["New", "Close"], kind: .noMatch)
        XCTAssertEqual(miss.message, "No item 'Close Tab' in 'File'. Available: 'New', 'Close'.")
    }

    func testMenuBarLevelIsNamedAsTheMenuBar() {
        let miss = MenuMiss(segment: "Fiel", level: nil, candidates: ["File"], kind: .noMatch)
        XCTAssertEqual(miss.message, "No item 'Fiel' in the menu bar. Available: 'File'.")
    }

    func testAmbiguousMessageNamesTheContenders() {
        let miss = MenuMiss(segment: "S", level: nil, candidates: [], kind: .ambiguous(matches: ["Safari", "Settings"]))
        XCTAssertEqual(miss.message, "'S' matches several items in the menu bar: 'Safari', 'Settings'. Use the exact label.")
    }

    func testEmptyLevelSaysSoInsteadOfPrintingAnEmptyList() {
        let miss = MenuMiss(segment: "X", level: "File", candidates: [], kind: .noMatch)
        XCTAssertTrue(miss.message.contains("exposed no items"), miss.message)
    }

    func testLongCandidateListsAreCapped() {
        let labels = (0..<45).map { "Item \($0)" }
        let miss = MenuMiss(segment: "Nope", level: "Big", candidates: labels, kind: .noMatch)
        XCTAssertTrue(miss.message.contains("'Item 29'"))
        XCTAssertFalse(miss.message.contains("'Item 30'"))
        XCTAssertTrue(miss.message.contains("15 more"), miss.message)
    }
}
