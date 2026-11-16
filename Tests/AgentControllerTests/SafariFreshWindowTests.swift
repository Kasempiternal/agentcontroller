import XCTest
import MCPServer
@testable import MCPTools
@testable import AccessibilityEngine

/// 3.2.0: a Safari window that is full screen or on another Space cannot be captured or resized, so
/// the page goes in a normal window of its own, opened in the background and reused. Nothing here
/// sends an Apple Event: `SafariWindows.system` is a recording fake, and the live one refuses
/// under test. The user's window is never given a script, so the fake would show it.
final class SafariFreshWindowTests: XCTestCase {

    private static let safari = BrowserTarget(
        bundleId: "com.apple.Safari", name: "Safari", appURL: URL(fileURLWithPath: "/Applications/Safari.app"))
    private let page = URL(string: "https://example.com/a")!

    private var fake: FakeSafariSystem!
    private var savedSystem: SafariSystem!
    private var savedGrace: TimeInterval!

    override func setUp() {
        super.setUp()
        savedSystem = SafariWindows.system
        savedGrace = SafariWindows.appearanceGrace
        fake = FakeSafariSystem()
        SafariWindows.system = fake
        SafariWindows.appearanceGrace = 0.3
        SafariAgentWindows.shared.removeAll()
        MainActor.assumeIsolated { BrowserNavigator.refuseLaunchServices = true }
    }

    override func tearDown() {
        SafariWindows.system = savedSystem
        SafariWindows.appearanceGrace = savedGrace
        SafariAgentWindows.shared.removeAll()
        MainActor.assumeIsolated { BrowserNavigator.refuseLaunchServices = false }
        super.tearDown()
    }

    // MARK: - What makes a window unusable

    func testFullScreenAndOtherSpaceWindowsAreUnusableAndMinimizedOnesAreNot() {
        func use(fullScreen: Bool = false, minimized: Bool = false, active: Bool = true) -> SafariWindowUse {
            SafariWindowFacts(isFullScreen: fullScreen, isMinimized: minimized, inActiveSpace: active).use
        }
        XCTAssertEqual(use(), .usable)
        XCTAssertEqual(use(fullScreen: true), .fullScreen)
        XCTAssertEqual(use(fullScreen: true, active: false), .fullScreen)
        XCTAssertEqual(use(active: false), .otherSpace, "absent from kAXWindows and not minimized: another Space")
        XCTAssertEqual(use(minimized: true, active: false), .usable, "a minimized window is restore_window's business")
        XCTAssertEqual(use(minimized: true), .usable)
    }

    func testACaptureIsRefusedOnlyWhereThereIsNoSurface() {
        func block(fullScreen: Bool = false, minimized: Bool = false, active: Bool = true) -> SafariWindowUse? {
            SafariWindowFacts(isFullScreen: fullScreen, isMinimized: minimized, inActiveSpace: active).captureBlock
        }
        XCTAssertNil(block(), "a normal window on the active Space")
        XCTAssertNil(block(fullScreen: true), "a full-screen window the user is looking at captures fine")
        XCTAssertEqual(block(fullScreen: true, active: false), .fullScreen)
        XCTAssertEqual(block(active: false), .otherSpace)
        XCTAssertNil(block(minimized: true, active: false), "minimized has its own answer: restore_window")
    }

    /// Never calls the live opener: if the switch were off, this test would be the one that opens a window.
    func testTheKillSwitchIsOnUnderSwiftTestAndHidesSafari() async {
        guard LiveSafariSystem.underTest else {
            return XCTFail("the test-run signal is off: the live Safari system could send Apple Events from tests")
        }
        let pid = await LiveSafariSystem().pid(bundleId: "com.apple.Safari")
        XCTAssertNil(pid, "under test the live system must not even find Safari")
    }

    // MARK: - The decision

    private func state(_ use: SafariWindowUse, url: String? = nil) -> SafariWindowState {
        switch use {
        case .usable: return .init(facts: .init(isFullScreen: false, isMinimized: false, inActiveSpace: true), pageURL: url)
        case .fullScreen: return .init(facts: .init(isFullScreen: true, isMinimized: false, inActiveSpace: false), pageURL: url)
        case .otherSpace: return .init(facts: .init(isFullScreen: false, isMinimized: false, inActiveSpace: false), pageURL: url)
        }
    }

    private func survey(front: SafariWindowUse?, agent: SafariWindowUse? = nil, agentIsFront: Bool = false,
                        frontmost: Bool = false, frontOnScreenFullScreen: Bool = false) -> SafariSurvey {
        var frontState = front.map { state($0) }
        if frontOnScreenFullScreen {
            frontState = .init(facts: .init(isFullScreen: true, isMinimized: false, inActiveSpace: true), pageURL: nil)
        }
        return SafariSurvey(
            front: frontState,
            agent: agent.map { .init(id: 77, state: state($0), isFront: agentIsFront, because: .fullScreen) },
            safariIsFrontmost: frontmost)
    }

    func testAUsableFrontWindowKeepsTheUsualPath() {
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .usable)), .defaultPath)
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: nil)), .defaultPath, "Safari with no window: the usual path opens one")
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .usable, agent: .usable)), .defaultPath)
    }

    func testAFullScreenOrOtherSpaceFrontWindowGetsAFreshWindow() {
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .fullScreen)), .openFreshWindow(because: .fullScreen))
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .otherSpace)), .openFreshWindow(because: .otherSpace))
    }

    func testAnAgentWindowIsReusedAndAnUnusableOneIsReplacedNotTouched() {
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .fullScreen, agent: .usable)),
                       .reuseAgentWindow(id: 77, because: .fullScreen))
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .otherSpace, agent: .usable)),
                       .reuseAgentWindow(id: 77, because: .otherSpace))
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .fullScreen, agent: .otherSpace)),
                       .openFreshWindow(because: .fullScreen), "the user moved it away: open another, leave that one alone")
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .fullScreen, agent: .fullScreen)),
                       .openFreshWindow(because: .fullScreen))
    }

    func testTheAgentWindowAtTheFrontIsNavigatedNotGivenAnotherTab() {
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .usable, agent: .usable, agentIsFront: true)),
                       .reuseAgentWindow(id: 77, because: .fullScreen))
    }

    func testNothingIsOpenedWhileTheUserIsInsideTheirFullScreenSafari() {
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: nil, frontmost: true, frontOnScreenFullScreen: true)), .holdOff)
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: .fullScreen, frontmost: true)), .openFreshWindow(because: .fullScreen),
                       "full screen on another Space while Safari is frontmost is not 'looking at it'")
        XCTAssertEqual(SafariWindowPolicy.route(survey(front: nil, agent: .usable, frontmost: true, frontOnScreenFullScreen: true)),
                       .reuseAgentWindow(id: 77, because: .fullScreen), "an agent window already exists: no new window, so nothing to pull them out")
    }

    // MARK: - Finding the window

    func testTheClosestFrameIsTheWindowAndATitleBreaksAnExactTie() {
        let a = SafariWindowMatch.Candidate(frame: CGRect(x: 4, y: 33, width: 1679, height: 1084), title: "user")
        let b = SafariWindowMatch.Candidate(frame: CGRect(x: 3, y: 33, width: 1679, height: 1084), title: "agent")
        XCTAssertEqual(SafariWindowMatch.pick(frame: b.frame, title: "agent", among: [a, b]), 1, "one point apart is two windows")
        XCTAssertEqual(SafariWindowMatch.pick(frame: a.frame, title: nil, among: [a, b]), 0)
        XCTAssertEqual(SafariWindowMatch.pick(frame: a.frame, title: "agent", among: [a, a]), 0)
        let twin = SafariWindowMatch.Candidate(frame: a.frame, title: "agent")
        XCTAssertEqual(SafariWindowMatch.pick(frame: a.frame, title: "agent", among: [a, twin]), 1)
        XCTAssertNil(SafariWindowMatch.pick(frame: CGRect(x: 500, y: 500, width: 300, height: 300), title: nil, among: [a, b]))
    }

    // MARK: - The scripts

    func testTheScriptsCompileAndCarryNoPageText() throws {
        for id in ["com.apple.Safari", "com.apple.SafariTechnologyPreview"] {
            let application = try XCTUnwrap(SafariScripts.applicationID(for: id))
            for source in [SafariScripts.open(applicationID: application), SafariScripts.navigate(applicationID: application),
                           SafariScripts.close(applicationID: application)] {
                XCTAssertTrue(source.contains("argv"))
                XCTAssertFalse(source.contains("http"), "the page travels as an argument, never inside the script")
            }
        }
        XCTAssertNil(SafariScripts.applicationID(for: "com.google.Chrome"))
        XCTAssertNil(SafariScripts.applicationID(for: "x\" & (do shell script \"id\") & \""))
    }

    func testTheScriptsCompileAgainstSafarisDictionary() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/Applications/Safari.app"), "Safari is not installed")
        for source in [SafariScripts.open(applicationID: "com.apple.Safari"), SafariScripts.navigate(applicationID: "com.apple.Safari"),
                       SafariScripts.close(applicationID: "com.apple.Safari")] {
            var error: NSDictionary?
            // Compiling resolves Safari's terms; it sends no Apple Event and starts nothing.
            XCTAssertTrue(NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false, "\(String(describing: error))")
        }
    }

    func testAppleEventFailuresAreToldApart() {
        XCTAssertEqual(SafariScripts.classify(stderr: "execution error: Not authorized to send Apple events to Safari. (-1743)"), .notAllowed)
        XCTAssertEqual(SafariScripts.classify(stderr: "Can't get window id 99. Invalid index. (-1728)"), .windowGone)
        XCTAssertEqual(SafariScripts.classify(stderr: "AppleEvent timed out. (-1712)"), .timedOut)
        XCTAssertEqual(SafariScripts.classify(stderr: "boom\n"), .other("boom"))
        XCTAssertEqual(SafariScripts.parseWindowID("2933\n"), 2933)
        XCTAssertNil(SafariScripts.parseWindowID("missing value"))
    }

    // MARK: - The whole call against a recording Safari

    func testAFullScreenWindowGetsANewWindowAndTheUsersIsNeverScripted() async throws {
        fake.front = state(.fullScreen, url: "https://user.example/dashboard")

        let outcome = try await XCTUnwrapAsync(await SafariWindows.navigate(page, in: Self.safari, timeout: 2))

        XCTAssertEqual(fake.calls, [.open("https://example.com/a")])
        XCTAssertEqual(outcome.agentWindow, .init(id: 1001, created: true, because: .fullScreen))
        XCTAssertTrue(outcome.loaded)
        XCTAssertEqual(SafariAgentWindows.shared.entry(forPID: fake.pid), .init(id: 1001, because: .fullScreen))
        let notice = BrowserRouting.navigationNotice(page: page, browser: "Safari", outcome: outcome)
        XCTAssertTrue(notice.contains("NEW normal Safari window (id 1001)"), notice)
        XCTAssertTrue(notice.contains("full screen"), notice)
        XCTAssertTrue(notice.contains("The user's own window was not touched"), notice)
    }

    func testTheNextPageReusesThatWindowInsteadOfOpeningAnother() async throws {
        fake.front = state(.otherSpace)
        _ = try await XCTUnwrapAsync(await SafariWindows.navigate(page, in: Self.safari, timeout: 2))

        let other = URL(string: "https://example.com/b")!
        let second = try await XCTUnwrapAsync(await SafariWindows.navigate(other, in: Self.safari, timeout: 2))

        XCTAssertEqual(fake.calls, [.open("https://example.com/a"), .navigate(1001, "https://example.com/b")])
        XCTAssertEqual(second.agentWindow, .init(id: 1001, created: false, because: .otherSpace))
        XCTAssertTrue(BrowserRouting.navigationNotice(page: other, browser: "Safari", outcome: second).contains("opened earlier (id 1001)"))

        let again = try await XCTUnwrapAsync(await SafariWindows.navigate(other, in: Self.safari, timeout: 2))
        XCTAssertEqual(fake.calls.count, 2, "the page is already showing in that window: no script at all")
        XCTAssertEqual(again.agentWindow?.id, 1001)
    }

    func testTwoCallsArrivingTogetherShareOneWindow() async throws {
        fake.front = state(.fullScreen)
        fake.openDelay = 0.15
        let browser = Self.safari
        async let first = SafariWindows.navigate(URL(string: "https://example.com/a")!, in: browser, timeout: 2)
        async let second = SafariWindows.navigate(URL(string: "https://example.com/b")!, in: browser, timeout: 2)
        let (a, b) = try await (first, second)

        XCTAssertEqual(a?.agentWindow?.id, 1001)
        XCTAssertEqual(b?.agentWindow?.id, 1001)
        let opens = fake.calls.filter { if case .open = $0 { return true } else { return false } }
        XCTAssertEqual(opens.count, 1, "two windows were opened: \(fake.calls)")
    }

    func testAWindowTheUserMovedAwayIsLeftAloneAndReplaced() async throws {
        fake.front = state(.fullScreen)
        _ = try await XCTUnwrapAsync(await SafariWindows.navigate(page, in: Self.safari, timeout: 2))
        fake.agentUse = .otherSpace

        let second = try await XCTUnwrapAsync(await SafariWindows.navigate(URL(string: "https://example.com/b")!, in: Self.safari, timeout: 2))

        XCTAssertEqual(second.agentWindow?.id, 1002)
        XCTAssertFalse(fake.calls.contains { if case .close = $0 { return true } else { return false } }, "never closes a window it is not discarding")
    }

    func testAUsableFrontWindowIsNotOursToOpenAWindowFor() async throws {
        fake.front = state(.usable)
        let outcome = try await SafariWindows.navigate(page, in: Self.safari, timeout: 2)
        XCTAssertNil(outcome)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testOtherBrowsersAndNonWebPagesAreNotOurs() async throws {
        fake.front = state(.fullScreen)
        let chrome = BrowserTarget(bundleId: "com.google.Chrome", name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        let chromeOutcome = try await SafariWindows.navigate(page, in: chrome, timeout: 2)
        XCTAssertNil(chromeOutcome)
        let fileOutcome = try await SafariWindows.navigate(URL(string: "file:///tmp/x.html")!, in: Self.safari, timeout: 2)
        XCTAssertNil(fileOutcome)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testTheUserInsideFullScreenSafariIsNotPulledOut() async throws {
        fake.front = .init(facts: .init(isFullScreen: true, isMinimized: false, inActiveSpace: true), pageURL: nil)
        fake.frontmost = true
        do {
            _ = try await SafariWindows.navigate(page, in: Self.safari, timeout: 2)
            XCTFail("a window was opened under the user")
        } catch let error as SafariWindowError {
            XCTAssertTrue(error.message.contains("looking at their full-screen Safari"), error.message)
            XCTAssertTrue(error.message.contains("Do not ask the user to leave full screen"), error.message)
        }
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAWindowThatNeverBecomesUsableIsClosedAndNotRetried() async throws {
        fake.front = state(.fullScreen)
        fake.landsIn = .otherSpace
        do {
            _ = try await SafariWindows.navigate(page, in: Self.safari, timeout: 2)
            XCTFail("an unusable window was reported as usable")
        } catch let error as SafariWindowError {
            XCTAssertTrue(error.message.contains("closed"), error.message)
        }
        XCTAssertEqual(fake.calls, [.open("https://example.com/a"), .close(1001)])
        XCTAssertNil(SafariAgentWindows.shared.entry(forPID: fake.pid))
    }

    func testDeniedAutomationSaysWhereToAllowIt() async throws {
        fake.front = state(.fullScreen)
        fake.openFailure = .notAllowed
        do {
            _ = try await SafariWindows.navigate(page, in: Self.safari, timeout: 2)
            XCTFail("expected a refusal")
        } catch let error as SafariWindowError {
            XCTAssertTrue(error.message.contains("System Settings > Privacy & Security > Automation"), error.message)
        }
        XCTAssertNil(SafariAgentWindows.shared.entry(forPID: fake.pid))
    }

    // MARK: - Through the tools

    func testASnapshotOfASafariPageInAFullScreenSafariIsRewrittenAndSaysWhichWindow() async throws {
        fake.front = state(.fullScreen)
        for tool in ["snapshot", "screenshot_window", "read_all_text"] {
            SafariAgentWindows.shared.removeAll()
            fake.reset()
            let prepared = try await BrowserRouting.prepare(
                name: tool, arguments: .object(["app": .string("Safari"), "url": .string("https://example.com/a")]))
            guard case .rewritten(let args, let notice) = prepared else { return XCTFail("\(tool): \(prepared)") }
            XCTAssertEqual(args["app"]?.stringValue, "com.apple.Safari", tool)
            XCTAssertEqual(fake.calls, [.open("https://example.com/a")], tool)
            XCTAssertTrue(notice?.contains("(id 1001)") ?? false, "\(tool): \(notice ?? "nil")")
        }
    }

    func testOpenURLInAFullScreenSafariReturnsTheWindowId() async throws {
        fake.front = state(.otherSpace)
        let launchServicesBefore = await MainActor.run { BrowserNavigator.launchServicesOpens }
        let registry = ToolRegistry()
        let result = try await registry.callTool(
            name: "open_url", arguments: .object(["url": .string("https://example.com/a"), "browser": .string("safari")]))
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertNil(result["isError"]?.boolValue, text)
        XCTAssertTrue(text.contains("\"window\":1001"), text)
        XCTAssertTrue(text.contains("\"freshWindow\":true"), text)
        XCTAssertTrue(text.contains("\"activated\":false"), text)
        XCTAssertEqual(fake.calls, [.open("https://example.com/a")])
        let launchServicesAfter = await MainActor.run { BrowserNavigator.launchServicesOpens }
        XCTAssertEqual(launchServicesAfter, launchServicesBefore, "the page was also handed to LaunchServices")
    }

    func testAppsThatAreNotSafariAreNeverJudged() async {
        let own = getpid()
        let blocker = await SafariWindows.captureBlocker(pid: own)
        XCTAssertNil(blocker)
        let bounds = await SafariWindows.boundsTarget(pid: own, requestedIndex: nil)
        XCTAssertEqual(bounds, .passthrough)
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}

/// A Safari that records what it is asked and answers from one small state.
final class FakeSafariSystem: SafariSystem, @unchecked Sendable {
    enum Call: Equatable {
        case open(String)
        case navigate(Int, String)
        case close(Int)
    }

    let pid: pid_t = 4242
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var nextID = 1001

    var front: SafariWindowState?
    var frontmost = false
    var agentID: Int?
    var agentUse: SafariWindowUse = .usable
    var agentURL: String?
    /// Where a window this fake opens lands.
    var landsIn: SafariWindowUse = .usable
    var openFailure: SafariScripts.Failure?
    var openDelay: TimeInterval = 0

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _calls = []
        agentID = nil
        agentURL = nil
        agentUse = .usable
        landsIn = .usable
        nextID = 1001
    }

    private func record(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
    }

    func pid(bundleId: String) async -> pid_t? { pid }

    func survey(pid: pid_t, entry: SafariAgentWindows.Entry?) async -> SafariSurvey {
        var agent: SafariSurvey.AgentWindow?
        if let entry, entry.id == agentID {
            let facts = SafariWindowState(facts: Self.facts(agentUse), pageURL: agentURL)
            agent = .init(id: entry.id, state: facts, isFront: false, because: entry.because)
        }
        return SafariSurvey(front: front, agent: agent, safariIsFrontmost: frontmost)
    }

    func page(pid: pid_t, windowID: Int) async -> SafariPage? {
        guard windowID == agentID else { return nil }
        return SafariPage(use: agentUse, url: agentURL, loaded: true)
    }

    func openWindow(bundleId: String, url: URL) async throws -> Int {
        record(.open(url.absoluteString))
        if openDelay > 0 { try await Task.sleep(nanoseconds: UInt64(openDelay * 1_000_000_000)) }
        if let openFailure { throw SafariScriptFailure(failure: openFailure) }
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        agentID = id
        agentUse = landsIn
        agentURL = url.absoluteString
        return id
    }

    func navigate(bundleId: String, windowID: Int, to url: URL) async throws {
        record(.navigate(windowID, url.absoluteString))
        agentURL = url.absoluteString
    }

    func closeWindow(bundleId: String, windowID: Int) async {
        record(.close(windowID))
        agentID = nil
    }

    private static func facts(_ use: SafariWindowUse) -> SafariWindowFacts {
        switch use {
        case .usable: return .init(isFullScreen: false, isMinimized: false, inActiveSpace: true)
        case .fullScreen: return .init(isFullScreen: true, isMinimized: false, inActiveSpace: false)
        case .otherSpace: return .init(isFullScreen: false, isMinimized: false, inActiveSpace: false)
        }
    }
}
