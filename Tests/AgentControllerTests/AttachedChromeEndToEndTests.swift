import XCTest
import MCPServer
#if canImport(Darwin)
import Darwin
#endif
@testable import MCPTools

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
