import XCTest
import MCPServer
#if canImport(Darwin)
import Darwin
#endif
@testable import MCPTools

/// What keeps the agent's web calls out of the user's own browser: a `headless:true` call
/// never attaches to a Chrome the user has open (S1), a page opened in their Chrome is found
/// by its URL instead of "the first tab" (A3), the user is told when the tab landed in their
/// view (S3), and the pid file of another running copy of the app is not ours to touch (S9).
final class BrowserSafetyTests: XCTestCase {

    private var savedEnvironment: [String: String?] = [:]

    private func setEnvironment(_ values: [String: String]) {
        for (key, value) in values {
            savedEnvironment[key] = .some(ProcessInfo.processInfo.environment[key])
            setenv(key, value, 1)
        }
    }

    override func tearDown() {
        for (key, old) in savedEnvironment {
            if let old { setenv(key, old, 1) } else { unsetenv(key) }
        }
        savedEnvironment.removeAll()
        super.tearDown()
    }

    private func page(_ id: String, _ url: String) -> ChromeLauncher.PageTarget {
        ChromeLauncher.PageTarget(id: id, url: url, webSocketDebuggerURL: URL(string: "ws://127.0.0.1:1/\(id)")!)
    }

    // MARK: - S1: headless means the private browser

    func testHeadlessNeverTouchesTheUsersDebugPort() async throws {
        let userChrome = try FakeDebugPortServer()
        try userChrome.start()
        defer { userChrome.stop() }
        setEnvironment([
            ChromeLauncher.debugPortsEnv: "\(userChrome.port)",
            "AGENTCONTROLLER_CHROME": "/nonexistent/agentcontroller-test-chrome",
        ])

        let page = URL(string: "https://example.test/")!
        let isolated = TargetIdentity(raw: page.absoluteString).routed(pageHint: nil, headless: true)
        do {
            _ = try await WebCDPBackend.shared.snapshot(identity: isolated, interactiveOnly: true)
            XCTFail("with no Chromium installed there is nothing for a headless call to use")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No Chromium browser found"), "\(error)")
        }
        XCTAssertEqual(userChrome.connections, 0, "a headless:true call connected to the user's Chrome")

        // The control: without the flag the same call does look for (and find) that Chrome.
        _ = try? await WebCDPBackend.shared.snapshot(
            identity: TargetIdentity(raw: page.absoluteString), interactiveOnly: true)
        XCTAssertGreaterThan(userChrome.requests, 0, "the unflagged call should have attached to the debug port")
        await WebCDPBackend.shared.shutdown()
    }

    func testAnExplicitHeadlessBrowserChoiceCarriesTheFlagDownstream() throws {
        let rewritten = BrowserRouting.headlessArguments(
            .object(["app": .string("https://example.test/"), "browser": .string("headless")]),
            page: URL(string: "https://example.test/")!)
        XCTAssertEqual(rewritten["headless"]?.boolValue, true)
        XCTAssertNil(rewritten["app"])
        let identity = try XCTUnwrap(BackendRouter.identity(from: rewritten))
        XCTAssertTrue(identity.headless)
        XCTAssertEqual(identity.kind, .url)
    }

    func testAnAdoptedUsersTabIsNeverNavigated() {
        let wanted = URL(string: "https://app.test/dash")!
        XCTAssertEqual(CDPNavigation.reopenAction(adopted: true, currentURL: "https://app.test/dash", requested: wanted), .keep)
        XCTAssertEqual(CDPNavigation.reopenAction(adopted: true, currentURL: "https://mail.test/inbox", requested: wanted), .newTab,
                       "the user's tab moved on: the page goes in a tab of its own")
        XCTAssertEqual(CDPNavigation.reopenAction(adopted: false, currentURL: "https://mail.test/inbox", requested: wanted), .navigate)
        XCTAssertEqual(CDPNavigation.reopenAction(adopted: false, currentURL: "https://app.test/dash", requested: wanted), .keep)
        XCTAssertEqual(CDPNavigation.reopenAction(adopted: true, currentURL: nil, requested: wanted), .newTab)
    }

    func testHeadlessAndAttachedSessionsForTheSameURLAreSeparate() {
        let url = "https://example.test/"
        let attached = TargetIdentity(raw: url)
        let isolated = TargetIdentity(raw: url).routed(pageHint: nil, headless: true)
        XCTAssertNotEqual(WebCDPBackend.key(for: attached), WebCDPBackend.key(for: isolated))
    }

    // MARK: - A3: the page a rewritten call is about

    func testTheBrowserRewriteKeepsThePageURLOutOfBandAndOutOfTheIdentity() throws {
        let browser = BrowserTarget(bundleId: "com.google.Chrome", name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        let page = URL(string: "https://example.test/docs")!
        let rewritten = BrowserRouting.browserArguments(
            .object(["app": .string("chrome:https://example.test/docs"), "url": .string(page.absoluteString)]),
            browser: browser, page: page)
        XCTAssertEqual(rewritten["app"]?.stringValue, "com.google.Chrome")
        XCTAssertNil(rewritten["url"], "the page leaves the arguments so downstream drives the app")
        XCTAssertEqual(rewritten[BrowserRouting.pageURLKey]?.stringValue, page.absoluteString)

        let identity = try XCTUnwrap(BackendRouter.identity(from: rewritten))
        XCTAssertEqual(identity.kind, .application)
        XCTAssertNil(identity.url, "the hint selects a tab; it must never become a navigation target")
        XCTAssertEqual(identity.pageHint, page)
        XCTAssertFalse(identity.headless)
    }

    func testTwoPagesInTheSameChromeAreTwoSessions() {
        let chrome = TargetIdentity(raw: "com.google.Chrome")
        let a = chrome.routed(pageHint: URL(string: "https://a.test/"), headless: false)
        let b = chrome.routed(pageHint: URL(string: "https://b.test/"), headless: false)
        XCTAssertNotEqual(WebCDPBackend.key(for: a), WebCDPBackend.key(for: b))
        XCTAssertNotEqual(WebCDPBackend.key(for: a), WebCDPBackend.key(for: chrome))
        XCTAssertEqual(WebCDPBackend.key(for: a), WebCDPBackend.key(for: chrome.routed(pageHint: URL(string: "https://a.test/"), headless: false)))
    }

    func testTheHintPicksTheTabOnThatPageNotTheFirstOne() {
        let tabs = [
            page("mail", "https://mail.test/inbox"),
            page("docs-sub", "https://docs.test/guide/intro"),
            page("docs", "https://docs.test/guide"),
        ]
        XCTAssertEqual(CDPNavigation.tab(in: tabs, for: URL(string: "https://docs.test/guide")!)?.id, "docs", "an exact match beats one below it")
        XCTAssertEqual(CDPNavigation.tab(in: Array(tabs.prefix(2)), for: URL(string: "https://docs.test/guide")!)?.id, "docs-sub")
    }

    func testNoTabOnThePageIsAnAnswerNotAFallbackToTheFirstTab() {
        let tabs = [page("mail", "https://mail.test/inbox"), page("blank", "about:blank")]
        XCTAssertNil(CDPNavigation.tab(in: tabs, for: URL(string: "https://docs.test/guide")!))
    }

    // MARK: - S3: the tab landed in the user's view

    func testTheNoticeSaysWhenTheBrowserWasFrontmost() {
        let page = URL(string: "https://example.test/")!
        let loaded = BrowserNavigator.Outcome(pid: 1, loaded: true, pageURL: page.absoluteString, waitedMs: 120, wasFrontmost: false)
        let plain = BrowserRouting.navigationNotice(page: page, browser: "Safari", outcome: loaded)
        XCTAssertEqual(plain, "Opened https://example.test/ in Safari (background, loaded in 120ms).")

        var inView = loaded
        inView.wasFrontmost = true
        let notice = BrowserRouting.navigationNotice(page: page, browser: "Safari", outcome: inView)
        XCTAssertTrue(notice.hasPrefix(plain), notice)
        XCTAssertTrue(notice.hasSuffix("Safari was frontmost — the new tab is in the user's view; prefer driving it only while the user isn't using it."), notice)
    }

    // MARK: - S9: the pid file belongs to whoever wrote it

    private func profile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ac-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setEnvironment(["AGENTCONTROLLER_CDP_PROFILE": dir.path])
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testOnlyAPidFileThisProcessWroteForThatChromeIsRemoved() throws {
        _ = try profile()
        let pidFile = ChromeLauncher.pidFile

        try "4242 \(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
        ChromeLauncher.removePIDFile(ifFor: 9999)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "another Chrome's record")

        try "4242 \(getppid())".write(to: pidFile, atomically: true, encoding: .utf8)
        ChromeLauncher.removePIDFile(ifFor: 4242)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "another instance's record")

        try "4242 \(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
        ChromeLauncher.removePIDFile(ifFor: 4242)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path), "our own record is ours to remove")
    }

    func testALaunchThatNeverOpensAPortLeavesAnotherInstancesPidFileAlone() async throws {
        let dir = try profile()
        let fakeChrome = dir.appendingPathComponent("fake-chrome.sh")
        try "#!/bin/sh\nexit 3\n".write(to: fakeChrome, atomically: true, encoding: .utf8)
        chmod(fakeChrome.path, 0o755)
        setEnvironment(["AGENTCONTROLLER_CHROME": fakeChrome.path])

        // Another running copy of the app (our parent stands in for it) owns this profile.
        let theirs = "4242 \(getppid())"
        try theirs.write(to: ChromeLauncher.pidFile, atomically: true, encoding: .utf8)

        do {
            _ = try await ChromeLauncher.launchOwned(headless: true)
            XCTFail("a Chrome that exits at once cannot have opened a DevTools port")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("failed to start"), "\(error)")
        }
        XCTAssertEqual(try? String(contentsOf: ChromeLauncher.pidFile, encoding: .utf8), theirs,
                       "the failed launch overwrote or deleted the other instance's pid file")
    }
}
