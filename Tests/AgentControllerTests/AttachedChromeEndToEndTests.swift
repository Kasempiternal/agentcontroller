import XCTest
import MCPServer
#if canImport(Darwin)
import Darwin
#endif
@testable import MCPTools
import PortOwnership

/// A stand-in for the USER'S Chrome: a separate headless Chromium with its own profile and a
/// debug port the backend is pointed at, so every call attaches instead of using the browser
/// this app owns. Off by default (launches a browser): run with
/// `AGENTCONTROLLER_E2E=1 swift test --filter AttachedChromeEndToEndTests`.
final class AttachedChromeEndToEndTests: XCTestCase {
    private var chrome: Process?
    private var port: UInt16 = 0
    private var workDir: URL!
    private var saved: [String: String?] = [:]

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTCONTROLLER_E2E"] == "1",
                          "set AGENTCONTROLLER_E2E=1 to launch a real Chromium")
        // A page that misses the test Chrome must fail, never land in this Mac's real browsers.
        MainActor.assumeIsolated { BrowserNavigator.refuseLaunchServices = true }
        let binary = try XCTUnwrap(ChromeLauncher.findBinary(), "no Chromium browser installed")

        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("ac-attached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let probe = try SilentTCPServer()
        try probe.start()
        port = probe.port
        probe.stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--headless=new", "--remote-debugging-port=\(port)",
            "--user-data-dir=\(workDir.appendingPathComponent("user-profile").path)",
            "--no-first-run", "--no-default-browser-check", "about:blank",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        chrome = process

        for key in [ChromeLauncher.debugPortsEnv, "AGENTCONTROLLER_CDP_PROFILE", "AGENTCONTROLLER_CONSENT_PATH"] {
            saved[key] = .some(ProcessInfo.processInfo.environment[key])
        }
        setenv(ChromeLauncher.debugPortsEnv, "\(port)", 1)
        setenv("AGENTCONTROLLER_CDP_PROFILE", workDir.appendingPathComponent("owned-profile").path, 1)
        setenv("AGENTCONTROLLER_CONSENT_PATH", workDir.appendingPathComponent("consent.json").path, 1)

        let up = expectation(description: "debug port answers")
        Task {
            for _ in 0..<100 {
                if await ChromeLauncher.browserName(port: self.port) != nil { up.fulfill(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        wait(for: [up], timeout: 15)
    }

    override func tearDown() {
        MainActor.assumeIsolated { BrowserNavigator.refuseLaunchServices = false }
        let done = DispatchSemaphore(value: 0)
        Task {
            await WebCDPBackend.shared.shutdown()
            await ProbeCache.shared.reset()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        if let chrome, chrome.isRunning { ChromeLauncher.terminateBlocking(pid: chrome.processIdentifier) }
        for (key, old) in saved {
            if let old { setenv(key, old, 1) } else { unsetenv(key) }
        }
        saved.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func writePage(_ name: String, button: String) throws -> String {
        let url = workDir.appendingPathComponent("\(name).html")
        try "<!doctype html><title>\(name)</title><button>\(button)</button>".write(to: url, atomically: true, encoding: .utf8)
        return url.absoluteString
    }

    /// A tab the "user" already had open.
    @discardableResult
    private func userOpens(_ url: String) async throws -> ChromeLauncher.PageTarget {
        let tab = try await ChromeLauncher.newPage(port: port, url: url)
        for _ in 0..<50 {
            if let page = try await ChromeLauncher.listPages(port: port).first(where: { $0.id == tab.id }), page.url == url {
                return page
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("Chrome never reported \(url)")
    }

    private func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        await ProbeCache.shared.reset()
        let routed = await BackendRouter.dispatch(name: name, arguments: .object(args))
        return try XCTUnwrap(routed, "\(name) was not routed")
    }

    private func text(_ result: JSONValue) -> String {
        result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    // MARK: - A3 / S1

    /// The page was opened by the browser router; the call that follows names only the app.
    /// The first tab Chrome lists is somebody else's.
    func testASnapshotOfThePageThatWasJustOpenedReadsThatTabNotTheFirstOne() async throws {
        let alpha = try writePage("alpha", button: "Alpha only")
        let beta = try writePage("beta", button: "Beta only")
        let gamma = try writePage("gamma", button: "Gamma decoy")
        // Chrome lists the most recently opened tab first, so the decoy is what "the first
        // tab" would be.
        try await userOpens(alpha)
        try await userOpens(beta)
        try await userOpens(gamma)
        let listed = try await ChromeLauncher.listPages(port: port)
        XCTAssertEqual(listed.first?.url, gamma, "fixture assumption: the newest tab is listed first")

        let rewritten = BrowserRouting.browserArguments(
            .object(["app": .string("chrome"), "url": .string(beta)]),
            browser: BrowserTarget(bundleId: "com.google.Chrome", name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
            page: URL(string: beta)!)
        let snapshot = text(try await call("snapshot", rewritten.objectValue ?? [:]))
        XCTAssertTrue(snapshot.contains("Beta only"), snapshot)
        XCTAssertFalse(snapshot.contains("Gamma decoy") || snapshot.contains("Alpha only"), "read the wrong tab: \(snapshot)")

        // A second page in the same Chrome is a session of its own, not the first one reused.
        let other = BrowserRouting.browserArguments(
            .object(["app": .string("chrome"), "url": .string(alpha)]),
            browser: BrowserTarget(bundleId: "com.google.Chrome", name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
            page: URL(string: alpha)!)
        let second = text(try await call("snapshot", other.objectValue ?? [:]))
        XCTAssertTrue(second.contains("Alpha only"), second)
        XCTAssertFalse(second.contains("Beta only"), second)
    }

    /// 3.1.0: after a page was opened by url, a call that names only the browser means THAT
    /// page. It used to get the first unclaimed tab — never the one just opened, because that
    /// one is claimed by its own session — so `read_all_text {app:"Google Chrome"}` after
    /// opening App Store Connect's keys page read the user's Business tab instead.
    func testABareBrowserCallFollowsThePageTheAgentJustDrove() async throws {
        let beta = try writePage("beta", button: "Beta only")
        let gamma = try writePage("gamma", button: "Gamma decoy")
        try await userOpens(beta)
        try await userOpens(gamma)

        let rewritten = BrowserRouting.browserArguments(
            .object(["app": .string("chrome"), "url": .string(beta)]),
            browser: BrowserTarget(bundleId: "com.google.Chrome", name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
            page: URL(string: beta)!)
        let first = text(try await call("snapshot", rewritten.objectValue ?? [:]))
        XCTAssertTrue(first.contains("Beta only"), first)

        let waitsBefore = await WebCDPBackend.shared.settleRounds
        let bare = text(try await call("snapshot", ["app": .string("com.google.Chrome")]))
        let waitsAfter = await WebCDPBackend.shared.settleRounds
        XCTAssertEqual(waitsAfter, waitsBefore, "a settled page is not waited on again")
        XCTAssertTrue(bare.contains("Beta only"), "a bare browser call read another tab: \(bare)")
        XCTAssertFalse(bare.contains("Gamma decoy"), bare)
    }

    /// Every Claude session on the Mac shares one server. A bare browser call follows the page
    /// THAT session drove, never the page another session drove.
    func testEachSessionFollowsItsOwnPage() async throws {
        let alpha = try writePage("alpha", button: "Alpha only")
        let beta = try writePage("beta", button: "Beta only")
        try await userOpens(alpha)
        try await userOpens(beta)
        let chrome = BrowserTarget(bundleId: "com.google.Chrome", name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        func opened(_ url: String) -> [String: JSONValue] {
            BrowserRouting.browserArguments(.object(["app": .string("chrome"), "url": .string(url)]),
                                            browser: chrome, page: URL(string: url)!).objectValue ?? [:]
        }
        _ = try await RequestContext.$clientID.withValue("session-a") { try await call("snapshot", opened(alpha)) }
        _ = try await RequestContext.$clientID.withValue("session-b") { try await call("snapshot", opened(beta)) }

        let a = try await RequestContext.$clientID.withValue("session-a") { text(try await call("snapshot", ["app": .string("com.google.Chrome")])) }
        let b = try await RequestContext.$clientID.withValue("session-b") { text(try await call("snapshot", ["app": .string("com.google.Chrome")])) }
        XCTAssertTrue(a.contains("Alpha only") && !a.contains("Beta only"), "session A read: \(a)")
        XCTAssertTrue(b.contains("Beta only") && !b.contains("Alpha only"), "session B read: \(b)")
    }

    /// An agent working through many pages used to leave one tab per page in the user's Chrome.
    /// Tabs it opened are capped; the user's own tab is never closed.
    func testTabsOpenedByAgentsAreCappedAndTheUsersTabSurvives() async throws {
        let mine = try await userOpens(try writePage("mine", button: "User work"))
        for index in 0..<(WebCDPBackend.maxCreatedTabs + 3) {
            let page = try writePage("page\(index)", button: "Page \(index)")
            let snapshot = text(try await call("snapshot", ["url": .string(page)]))
            XCTAssertTrue(snapshot.contains("Page \(index)"), snapshot)
        }
        let after = try await ChromeLauncher.listPages(port: port)
        let opened = after.filter { $0.url.contains("/page") }
        XCTAssertLessThanOrEqual(opened.count, WebCDPBackend.maxCreatedTabs, "tabs opened by the agent: \(opened.map(\.url))")
        XCTAssertEqual(after.first { $0.id == mine.id }?.url, mine.url, "the user's tab was touched")
    }

    /// With no tab on the page the CDP backend refuses; for an app identity the router then
    /// declines and the call falls through to the AX path — it never reads "the first tab".
    func testAPageWithNoTabIsDeclinedNotAnsweredFromTheFirstTab() async throws {
        try await userOpens(try writePage("mail", button: "Private inbox"))
        let missing = try writePage("missing", button: "Never opened")
        await ProbeCache.shared.reset()
        let routed = await BackendRouter.dispatch(
            name: "snapshot",
            arguments: .object(["app": .string("com.google.Chrome"), BrowserRouting.pageURLKey: .string(missing)]))
        XCTAssertNil(routed, "the router answered from a tab that is not the requested page: \(routed.map(text) ?? "")")
    }

    /// An agent that asks for a page nobody has open gets a tab of its own; the user's tabs
    /// are left exactly as they were.
    func testAPageNoTabIsOnGetsANewTabAndTheUsersTabsAreUntouched() async throws {
        let mine = try await userOpens(try writePage("mine", button: "User work"))
        let wanted = try writePage("wanted", button: "Wanted page")
        let before = try await ChromeLauncher.listPages(port: port)

        let snapshot = text(try await call("snapshot", ["url": .string(wanted)]))
        XCTAssertTrue(snapshot.contains("Wanted page"), snapshot)

        let after = try await ChromeLauncher.listPages(port: port)
        XCTAssertEqual(after.count, before.count + 1, "one new tab, nothing closed")
        XCTAssertEqual(after.first { $0.id == mine.id }?.url, mine.url, "the user's tab was navigated")
        XCTAssertTrue(after.contains { $0.url == wanted })
    }

    /// `headless:true` is a promise to stay out of the user's browser: the page must open in
    /// the private Chromium this app owns, whatever debug port is open.
    // MARK: - 3.1.2: through the registry, the path every agent takes

    /// The tests above call `BackendRouter.dispatch` directly and so skip `BrowserRouting`, which
    /// in 3.1.1 handed every `app:"chrome"` page to LaunchServices first. These enter where the
    /// MCP handler does.
    private func viaRegistry(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        await ProbeCache.shared.reset()
        return try await ToolRegistry().callTool(name: name, arguments: .object(args))
    }

    private func isError(_ result: JSONValue) -> Bool { result["isError"]?.boolValue == true }

    private func launchServicesOpens() async -> Int { await MainActor.run { BrowserNavigator.launchServicesOpens } }

    /// Measured on the release Chrome, 15/10/2026: three snapshots by name, three new tabs and
    /// Chrome in front each time.
    func testChromeByNameNeverGoesThroughLaunchServicesAndReadsReuseOneTab() async throws {
        let mine = try await userOpens(try writePage("mine", button: "User work"))
        let page = try writePage("keys", button: "Create key")
        let before = try await ChromeLauncher.listPages(port: port)
        let opens = await launchServicesOpens()

        let first = try await viaRegistry("snapshot", ["app": .string("chrome"), "url": .string(page)])
        XCTAssertTrue(text(first).contains("Create key"), text(first))
        let again = try await viaRegistry("snapshot", ["app": .string("chrome"), "url": .string(page)])
        XCTAssertFalse(isError(again), text(again))
        let read = text(try await viaRegistry("read_all_text", ["app": .string("chrome"), "url": .string(page)]))
        XCTAssertTrue(read.contains("Create key"), read)
        let bare = text(try await viaRegistry("read_all_text", ["app": .string("Google Chrome")]))
        XCTAssertTrue(bare.contains("Create key"), "a bare call read another tab: \(bare)")
        let shot = try await viaRegistry("screenshot_window", ["app": .string("chrome"), "url": .string(page)])
        XCTAssertEqual(shot["content"]?.arrayValue?.first?["type"]?.stringValue, "image", text(shot))

        let after = try await ChromeLauncher.listPages(port: port)
        XCTAssertEqual(after.count, before.count + 1, "reading one page opened \(after.count - before.count) tabs")
        XCTAssertEqual(after.first { $0.id == mine.id }?.url, mine.url, "the user's tab was touched")
        let opensAfter = await launchServicesOpens()
        XCTAssertEqual(opensAfter, opens, "a page went through LaunchServices")
    }

    func testManyChromePagesThroughTheRegistryStayCapped() async throws {
        let mine = try await userOpens(try writePage("mine", button: "User work"))
        for index in 0..<(WebCDPBackend.maxCreatedTabs + 3) {
            let page = try writePage("many\(index)", button: "Page \(index)")
            let snapshot = text(try await viaRegistry("snapshot", ["app": .string("chrome"), "url": .string(page)]))
            XCTAssertTrue(snapshot.contains("Page \(index)"), snapshot)
        }
        let after = try await ChromeLauncher.listPages(port: port)
        let opened = after.filter { URL(string: $0.url)?.lastPathComponent.hasPrefix("many") == true }
        XCTAssertLessThanOrEqual(opened.count, WebCDPBackend.maxCreatedTabs, "tabs opened by the agent: \(opened.map(\.url))")
        XCTAssertEqual(after.first { $0.id == mine.id }?.url, mine.url, "the user's tab was touched")
    }

    /// A selector call that names the page acts on the tab the snapshot opened, without a tab of
    /// its own (that tab is claimed by the snapshot's session, so a search for a free one failed).
    func testASelectorCallNamingThePageUsesTheTabTheSnapshotOpened() async throws {
        let page = try writePage("form", button: "Press me")
        let snapshot = try await viaRegistry("snapshot", ["app": .string("chrome"), "url": .string(page)])
        XCTAssertTrue(text(snapshot).contains("Press me"), "snapshot: \(text(snapshot))")
        let before = try await ChromeLauncher.listPages(port: port)
        let found = try await viaRegistry("find_elements", ["app": .string("chrome"), "url": .string(page), "labelContains": .string("Press me")])
        XCTAssertFalse(isError(found), text(found))
        XCTAssertTrue(text(found).contains("Press me"), "find: \(text(found)) tabs: \(before.map(\.url))")
        let after = try await ChromeLauncher.listPages(port: port)
        XCTAssertEqual(after.count, before.count, "a selector call opened a tab")
    }

    func testOpenURLInChromeIsABackgroundTabNotALaunchServicesOpen() async throws {
        let server = try LocalHTTPServer(directory: workDir)
        defer { server.stop() }
        _ = try writePage("served", button: "Served page")
        let url = "http://127.0.0.1:\(server.port)/served.html"
        let before = try await ChromeLauncher.listPages(port: port)
        let opens = await launchServicesOpens()

        let opened = try await viaRegistry("open_url", ["browser": .string("chrome"), "url": .string(url)])
        XCTAssertFalse(isError(opened), text(opened))
        XCTAssertTrue(text(opened).contains("cdp") && text(opened).contains("background"), text(opened))
        let read = text(try await viaRegistry("read_all_text", ["app": .string("chrome")]))
        XCTAssertTrue(read.contains("Served page"), "the bare follow-up read another tab: \(read)")
        _ = try await viaRegistry("open_url", ["browser": .string("chrome"), "url": .string(url)])

        let after = try await ChromeLauncher.listPages(port: port)
        XCTAssertEqual(after.count, before.count + 1, "open_url twice on one page opened \(after.count - before.count) tabs")
        let opensAfter = await launchServicesOpens()
        XCTAssertEqual(opensAfter, opens, "open_url went through LaunchServices")
    }

    func testHeadlessTrueLeavesTheUsersChromeAlone() async throws {
        let mine = try await userOpens(try writePage("mine", button: "User work"))
        let target = try writePage("private", button: "Private browser page")
        let before = try await ChromeLauncher.listPages(port: port)

        let snapshot = text(try await call("snapshot", ["url": .string(target), "headless": .bool(true)]))
        XCTAssertTrue(snapshot.contains("Private browser page"), snapshot)

        let after = try await ChromeLauncher.listPages(port: port)
        XCTAssertEqual(after.map(\.id).sorted(), before.map(\.id).sorted(), "a tab appeared in the user's Chrome")
        XCTAssertEqual(after.first { $0.id == mine.id }?.url, mine.url)
        XCTAssertNotNil(OwnedChromeRegistry.current, "the page should be in the owned Chromium")
        XCTAssertNotEqual(OwnedChromeRegistry.current?.port, port)
    }
}
