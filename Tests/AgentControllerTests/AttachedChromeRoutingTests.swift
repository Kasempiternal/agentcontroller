import XCTest
import MCPServer
@testable import MCPTools
@testable import AccessibilityEngine

/// 3.1.2: a page for a Chrome that publishes a debug port goes in as a background tab over CDP.
/// 3.1.1 handed it to LaunchServices: Chrome came to the front on every call and every call left
/// one more tab (release Chrome, 15/10/2026). None of these tests opens a browser.
final class AttachedChromeRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { BrowserNavigator.refuseLaunchServices = true }
    }

    override func tearDown() {
        AttachedChrome.resolverOverride = nil
        MainActor.assumeIsolated { BrowserNavigator.refuseLaunchServices = false }
        super.tearDown()
    }

    private func attachChrome(port: UInt16 = 9333) throws {
        try XCTSkipUnless(BrowserResolver.named("chrome") != nil, "Google Chrome is not installed")
        AttachedChrome.resolverOverride = { browser in browser.bundleId == "com.google.Chrome" ? port : nil }
    }

    private func rewritten(_ prepared: BrowserRouting.Prepared, file: StaticString = #filePath, line: UInt = #line) -> JSONValue? {
        guard case .rewritten(let args, _) = prepared else {
            XCTFail("expected the call to be rewritten, got \(prepared)", file: file, line: line)
            return nil
        }
        return args
    }

    func testASnapshotOfAChromePageGoesToTheDebugPortNotLaunchServices() async throws {
        try attachChrome()
        let before = await MainActor.run { BrowserNavigator.launchServicesOpens }
        let prepared = try await BrowserRouting.prepare(
            name: "snapshot", arguments: .object(["app": .string("chrome"), "url": .string("https://example.com/keys")]))
        let args = try XCTUnwrap(rewritten(prepared))
        XCTAssertEqual(args["url"]?.stringValue, "https://example.com/keys")
        XCTAssertEqual(args[BrowserRouting.attachedPortKey]?.intValue, 9333)
        XCTAssertEqual(args["headless"]?.boolValue, false)
        XCTAssertNil(args["app"], "the page is the identity now, not the app")
        let after = await MainActor.run { BrowserNavigator.launchServicesOpens }
        XCTAssertEqual(after, before, "the page was handed to LaunchServices")

        let identity = try XCTUnwrap(BackendRouter.identity(from: args))
        XCTAssertEqual(identity.kind, .url)
        XCTAssertEqual(identity.attachedPort, 9333)
        XCTAssertFalse(identity.headless)
    }

    func testEveryNavigatingToolTakesTheSameRoute() async throws {
        try attachChrome()
        for tool in BrowserRouting.navigatingTools {
            let prepared = try await BrowserRouting.prepare(
                name: tool, arguments: .object(["app": .string("Google Chrome"), "url": .string("https://example.com/")]))
            XCTAssertEqual(rewritten(prepared)?[BrowserRouting.attachedPortKey]?.intValue, 9333, tool)
        }
    }

    /// An action naming the page acts on the tab already there; it never opens one.
    func testAClickNamingAChromePageStaysOnThePageHint() async throws {
        try attachChrome()
        let prepared = try await BrowserRouting.prepare(
            name: "click",
            arguments: .object(["app": .string("chrome"), "url": .string("https://example.com/keys"), "labelContains": .string("Save")]))
        let args = try XCTUnwrap(rewritten(prepared))
        XCTAssertEqual(args["app"]?.stringValue, "com.google.Chrome")
        XCTAssertEqual(args[BrowserRouting.pageURLKey]?.stringValue, "https://example.com/keys")
        XCTAssertNil(args[BrowserRouting.attachedPortKey])
        XCTAssertNil(args["url"])
    }

    func testOpenURLInChromeBecomesABackgroundTab() async throws {
        try attachChrome()
        let prepared = await BrowserRouting.prepareOpenURL(.object(["browser": .string("chrome"), "url": .string("https://example.com/")]))
        let args = try XCTUnwrap(rewritten(prepared))
        XCTAssertEqual(args[BrowserRouting.attachedPortKey]?.intValue, 9333)
        XCTAssertNil(args["browser"])
    }

    func testOpenURLKeepsItsOwnPathWhenItShouldNotBeABackgroundTab() async throws {
        try attachChrome()
        let cases: [[String: JSONValue]] = [
            ["browser": .string("chrome"), "url": .string("https://example.com/"), "foreground": .bool(true)],
            ["browser": .string("chrome"), "url": .string("https://example.com/"), "headless": .bool(true)],
            ["url": .string("myapp://route")],
            ["browser": .string("safari"), "url": .string("https://example.com/")],
        ]
        for arguments in cases {
            let prepared = await BrowserRouting.prepareOpenURL(.object(arguments))
            guard case .unchanged = prepared else { return XCTFail("\(arguments) was rewritten: \(prepared)") }
        }
    }

    func testNoDebugPortMeansNoRewriteForOpenURL() async throws {
        try XCTSkipUnless(BrowserResolver.named("chrome") != nil, "Google Chrome is not installed")
        AttachedChrome.resolverOverride = { _ in nil }
        let prepared = await BrowserRouting.prepareOpenURL(.object(["browser": .string("chrome"), "url": .string("https://example.com/")]))
        guard case .unchanged = prepared else { return XCTFail("rewritten without a debug port: \(prepared)") }
    }

    /// The router's private keys never come from a client: `_cdpPort` would pin the CDP backend to
    /// any local port.
    func testPrivateKeysFromAClientAreDropped() {
        let sent: JSONValue = .object([
            "url": .string("https://example.com/"), BrowserRouting.attachedPortKey: .int(1234),
            BrowserRouting.pageURLKey: .string("https://example.com/other"),
        ])
        let kept = BrowserRouting.strippingPrivateKeys(sent)
        XCTAssertNil(kept[BrowserRouting.attachedPortKey])
        XCTAssertNil(kept[BrowserRouting.pageURLKey])
        XCTAssertEqual(kept["url"]?.stringValue, "https://example.com/")
        let plain: JSONValue = .object(["app": .string("Safari")])
        XCTAssertEqual(BrowserRouting.strippingPrivateKeys(plain), plain)
    }

    /// The port must belong to the browser the call named (Edge on 9222 is not Chrome), and a
    /// Chrome running from its code-sign clone is still Chrome.
    func testThePortMustBelongToTheNamedBrowsersBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ac-bundles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ relative: String, id: String) throws -> String {
            let contents = root.appendingPathComponent(relative).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            return contents.appendingPathComponent("MacOS/Browser").path
        }
        let clone = try bundle("com.google.Chrome.code_sign_clone/code_sign_clone.Ab12/Google Chrome.app.bundle", id: "com.google.Chrome")
        let edge = try bundle("Microsoft Edge.app", id: "com.microsoft.edgemac")
        XCTAssertEqual(AttachedChrome.bundleIdentifier(ofExecutable: clone), "com.google.Chrome")
        XCTAssertEqual(AttachedChrome.bundleIdentifier(ofExecutable: edge), "com.microsoft.edgemac")
        XCTAssertNil(AttachedChrome.bundleIdentifier(ofExecutable: "/usr/bin/python3"))
    }

    func testSafariReusesOnlyTheSameDocument() throws {
        let page = try XCTUnwrap(URL(string: "https://dash.example.com/keys?team=1"))
        XCTAssertTrue(BrowserNavigator.sameDocument("https://dash.example.com/keys?team=1", page))
        XCTAssertTrue(BrowserNavigator.sameDocument("https://DASH.example.com/keys/?team=1#new", page))
        XCTAssertFalse(BrowserNavigator.sameDocument("https://dash.example.com/keys/add?team=1", page), "a page under the path is another page")
        XCTAssertFalse(BrowserNavigator.sameDocument("https://dash.example.com/keys?team=2", page))
        XCTAssertFalse(BrowserNavigator.sameDocument("http://dash.example.com/keys?team=1", page))
        XCTAssertFalse(BrowserNavigator.sameDocument(nil, page))
        let root = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertTrue(BrowserNavigator.sameDocument("https://example.com/", root))
        XCTAssertFalse(BrowserNavigator.sameDocument("https://example.com/inbox", root), "the site root is not every page on it")
    }

    /// A browser that comes forward right after this server handed it a page is undone, even while
    /// the user is typing and even if it was never driven, and the agent is told it was not its doing.
    func testAHandOffActivationIsUndoneAndAttributedToTheServer() {
        XCTAssertTrue(FocusWatcher.isStolenFocus(
            activatedPID: 42, drivenPIDs: [], expected: false, guardEnabled: true,
            secondsSinceLastDispatch: 0.2, secondsSinceUserInput: 0.1, handedOff: true))
        XCTAssertFalse(FocusWatcher.isStolenFocus(
            activatedPID: 42, drivenPIDs: [], expected: false, guardEnabled: false,
            secondsSinceLastDispatch: 0.2, handedOff: true), "Focus Guard off")
        XCTAssertFalse(FocusWatcher.isStolenFocus(
            activatedPID: 42, drivenPIDs: [], expected: true, guardEnabled: true,
            secondsSinceLastDispatch: 0.2, handedOff: true), "foreground:true asked for it")
        let message = FocusWatcher.handoffMessage(appName: "Google Chrome")
        XCTAssertTrue(message.contains("this server handed it a page"))
        XCTAssertFalse(message.contains("outside this server"))
    }
}
