import XCTest
@testable import MCPTools
import MCPServer
#if canImport(Darwin)
import Darwin
#endif

/// Drives a REAL headless Chromium through `BackendRouter.dispatch`, the same entry the
/// MCP tool call takes. Off by default (launches a browser): run with
/// `AGENTCONTROLLER_E2E=1 swift test --filter BackendEndToEndTests`.
final class BackendEndToEndTests: XCTestCase {
    private static var workDir: URL!

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["AGENTCONTROLLER_E2E"] == "1" else { return }
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("ac-e2e-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // No attaching to whatever Chrome the developer has open; own profile; own consent file.
        setenv("AGENTCONTROLLER_CDP_PORTS", "", 1)
        setenv("AGENTCONTROLLER_CDP_PROFILE", workDir.appendingPathComponent("profile").path, 1)
        setenv("AGENTCONTROLLER_CONSENT_PATH", workDir.appendingPathComponent("consent.json").path, 1)
    }

    override class func tearDown() {
        if workDir != nil {
            let done = DispatchSemaphore(value: 0)
            Task {
                await WebCDPBackend.shared.shutdown()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 10)
            try? FileManager.default.removeItem(at: workDir)
            unsetenv("AGENTCONTROLLER_CDP_PORTS")
            unsetenv("AGENTCONTROLLER_CDP_PROFILE")
            unsetenv("AGENTCONTROLLER_CONSENT_PATH")
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AGENTCONTROLLER_E2E"] == "1",
            "set AGENTCONTROLLER_E2E=1 to launch a real Chromium"
        )
        try XCTSkipUnless(ChromeLauncher.findBinary() != nil, "no Chromium browser installed")
    }

    // MARK: - Fixtures

    private func page(_ name: String, body: String, script: String = "") throws -> String {
        let url = Self.workDir.appendingPathComponent("\(name).html")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(name)</title>
        <style>body{font:16px sans-serif} button{margin:8px;padding:8px} #spacer{height:3000px}</style></head>
        <body>\(body)
        <script>
        window.stats = {clicks:0, trustedClicks:0, mousedowns:0, mouseups:0, dblclicks:0, farClicks:0,
                        trustedInputs:0, untrustedInputs:0, lastValue:'', scrollYAtFarClick:-1, loads: 1};
        const $ = id => document.getElementById(id);
        \(script)
        </script></body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url.absoluteString
    }

    /// A fresh file per call: sessions are keyed by url and keep their page between calls, so
    /// tests sharing one url would inherit each other's counters.
    private func interactivePage(_ name: String = UUID().uuidString) throws -> String {
        try page(name, body: """
        <h1>E2E page</h1>
        <button id="count-btn">Count</button>
        <button id="dbl-btn">Dbl</button>
        <a id="next" href="#next">Go next</a>
        <input id="name" aria-label="Name field">
        <div id="spacer"></div>
        <button id="far-btn">Far away</button>
        """, script: """
        $('count-btn').addEventListener('click', e => { stats.clicks++; if (e.isTrusted) stats.trustedClicks++; });
        $('count-btn').addEventListener('mousedown', () => stats.mousedowns++);
        $('count-btn').addEventListener('mouseup', () => stats.mouseups++);
        $('dbl-btn').addEventListener('dblclick', () => stats.dblclicks++);
        $('far-btn').addEventListener('click', () => { stats.farClicks++; stats.scrollYAtFarClick = window.scrollY; });
        $('name').addEventListener('input', e => { e.isTrusted ? stats.trustedInputs++ : stats.untrustedInputs++; stats.lastValue = e.target.value; });
        setTimeout(() => { const b = document.createElement('button'); b.textContent = 'Late arrival'; document.body.appendChild(b); }, 1500);
        """)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        var arguments = args
        if name == "run_app_code" { arguments["consent"] = .bool(true) }
        let routed = await BackendRouter.dispatch(name: name, arguments: .object(arguments))
        return try XCTUnwrap(routed, "\(name) was not routed")
    }

    private func text(_ result: JSONValue) -> String {
        result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    private func payload(_ result: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        XCTAssertNotEqual(result["isError"]?.boolValue, true, text(result), file: file, line: line)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text(result).utf8))
    }

    private func stats(_ url: String) async throws -> JSONValue {
        let result = try await call("run_app_code", ["url": .string(url), "code": .string("JSON.stringify(window.stats)")])
        let inner = try payload(result)["result"]?["result"]?["value"]?.stringValue ?? "{}"
        return try JSONDecoder().decode(JSONValue.self, from: Data(inner.utf8))
    }

    private func id(of label: String, in snapshot: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let element = snapshot["elements"]?.arrayValue?.first { $0["label"]?.stringValue == label }
        return try XCTUnwrap(element?["id"]?.stringValue, "no element labelled \(label)", file: file, line: line)
    }

    private func ownedChromeMainProcesses() async throws -> Int {
        let profile = ChromeLauncher.profileDirectory.path
        let out = try await ProcessRunner.run(executable: "/bin/ps", arguments: ["-axo", "command="], timeout: 5)
        return out.stdoutString.split(separator: "\n").filter {
            $0.contains("--user-data-dir=\(profile)") && !$0.contains("--type=")
        }.count
    }

    // MARK: - C1: no reload on every call

    func testClicksPersistAcrossSnapshotsScreenshotsAndScripts() async throws {
        let url = try interactivePage()
        let snap = try payload(try await call("snapshot", ["url": .string(url)]))
        XCTAssertEqual(snap["backend"]?.stringValue, "cdp")
        let button = try id(of: "Count", in: snap)

        for _ in 0..<3 { _ = try payload(try await call("click", ["elementId": .string(button)])) }
        var s = try await stats(url)
        XCTAssertEqual(s["clicks"]?.intValue, 3)

        // Each of these used to Page.navigate back to the url, wiping the page's state.
        _ = try await call("screenshot_window", ["url": .string(url)])
        _ = try await call("snapshot", ["url": .string(url)])
        s = try await stats(url)
        XCTAssertEqual(s["clicks"]?.intValue, 3, "the page was reloaded by a later call")
        XCTAssertEqual(s["loads"]?.intValue, 1)
    }

    func testRealPointerEventsFireAndOffscreenElementsAreScrolledTo() async throws {
        let url = try interactivePage()
        let snap = try payload(try await call("snapshot", ["url": .string(url)]))
        _ = try payload(try await call("click", ["elementId": .string(try id(of: "Count", in: snap))]))
        _ = try payload(try await call("click", ["elementId": .string(try id(of: "Far away", in: snap))]))
        let s = try await stats(url)
        XCTAssertEqual(s["trustedClicks"]?.intValue, 1, "click must be a trusted pointer event")
        XCTAssertEqual(s["mousedowns"]?.intValue, 1)
        XCTAssertEqual(s["mouseups"]?.intValue, 1)
        XCTAssertEqual(s["farClicks"]?.intValue, 1)
        XCTAssertGreaterThan(s["scrollYAtFarClick"]?.doubleValue ?? 0, 1000, "the element was never scrolled into view")
    }

    func testDoubleClickFiresDblclick() async throws {
        let url = try interactivePage()
        let snap = try payload(try await call("snapshot", ["url": .string(url)]))
        _ = try payload(try await call("double_click", ["elementId": .string(try id(of: "Dbl", in: snap))]))
        let s = try await stats(url)
        XCTAssertEqual(s["dblclicks"]?.intValue, 1)
    }

    /// A click that moves the page (here a link) must not be undone by the next call that
    /// names the original url.
    func testSnapshotAfterANavigatingClickStaysOnTheNewLocation() async throws {
        let url = try interactivePage()
        let snap = try payload(try await call("snapshot", ["url": .string(url)]))
        _ = try payload(try await call("click", ["elementId": .string(try id(of: "Count", in: snap))]))
        _ = try payload(try await call("click", ["elementId": .string(try id(of: "Go next", in: snap))]))
        let after = try payload(try await call("snapshot", ["url": .string(url)]))
        XCTAssertTrue(after["url"]?.stringValue?.hasSuffix("#next") == true, "landed on \(after["url"]?.stringValue ?? "nil")")
        let s = try await stats(url)
        XCTAssertEqual(s["clicks"]?.intValue, 1, "page state was lost")
    }

    func testOpenURLNavigatesOnlyWhenThePageIsElsewhere() async throws {
        let a = try interactivePage("open-a")
        let b = try page("open-b", body: "<h1>B</h1>")
        let snap = try payload(try await call("snapshot", ["url": .string(a)]))
        _ = try payload(try await call("click", ["elementId": .string(try id(of: "Count", in: snap))]))

        let again = try payload(try await call("open_url", ["url": .string(a), "headless": .bool(true)]))
        XCTAssertEqual(again["loaded"]?.boolValue, true)
        var s = try await stats(a)
        XCTAssertEqual(s["clicks"]?.intValue, 1, "open_url on the page it is already on reloaded it")

        _ = try payload(try await call("open_url", ["url": .string(b), "headless": .bool(true)]))
        let bSnap = try payload(try await call("snapshot", ["url": .string(b)]))
        XCTAssertTrue(bSnap["elements"]?.arrayValue?.contains { $0["label"]?.stringValue == "B" } ?? false || bSnap["count"]?.intValue != nil)
        s = try await stats(a)
        XCTAssertEqual(s["clicks"]?.intValue, 1)
    }

    // MARK: - C2: one Chromium, killed on shutdown

    func testOneChromiumServesEveryUrlAndShutdownKillsIt() async throws {
        await WebCDPBackend.shared.shutdown()
        let urls = try (0..<3).map { try interactivePage("many-\($0)") }
        for url in urls { _ = try payload(try await call("snapshot", ["url": .string(url)])) }
        let running = try await ownedChromeMainProcesses()
        XCTAssertEqual(running, 1, "each url launched its own Chromium")

        await WebCDPBackend.shared.shutdown()
        var left = try await ownedChromeMainProcesses()
        for _ in 0..<40 where left > 0 {
            try await Task.sleep(for: .milliseconds(100))
            left = try await ownedChromeMainProcesses()
        }
        XCTAssertEqual(left, 0, "shutdown left the owned Chromium running")
    }

    func testSurvivesTheOwnedChromeBeingKilled() async throws {
        let url = try interactivePage("killed")
        _ = try payload(try await call("snapshot", ["url": .string(url)]))
        let chrome = try XCTUnwrap(OwnedChromeRegistry.current)
        chrome.terminate()
        try await Task.sleep(for: .milliseconds(300))
        let snap = try payload(try await call("snapshot", ["url": .string(url)]))
        XCTAssertGreaterThan(snap["count"]?.intValue ?? 0, 0)
        XCTAssertNotEqual(OwnedChromeRegistry.current?.process.processIdentifier, chrome.process.processIdentifier)
    }

    // MARK: - H1: a big AX tree

    func testSnapshotOfAPageWhoseAXTreeExceedsOneMiB() async throws {
        let url = try page("big", body: "<div id=\"host\"></div>", script: """
        const host = $('host');
        for (let i = 0; i < 12000; i++) {
          const b = document.createElement('button');
          b.setAttribute('aria-label', 'Row ' + i + ' ' + 'x'.repeat(60));
          b.textContent = 'r' + i;
          host.appendChild(b);
        }
        """)
        let snap = try payload(try await call("snapshot", ["url": .string(url), "mode": .string("all")]))
        XCTAssertGreaterThanOrEqual(snap["count"]?.intValue ?? 0, 12000)
        // The connection survived and still answers.
        let again = try payload(try await call("snapshot", ["url": .string(url)]))
        XCTAssertGreaterThanOrEqual(again["count"]?.intValue ?? 0, 12000)
    }

    // MARK: - H6: typing

    func testTypeTextGoesThroughTheInputPipelineAndReplaces() async throws {
        let url = try interactivePage()
        let snap = try payload(try await call("snapshot", ["url": .string(url)]))
        let field = try id(of: "Name field", in: snap)
        _ = try payload(try await call("type_text", ["elementId": .string(field), "text": .string("abc")]))
        var s = try await stats(url)
        XCTAssertEqual(s["lastValue"]?.stringValue, "abc")
        XCTAssertGreaterThan(s["trustedInputs"]?.intValue ?? 0, 0, "frameworks that ignore this.value= only see trusted input events")
        XCTAssertEqual(s["untrustedInputs"]?.intValue, 0)

        _ = try payload(try await call("type_text", ["elementId": .string(field), "text": .string("xyz")]))
        s = try await stats(url)
        XCTAssertEqual(s["lastValue"]?.stringValue, "xyz", "typing replaces the previous content")

        _ = try payload(try await call("type_text", ["elementId": .string(field), "text": .string("")]))
        s = try await stats(url)
        XCTAssertEqual(s["lastValue"]?.stringValue, "")
    }

    // MARK: - M1/M2/LOW

    func testWaitForElementPollsUntilTheElementAppears() async throws {
        let url = try interactivePage()
        let started = Date()
        let found = try payload(try await call("wait_for_element", [
            "url": .string(url), "labelContains": .string("Late"), "timeout": .double(8),
        ]))
        XCTAssertEqual(found["found"]?.boolValue, true)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.8, "it answered from the first, pre-render snapshot")

        let missing = try payload(try await call("wait_for_element", [
            "url": .string(url), "labelContains": .string("Never appears"), "timeout": .double(1),
        ]))
        XCTAssertEqual(missing["found"]?.boolValue, false)
    }

    func testAssertVisibleAnswersPassOrFailForRoleAndIdentifierSelectors() async throws {
        let url = try interactivePage()
        let byRole = try payload(try await call("assert_visible", ["url": .string(url), "role": .string("textbox")]))
        XCTAssertEqual(byRole["passed"]?.boolValue, true)
        let byIdentifier = try payload(try await call("assert_visible", ["url": .string(url), "identifier": .string("count-btn")]))
        XCTAssertEqual(byIdentifier["passed"]?.boolValue, true)
        XCTAssertEqual(byIdentifier["label"]?.stringValue, "Count")

        let missing = try await call("assert_visible", ["url": .string(url), "identifier": .string("no-such-id"), "timeout": .double(0.5)])
        XCTAssertEqual(missing["isError"]?.boolValue, true)
        XCTAssertTrue(text(missing).contains("FAILED"), text(missing))

        let gone = try payload(try await call("assert_not_visible", ["url": .string(url), "identifier": .string("no-such-id"), "timeout": .double(0.5)]))
        XCTAssertEqual(gone["passed"]?.boolValue, true)

        let noSelector = try await call("assert_visible", ["url": .string(url)])
        XCTAssertEqual(noSelector["isError"]?.boolValue, true)
    }

    func testStaleIdIsReportedAsStaleNotRetargeted() async throws {
        let url = try interactivePage()
        let snap = try payload(try await call("snapshot", ["url": .string(url)]))
        let button = try id(of: "Count", in: snap)
        _ = try payload(try await call("run_app_code", ["url": .string(url), "code": .string("document.body.innerHTML = ''")]))
        let result = try await call("click", ["elementId": .string(button)])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(text(result).contains("Stale element id"), text(result))
        XCTAssertTrue(text(result).contains("snapshot"), text(result))
    }

    /// Chrome numbers DOM nodes per renderer process and a cross-site navigation swaps the
    /// process, so an id read on one site resolves, on the next, to an unrelated node there.
    func testAnIdFromAPageThatMovedToAnotherSiteIsStaleNotRetargeted() async throws {
        let inputs = (0..<200).map { #"<input id="e\#($0)" aria-label="e\#($0)">"# }.joined()
        let site = try LoopbackHTTPServer(pages: [
            "/bank": #"<!doctype html><title>bank</title><input id="pw" aria-label="Password">"#,
            "/elsewhere": #"<!doctype html><title>elsewhere</title><script>window.typed = []; document.addEventListener('input', e => typed.push(e.target.id + '=' + e.target.value))</script>"# + inputs,
        ])
        try site.start()
        defer { site.stop() }
        let bank = "http://127.0.0.1:\(site.port)/bank"
        let password = try id(of: "Password", in: try payload(try await call("snapshot", ["url": .string(bank)])))

        // 127.0.0.1 → localhost is a different site: the tab gets a new renderer process.
        _ = try payload(try await call("run_app_code", ["url": .string(bank), "code": .string(
            "setTimeout(() => { location.href = 'http://localhost:\(site.port)/elsewhere' }, 20); 'ok'")]))
        var title = ""
        for _ in 0..<50 where title != "elsewhere" {
            try await Task.sleep(for: .milliseconds(100))
            let read = try await call("run_app_code", ["url": .string(bank), "code": .string("document.title")])
            title = (try? payload(read))?["result"]?["result"]?["value"]?.stringValue ?? ""
        }
        XCTAssertEqual(title, "elsewhere")
        _ = try payload(try await call("run_app_code", ["url": .string(bank), "code": .string("document.getElementById('e3').focus(); 'ok'")]))

        let typed = try await call("type_text", ["elementId": .string(password), "text": .string("hunter2")])
        XCTAssertEqual(typed["isError"]?.boolValue, true, text(typed))
        XCTAssertTrue(text(typed).contains("Stale element id"), text(typed))
        let leaked = try payload(try await call("run_app_code", ["url": .string(bank), "code": .string("JSON.stringify(window.typed)")]))
        XCTAssertEqual(leaked["result"]?["result"]?["value"]?.stringValue, "[]", "the bank page's password went to the other site")
    }

    func testJavaScriptExceptionIsAnError() async throws {
        let url = try interactivePage()
        let result = try await call("run_app_code", ["url": .string(url), "code": .string("throw new Error('boom')")])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(text(result).contains("boom"), text(result))
        let ok = try await call("run_app_code", ["url": .string(url), "code": .string("1 + 1")])
        XCTAssertNotEqual(ok["isError"]?.boolValue, true)
    }

    func testUnsupportedToolOnAWebPageSaysSo() async throws {
        let url = try interactivePage()
        let result = try await call("scroll", ["url": .string(url)])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(text(result).contains("not supported on web targets"), text(result))
        XCTAssertTrue(text(result).contains("run_app_code"), text(result))
    }

    func testReadAllTextReturnsThePageText() async throws {
        let url = try interactivePage()
        let result = try payload(try await call("read_all_text", ["url": .string(url)]))
        XCTAssertTrue(result["text"]?.stringValue?.contains("E2E page") == true)
    }

    func testUnreachableUrlIsANavigationError() async throws {
        let result = try await call("snapshot", ["url": .string("http://127.0.0.1:1/definitely-not-listening")])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(text(result).contains("Navigation to"), text(result))
    }

    // MARK: - iOS (read-only: describe-all, never a tap)

    /// `AGENTCONTROLLER_E2E_IOS_UDID=<booted simulator>` as well as `AGENTCONTROLLER_E2E=1`.
    func testSimulatorSnapshotAgainstRealIdb() async throws {
        let udid = try XCTUnwrap(
            ProcessInfo.processInfo.environment["AGENTCONTROLLER_E2E_IOS_UDID"],
            "set AGENTCONTROLLER_E2E_IOS_UDID to a booted simulator"
        )
        let snap = try payload(try await call("snapshot", ["udid": .string(udid)]))
        XCTAssertEqual(snap["backend"]?.stringValue, "ios-sim")
        XCTAssertEqual(snap["udid"]?.stringValue, udid)
        let elements = try XCTUnwrap(snap["elements"]?.arrayValue)
        XCTAssertGreaterThan(elements.count, 0)
        XCTAssertTrue(elements.contains { ($0["label"]?.stringValue ?? "").isEmpty == false }, "labels come from AXLabel")
        XCTAssertTrue(elements.allSatisfy { $0["role"]?.stringValue != "element" }, "roles come from the idb type")
        XCTAssertFalse(elements.contains { UUID(uuidString: $0["label"]?.stringValue ?? "") != nil }, "a UUID is not a label")

        // `booted` resolves through the probe; with several booted it must say so rather than guess.
        let booted = await IOSSimBackend.shared.bootedUDIDs()
        let alias = try await call("snapshot", ["udid": .string("booted")])
        if booted.count == 1 {
            XCTAssertNotEqual(alias["isError"]?.boolValue, true, text(alias))
        } else {
            XCTAssertEqual(alias["isError"]?.boolValue, true)
            XCTAssertTrue(text(alias).contains("Multiple booted") || text(alias).contains("No booted"), text(alias))
        }
    }
}
