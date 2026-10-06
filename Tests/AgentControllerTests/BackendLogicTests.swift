import XCTest
@testable import MCPTools
import MCPServer

/// Pure pieces of the web and iOS backends: no browser, no idb.
final class BackendLogicTests: XCTestCase {
    // MARK: - Current-URL comparison (C1)

    func testRequestedUrlEqualsTheFormChromeReports() {
        XCTAssertTrue(CDPNavigation.isCurrent("https://example.com/", requested: URL(string: "https://example.com")!))
        XCTAssertTrue(CDPNavigation.isCurrent("HTTPS://Example.COM/a?x=1", requested: URL(string: "https://example.com/a?x=1")!))
        XCTAssertTrue(CDPNavigation.isCurrent("http://localhost:80/", requested: URL(string: "http://localhost/")!))
        XCTAssertTrue(CDPNavigation.isCurrent("file:///tmp/p.html", requested: URL(string: "file:///tmp/p.html")!))
    }

    func testADifferentPathQueryFragmentOrNilIsNotTheCurrentPage() {
        let requested = URL(string: "https://example.com/app")!
        XCTAssertFalse(CDPNavigation.isCurrent("https://example.com/app/settings", requested: requested))
        XCTAssertFalse(CDPNavigation.isCurrent("https://example.com/app?tab=2", requested: requested))
        XCTAssertFalse(CDPNavigation.isCurrent("https://example.com/app#next", requested: requested))
        XCTAssertFalse(CDPNavigation.isCurrent("about:blank", requested: requested))
        XCTAssertFalse(CDPNavigation.isCurrent(nil, requested: requested))
        XCTAssertFalse(CDPNavigation.isCurrent("https://other.com/app", requested: requested))
    }

    func testAUserTabCountsAsTheRequestedPageOnlyWithinTheSameOriginAndPath() {
        let requested = URL(string: "https://app.test:3000/dash")!
        XCTAssertTrue(CDPNavigation.pageMatches("https://app.test:3000/dash", requested: requested))
        XCTAssertTrue(CDPNavigation.pageMatches("https://app.test:3000/dash/users/4", requested: requested))
        XCTAssertFalse(CDPNavigation.pageMatches("https://app.test:3000/dashboard", requested: requested))
        XCTAssertFalse(CDPNavigation.pageMatches("https://app.test:3001/dash", requested: requested))
        XCTAssertFalse(CDPNavigation.pageMatches("http://app.test:3000/dash", requested: requested))
        XCTAssertFalse(CDPNavigation.pageMatches("", requested: requested))
        // The old prefix test let an empty/blank tab "match" anything.
        XCTAssertFalse(CDPNavigation.pageMatches("about:blank", requested: requested))
    }

    /// A bare origin asks for the site's front page. It used to match ANY page on the site,
    /// so an agent that asked for github.com was handed the user's open private repository.
    func testABareOriginMatchesOnlyTheSitesFrontPage() {
        let bare = URL(string: "https://app.test:3000")!
        XCTAssertTrue(CDPNavigation.pageMatches("https://app.test:3000", requested: bare))
        XCTAssertTrue(CDPNavigation.pageMatches("https://app.test:3000/", requested: bare))
        XCTAssertTrue(CDPNavigation.pageMatches("https://app.test:3000/", requested: URL(string: "https://app.test:3000/")!))
        XCTAssertFalse(CDPNavigation.pageMatches("https://app.test:3000/anything", requested: bare))
        XCTAssertFalse(CDPNavigation.pageMatches("https://app.test:3000/org/private-repo", requested: URL(string: "https://app.test:3000/")!))
        XCTAssertFalse(CDPNavigation.pageMatches("https://other.test:3000/", requested: bare))
    }

    // MARK: - Click point (H7)

    func testClickPointIsTheCentreOfTheQuad() {
        let quad: [Double] = [10, 20, 110, 20, 110, 60, 10, 60]
        let point = CDPGeometry.clickPoint(quads: [quad], viewport: (width: 800, height: 600))
        XCTAssertEqual(point, CDPPoint(x: 60, y: 40))
    }

    func testClickPointStaysInsideTheViewportForAnElementTallerThanIt() {
        let quad: [Double] = [0, -500, 200, -500, 200, 2_000, 0, 2_000]
        let point = CDPGeometry.clickPoint(quads: [quad], viewport: (width: 1000, height: 600))
        XCTAssertEqual(point, CDPPoint(x: 100, y: 300))
    }

    func testClickPointSkipsEmptyAndOffscreenQuads() {
        let empty: [Double] = [5, 5, 5, 5, 5, 5, 5, 5]
        let offscreen: [Double] = [2_000, 2_000, 2_100, 2_000, 2_100, 2_050, 2_000, 2_050]
        let usable: [Double] = [0, 0, 40, 0, 40, 20, 0, 20]
        XCTAssertEqual(CDPGeometry.clickPoint(quads: [empty, offscreen, usable], viewport: (800, 600)), CDPPoint(x: 20, y: 10))
        XCTAssertNil(CDPGeometry.clickPoint(quads: [empty, offscreen], viewport: (800, 600)))
        XCTAssertNil(CDPGeometry.clickPoint(quads: [[1, 2, 3]], viewport: (800, 600)))
    }

    func testQuadsAndViewportAreReadFromCDPResponses() {
        let quads = CDPGeometry.quads(from: .object(["quads": .array([.array([.int(1), .double(2.5), .int(3), .int(4), .int(5), .int(6), .int(7), .int(8)])])]))
        XCTAssertEqual(quads, [[1, 2.5, 3, 4, 5, 6, 7, 8]])
        let metrics = JSONValue.object(["cssLayoutViewport": .object(["clientWidth": .int(1280), "clientHeight": .int(720)])])
        XCTAssertEqual(CDPGeometry.viewport(from: metrics).width, 1280)
        XCTAssertEqual(CDPGeometry.viewport(from: metrics).height, 720)
    }

    // MARK: - Selector (M1)

    private func ref(_ node: Int, _ role: String, _ label: String) -> RoutedRef {
        .cdp(sessionKey: "k", backendNodeId: node, role: role, label: label)
    }

    func testSelectorMatchesRoleAndTextAcrossAXAndChromeSpellings() throws {
        let refs = [ref(1, "button", "Save draft"), ref(2, "textbox", "Name"), ref(3, "button", "Cancel")]
        let byRole = try CDPSelector.parse(.object(["role": .string("AXButton")]))
        XCTAssertEqual(byRole.select(refs, identifiedNodes: nil), [0, 2])
        let field = try CDPSelector.parse(.object(["role": .string("AXTextField")]))
        XCTAssertEqual(field.select(refs, identifiedNodes: nil), [1])
        let contains = try CDPSelector.parse(.object(["role": .string("button"), "labelContains": .string("save")]))
        XCTAssertEqual(contains.select(refs, identifiedNodes: nil), [0])
        let exact = try CDPSelector.parse(.object(["title": .string("cancel")]))
        XCTAssertEqual(exact.select(refs, identifiedNodes: nil), [2])
        let none = try CDPSelector.parse(.object(["labelContains": .string("zzz")]))
        XCTAssertEqual(none.select(refs, identifiedNodes: nil), [])
    }

    func testSelectorIdentifierRestrictsToTheDOMNodesThatCarryIt() throws {
        let refs = [ref(1, "button", "A"), ref(2, "button", "A"), ref(3, "link", "A")]
        let selector = try CDPSelector.parse(.object(["identifier": .string("save")]))
        XCTAssertEqual(selector.select(refs, identifiedNodes: [2]), [1])
        XCTAssertEqual(selector.select(refs, identifiedNodes: []), [])
        let indexed = try CDPSelector.parse(.object(["role": .string("button"), "index": .int(1)]))
        XCTAssertEqual(indexed.select(refs, identifiedNodes: nil), [1])
        let beyond = try CDPSelector.parse(.object(["role": .string("button"), "index": .int(5)]))
        XCTAssertEqual(beyond.select(refs, identifiedNodes: nil), [])
    }

    func testSelectorRefusesCriteriaItCannotAnswer() {
        XCTAssertThrowsError(try CDPSelector.parse(.object(["value": .string("x")])))
        XCTAssertTrue(try CDPSelector.parse(.object([:])).isEmpty)
        XCTAssertTrue(try CDPSelector.parse(.object(["app": .string("https://x.test"), "timeout": .int(3)])).isEmpty)
    }

    func testIdentifierCSSSelectorEscapesQuotesAndBackslashes() {
        let css = CDPSelector.cssSelector(forIdentifier: #"a"b\c"#)
        XCTAssertTrue(css.contains(#"[id="a\"b\\c"]"#), css)
        XCTAssertTrue(css.contains(#"[data-testid="a\"b\\c"]"#), css)
        XCTAssertEqual(css.split(separator: ",").count, 5)
    }

    func testJSExceptionDetailsBecomeAnError() {
        let thrown = JSONValue.object(["exceptionDetails": .object([
            "text": .string("Uncaught"),
            "exception": .object(["description": .string("Error: boom\n    at <anonymous>:1:7")]),
        ])])
        XCTAssertThrowsError(try WebCDPBackend.throwIfException(thrown)) { error in
            XCTAssertEqual(error as? CDPError, .javascript("Error: boom\n    at <anonymous>:1:7"))
        }
        XCTAssertNoThrow(try WebCDPBackend.throwIfException(.object(["result": .object(["value": .int(2)])])))
    }

    // MARK: - Debug-port discovery (M3)

    func testNodeInspectorIsNotABrowser() {
        XCTAssertTrue(ChromeLauncher.isBrowser("Chrome/154.0.8037.98"))
        XCTAssertTrue(ChromeLauncher.isBrowser("HeadlessChrome/154.0.0.0"))
        XCTAssertFalse(ChromeLauncher.isBrowser("node.js/v22.1.0"))
        XCTAssertFalse(ChromeLauncher.isBrowser(""))
    }

    func testCandidatePortsDefaultToNodeFreeListAndHonourTheOverride() {
        XCTAssertEqual(ChromeLauncher.candidatePorts(environment: [:]), [9222, 9333])
        XCTAssertFalse(ChromeLauncher.candidatePorts(environment: [:]).contains(9229))
        XCTAssertEqual(ChromeLauncher.candidatePorts(environment: [ChromeLauncher.debugPortsEnv: "9444, 9555"]), [9444, 9555])
        XCTAssertEqual(ChromeLauncher.candidatePorts(environment: [ChromeLauncher.debugPortsEnv: ""]), [])
    }

    // MARK: - iOS (H4, H5, M8)

    private let sampleDescribeAll = """
    [
      {"AXFrame":"{{0, 0}, {402, 874}}","AXUniqueId":null,"frame":{"y":0,"x":0,"width":402,"height":874},"AXLabel":"Atino","type":"Application","title":null,"AXValue":null,"enabled":true,"role":"AXApplication"},
      {"AXFrame":"{{16, 62}, {44, 44}}","AXUniqueId":"BackButton","frame":{"y":62,"x":16,"width":44,"height":44},"AXLabel":"Matches","type":"Button","title":null,"AXValue":null,"enabled":true,"role":"AXButton"},
      {"AXUniqueId":null,"frame":{"y":124,"x":20,"width":93.6,"height":13.3},"AXLabel":"YOUR PROFILE","type":"Heading","enabled":true,"role":"AXHeading"},
      {"AXUniqueId":null,"frame":{"y":300,"x":0,"width":402,"height":10},"AXLabel":null,"type":"GenericElement","enabled":true,"role":"AXGroup"},
      {"AXUniqueId":null,"frame":{"y":400,"x":20,"width":300,"height":44},"AXLabel":null,"type":"TextField","enabled":true,"role":"AXTextField"}
    ]
    """

    func testDescribeAllKeepsLabelsAndTypesAndDropsStructuralNoise() throws {
        let refs = try IOSSimBackend.parseDescribeAll(udid: "U", data: Data(sampleDescribeAll.utf8))
        XCTAssertEqual(refs.count, 4, "the unlabeled GenericElement is noise")
        guard case .ios(let udid, let identifier, let role, let label, let x, let y, let w, let h) = refs[1] else {
            return XCTFail("expected an ios ref")
        }
        XCTAssertEqual(udid, "U")
        XCTAssertEqual(identifier, "BackButton")
        XCTAssertEqual(role, "Button")
        XCTAssertEqual(label, "Matches")
        XCTAssertEqual([x, y, w, h], [16, 62, 44, 44])
        guard case .ios(_, let headingID, let headingRole, let headingLabel, _, _, _, _) = refs[2] else {
            return XCTFail("expected an ios ref")
        }
        XCTAssertEqual(headingID, "", "no AXUniqueId means no identifier — not an invented UUID")
        XCTAssertEqual(headingRole, "Heading")
        XCTAssertEqual(headingLabel, "YOUR PROFILE")
        guard case .ios(_, _, let fieldRole, _, _, _, _, _) = refs[3] else { return XCTFail("expected an ios ref") }
        XCTAssertEqual(fieldRole, "TextField", "an unlabeled control is still worth targeting")
    }

    func testDescribeAllRejectsNonJSONInsteadOfReturningNothing() {
        XCTAssertThrowsError(try IOSSimBackend.parseDescribeAll(udid: "U", data: Data("idb: companion died".utf8)))
    }

    /// The real idb rejects `idb --udid X ui …` (exit 2) and integer-only coordinates.
    func testIdbArgumentsPutUdidAfterTheSubcommandAndUseIntegers() {
        XCTAssertEqual(IOSSimBackend.describeArguments(udid: "U"), ["ui", "describe-all", "--udid", "U", "--json"])
        XCTAssertEqual(IOSSimBackend.tapArguments(udid: "U", x: 201.0, y: 436.6), ["ui", "tap", "--udid", "U", "201", "437"])
        XCTAssertEqual(IOSSimBackend.textArguments(udid: "U", text: "-hello"), ["ui", "text", "--udid", "U", "--", "-hello"])
    }

    func testTapTargetsTheCentreOfTheElement() {
        let ref = RoutedRef.ios(udid: "U", identifier: "", role: "Button", label: "x", x: 16, y: 62, width: 44, height: 44)
        let centre = IOSSimBackend.center(of: ref)
        XCTAssertEqual(centre?.x, 38)
        XCTAssertEqual(centre?.y, 84)
        XCTAssertNil(IOSSimBackend.center(of: .cdp(sessionKey: "k", backendNodeId: 1, role: "r", label: "l")))
    }

    func testBootedAliasResolvesToTheRealUDID() {
        let one = IOSSimBackend.resolve(requested: "booted", booted: ["AAAA"])
        XCTAssertEqual(one, IOSSimBackend.Resolution(udid: "AAAA"))
        XCTAssertEqual(IOSSimBackend.resolve(requested: "booted", booted: []).ask, .missingAddon)
        let many = IOSSimBackend.resolve(requested: "booted", booted: ["A", "B"])
        XCTAssertEqual(many.ask, .multiInstance)
        XCTAssertEqual(many.udid, "booted")
    }

    func testAConcreteUDIDThatIsNotBootedIsReportedAsNotBooted() {
        let other = IOSSimBackend.resolve(requested: "ZZZZ", booted: ["AAAA"])
        XCTAssertEqual(other.ask, .missingAddon, "another simulator being booted must not make ZZZZ look booted")
        XCTAssertTrue(other.detail?.contains("not booted") == true)
        XCTAssertEqual(IOSSimBackend.resolve(requested: "ZZZZ", booted: []).ask, .missingAddon)
        XCTAssertEqual(IOSSimBackend.resolve(requested: "aaaa", booted: ["AAAA"]), IOSSimBackend.Resolution(udid: "AAAA"))
    }

    func testBootedListIsParsedFromSimctlJSON() {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"udid":"BBBB","state":"Booted","name":"iPhone"},
          {"udid":"AAAA","state":"Booted","name":"iPad"}],
         "com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"CCCC","state":"Shutdown"}]}}
        """
        XCTAssertEqual(IOSSimBackend.parseBooted(Data(json.utf8)), ["AAAA", "BBBB"])
        XCTAssertEqual(IOSSimBackend.parseBooted(Data("garbage".utf8)), [])
    }

    func testRecordExposesTheResolvedUDIDNotTheAlias() {
        var record = CapabilityRecord(target: "booted", backend: .iosSim, reason: "")
        XCTAssertNil(record.resolvedUDID)
        record.extras["udid"] = .string("0DDDC30D-6A6D-42FC-938C-BE6709063D29")
        XCTAssertEqual(record.resolvedUDID, "0DDDC30D-6A6D-42FC-938C-BE6709063D29")
    }
}
