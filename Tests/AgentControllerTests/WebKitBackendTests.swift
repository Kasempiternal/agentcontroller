import XCTest
import AppKit
import ImageIO
import Network
import MCPServer
@testable import MCPTools
@testable import AccessibilityEngine

/// 3.3.0: `browser:"webkit"` renders a page in WebKit inside this process, off screen. Everything
/// here talks to a loopback server of its own and to views it creates itself; nothing reaches the
/// user's Safari, Chrome or any app, and each test uses a profile of its own and removes it.
@MainActor
final class WebKitBackendTests: XCTestCase {
    private var server: TestPageServer!
    private var profile = ""
    private var extraProfiles: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        // No Dock icon, no menu bar: the test process is not an app the user should see.
        NSApplication.shared.setActivationPolicy(.prohibited)
        server = try TestPageServer()
        try server.start()
        profile = "t\(UUID().uuidString.prefix(8))"
        BrowserNavigator.refuseLaunchServices = true
    }

    override func tearDown() async throws {
        WebKitBackend.shared.closeAll()
        await WebKitBackend.shared.removeProfile(profile)
        for extra in extraProfiles { await WebKitBackend.shared.removeProfile(extra) }
        server.stop()
        BrowserNavigator.refuseLaunchServices = false
        AttachedChrome.resolverOverride = nil
        try await super.tearDown()
    }

    // MARK: - Pure

    func testOnlyWebKitNamesAreTargets() {
        XCTAssertNotNil(WebKitTarget.parse(.object(["browser": .string("webkit")])))
        XCTAssertNotNil(WebKitTarget.parse(.object(["app": .string(" WebKit ")])))
        XCTAssertEqual(WebKitTarget.parse(.object(["app": .string("webkit:https://example.com/a")]))?.url?.absoluteString, "https://example.com/a")
        XCTAssertNil(WebKitTarget.parse(.object(["app": .string("Safari"), "url": .string("https://example.com")])))
        XCTAssertNil(WebKitTarget.parse(.object(["app": .string("com.apple.WebKit.Networking")])))
        XCTAssertNil(WebKitTarget.parse(.object(["url": .string("https://example.com")])))
    }

    func testOptionsAreParsedAndBadOnesAreReported() throws {
        let good = try XCTUnwrap(WebKitTarget.parse(.object([
            "browser": .string("webkit"), "url": .string("http://127.0.0.1:1/x"), "profile": .string("qa one/../x"), "page": .string("a"),
            "width": .int(390), "height": .double(844), "colorScheme": .string("Dark"), "dpr": .int(3),
        ])))
        XCTAssertNil(good.problem)
        XCTAssertEqual(good.options, .init(width: 390, height: 844, colorScheme: .dark, scale: 3))
        XCTAssertEqual(good.profile, "qa_one_.._x", "a name is never a path")
        XCTAssertEqual(good.key, "qa_one_.._x/a")
        for bad in [["width": JSONValue.int(0)], ["height": .int(99_999)], ["colorScheme": .string("sepia")], ["deviceScaleFactor": .int(9)]] {
            var arguments = bad
            arguments["browser"] = .string("webkit")
            XCTAssertNotNil(WebKitTarget.parse(.object(arguments))?.problem, "\(bad)")
        }
    }

    func testProfileStoresAreHashedNotTruncated() {
        let a = WebKitBackend.storeIdentifier(profile: "a-very-long-profile-name-one")
        let b = WebKitBackend.storeIdentifier(profile: "a-very-long-profile-name-two")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, WebKitBackend.storeIdentifier(profile: "a-very-long-profile-name-one"))
    }

    func testSelectorsMatchLikeTheOtherWebBackend() throws {
        func ref(_ i: Int, _ role: String, _ label: String) -> RoutedRef { .webkit(page: "p/m", document: "1.1", index: i, role: role, label: label) }
        let collected = WebKitRouter.Collected(
            refs: [ref(0, "button", "Save"), ref(1, "textbox", "Search"), ref(2, "button", "Save draft")],
            elements: [.null, .null, .null],
            total: 3,
            raw: [.object([:]), .object(["ident": .bool(true)]), .object([:])])
        func hits(_ arguments: [String: JSONValue]) throws -> [Int] {
            WebKitRouter.select(collected, selector: try CDPSelector.parse(.object(arguments)))
        }
        XCTAssertEqual(try hits(["role": .string("AXButton")]), [0, 2])
        XCTAssertEqual(try hits(["labelContains": .string("save")]), [0, 2])
        XCTAssertEqual(try hits(["title": .string("save")]), [0])
        XCTAssertEqual(try hits(["role": .string("button"), "index": .int(1)]), [2])
        XCTAssertEqual(try hits(["identifier": .string("q")]), [1])
    }

    func testTheBackendKnowsExactlyTheToolsTheRouterImplements() {
        XCTAssertEqual(CapabilityRecord.Backend.webkit.supportedTools, WebKitRouter.supportedTools)
        for tool in WebKitRouter.supportedTools { XCTAssertTrue(CapabilityRecord.routableTools.contains(tool) || ["set_window_bounds", "get_window_bounds"].contains(tool), tool) }
        let record = CapabilityProbe.classify(TargetIdentity(raw: "webkit"))
        XCTAssertEqual(record.backend, .webkit)
    }

    func testEveryWebKitToolAdvertisesTheOptionsAndNoOtherToolDoes() throws {
        let listed = ToolRegistry().listTools()
        var seen = Set<String>()
        for entry in listed {
            guard let name = entry["name"]?.stringValue, let schema = entry["inputSchema"], case .object(let properties)? = schema["properties"] else { continue }
            let advertises = properties["colorScheme"] != nil && properties["deviceScaleFactor"] != nil && properties["profile"] != nil
            if WebKitRouter.supportedTools.contains(name) {
                XCTAssertTrue(advertises, "\(name) does not advertise the WebKit options")
                XCTAssertTrue(entry["description"]?.stringValue?.contains("webkit") ?? false, "\(name) does not mention webkit")
                seen.insert(name)
            } else {
                XCTAssertFalse(advertises, "\(name) advertises WebKit options it ignores")
            }
        }
        XCTAssertEqual(seen, WebKitRouter.supportedTools)
    }

    // MARK: - What a page may not make this view load

    func testThePolicyLetsAPageGoToTheWebAndNowhereElse() throws {
        let web = try XCTUnwrap(URL(string: "https://example.com/a?b=1#c"))
        XCTAssertTrue(WebKitURLPolicy.pageMayNavigate(to: web))
        XCTAssertTrue(WebKitURLPolicy.popupMayOpen(web))
        XCTAssertTrue(WebKitURLPolicy.pageMayNavigate(to: try XCTUnwrap(URL(string: "http://127.0.0.1:3231/"))))
        XCTAssertTrue(WebKitURLPolicy.pageMayNavigate(to: try XCTUnwrap(URL(string: "about:blank"))))
        XCTAssertFalse(WebKitURLPolicy.popupMayOpen(try XCTUnwrap(URL(string: "about:blank"))))
        for raw in ["file:///etc/hosts", "data:text/html,<p>x</p>", "blob:http://127.0.0.1/abc", "myapp://open", "javascript:alert(1)", "ftp://example.com/x", "about:config"] {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertFalse(WebKitURLPolicy.pageMayNavigate(to: url), raw)
            XCTAssertFalse(WebKitURLPolicy.popupMayOpen(url), raw)
        }
        XCTAssertFalse(WebKitURLPolicy.frameMayLoad(try XCTUnwrap(URL(string: "file:///etc/hosts")), topIsFile: false))
        XCTAssertTrue(WebKitURLPolicy.frameMayLoad(try XCTUnwrap(URL(string: "file:///tmp/a.html")), topIsFile: true))
        XCTAssertFalse(WebKitURLPolicy.frameMayLoad(try XCTUnwrap(URL(string: "myapp://open")), topIsFile: true))
    }

    func testAToolCallerNeedsAnOptionForFileAndDataUrls() async throws {
        let registry = ToolRegistry()
        for raw in ["file:///etc/hosts", "data:text/html,<p>hello</p>", "about:config", "ftp://example.com/x"] {
            let reply = try await call(registry, "open_url", ["browser": "webkit", "url": raw, "profile": profile])
            XCTAssertTrue(reply.isError, "\(raw): \(reply.text)")
        }
        let file = try await call(registry, "open_url", ["browser": "webkit", "url": "file:///etc/hosts", "profile": profile])
        XCTAssertTrue(file.text.contains("allowFile:true"), file.text)
        XCTAssertNil(WebKitBackend.shared.page(key: WebKitBackend.key(profile: profile, name: "main")), "a refused call must not open a page")
        let blank = try await call(registry, "open_url", ["browser": "webkit", "url": "about:blank", "profile": profile])
        XCTAssertFalse(blank.isError, blank.text)
    }

    func testAFilePageOnlyReadsItsOwnFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ac-webkit-\(UUID().uuidString)")
        let pageDir = base.appendingPathComponent("page"), otherDir = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "SECRET".write(to: otherDir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "NEIGHBOUR".write(to: pageDir.appendingPathComponent("near.txt"), atomically: true, encoding: .utf8)
        let html = """
        <!doctype html><title>local</title><p>local page</p><script>
        window.result = 'pending';
        const read = (u) => fetch(u).then((r) => r.text()).catch(() => 'blocked');
        Promise.all([read('near.txt'), read('../other/secret.txt'), read('file:///etc/hosts')]).then((r) => { window.result = r.join('|'); });
        </script>
        """
        try html.write(to: pageDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let registry = ToolRegistry()
        let opened = try await call(registry, "open_url", ["browser": "webkit", "url": pageDir.appendingPathComponent("index.html").absoluteString, "profile": profile, "allowFile": true])
        XCTAssertFalse(opened.isError, opened.text)
        try await Task.sleep(nanoseconds: 800_000_000)
        let seen = try await call(registry, "run_app_code", ["browser": "webkit", "profile": profile, "code": "window.result", "consent": true])
        XCTAssertFalse(seen.text.contains("SECRET"), "a file page read a file outside its folder: \(seen.text)")
        XCTAssertFalse(seen.text.contains("localhost"), "a file page read /etc/hosts: \(seen.text)")
    }

    func testAPopupToFileDataOrAnOddSchemeNeverLoadsButAWebOneDoes() async throws {
        server.pages["/other"] = .html("<!doctype html><title>other</title><p>the popup target</p>")
        server.pages["/popups"] = .html("""
        <!doctype html><title>popups</title>
        <button id="f" onclick="window.open('file:///etc/hosts')">file</button>
        <button id="d" onclick="window.open('data:text/html,<p>from data</p>')">data</button>
        <button id="c" onclick="window.open('myapp://open')">custom</button>
        <a id="b" target="_blank" href="file:///etc/hosts">blank link</a>
        <button id="w" onclick="window.open('\(server.url("/other").absoluteString)')">web</button>
        """)
        let registry = ToolRegistry()
        let opened = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/popups").absoluteString, "profile": profile])
        XCTAssertFalse(opened.isError, opened.text)
        let page = try XCTUnwrap(WebKitBackend.shared.page(key: WebKitBackend.key(profile: profile, name: "main")))
        let snap = try await call(registry, "snapshot", ["browser": "webkit", "profile": profile])
        func id(_ label: String) throws -> String {
            try XCTUnwrap((snap.json["elements"]?.arrayValue ?? []).first { $0["label"]?.stringValue == label }?["id"]?.stringValue, "no element \(label)")
        }
        var refused = ""
        for label in ["file", "data", "custom", "blank link"] {
            let click = try await call(registry, "click", ["browser": "webkit", "profile": profile, "elementId": try id(label)])
            XCTAssertFalse(click.isError, click.text)
            try await Task.sleep(nanoseconds: 400_000_000)
            refused += click.text + "\n" + page.takeBlocked().joined(separator: "\n")
            XCTAssertTrue(page.currentURL?.hasSuffix("/popups") == true, "\(label) took the view away: \(page.currentURL ?? "nil")")
        }
        for _ in 0..<12 where refused.components(separatedBy: "popup refused").count - 1 < 3 {
            try await Task.sleep(nanoseconds: 250_000_000)
            refused += "\n" + page.takeBlocked().joined(separator: "\n")
        }
        XCTAssertGreaterThanOrEqual(refused.components(separatedBy: "popup refused").count - 1, 3, refused)
        XCTAssertTrue(refused.contains("popup refused: file:///etc/hosts"), refused)
        XCTAssertTrue(refused.contains("popup refused: data:text/html"), refused)
        XCTAssertTrue(refused.contains("popup refused: myapp://open"), refused)

        let web = try await call(registry, "click", ["browser": "webkit", "profile": profile, "elementId": try id("web")])
        XCTAssertFalse(web.isError, web.text)
        for _ in 0..<20 where page.currentURL?.hasSuffix("/other") != true { try await Task.sleep(nanoseconds: 250_000_000) }
        XCTAssertEqual(page.currentURL, server.url("/other").absoluteString, "a web popup opens in the same view")
    }

    func testAPagesOwnNavigationToFileDataOrACustomSchemeIsCancelled() async throws {
        server.pages["/nav"] = .html("""
        <!doctype html><title>nav</title>
        <button id="f" onclick="location.href='file:///etc/hosts'">file</button>
        <button id="d" onclick="location.href='data:text/html,<p>x</p>'">data</button>
        <button id="c" onclick="location.href='myapp://open'">custom</button>
        <iframe id="frame" src="about:blank"></iframe>
        <button id="i" onclick="document.getElementById('frame').src='file:///etc/hosts'">frame</button>
        """)
        let registry = ToolRegistry()
        _ = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/nav").absoluteString, "profile": profile])
        let page = try XCTUnwrap(WebKitBackend.shared.page(key: WebKitBackend.key(profile: profile, name: "main")))
        let snap = try await call(registry, "snapshot", ["browser": "webkit", "profile": profile])
        var refused = ""
        for label in ["file", "data", "custom", "frame"] {
            let target = try XCTUnwrap((snap.json["elements"]?.arrayValue ?? []).first { $0["label"]?.stringValue == label }?["id"]?.stringValue)
            let click = try await call(registry, "click", ["browser": "webkit", "profile": profile, "elementId": target])
            try await Task.sleep(nanoseconds: 400_000_000)
            refused += click.text + "\n" + page.takeBlocked().joined(separator: "\n")
            XCTAssertTrue(page.currentURL?.hasSuffix("/nav") == true, "\(label) navigated the view: \(page.currentURL ?? "nil")")
        }
        for _ in 0..<12 where refused.components(separatedBy: "navigation refused").count - 1 < 2 {
            try await Task.sleep(nanoseconds: 250_000_000)
            refused += "\n" + page.takeBlocked().joined(separator: "\n")
        }
        // WebKit itself drops a web page's jump to file: before the delegate hears of it; data: and a custom scheme reach it.
        XCTAssertGreaterThanOrEqual(refused.components(separatedBy: "navigation refused").count - 1, 2, refused)
        let text = try await call(registry, "read_all_text", ["browser": "webkit", "profile": profile])
        XCTAssertFalse(text.text.contains("localhost"), "the page's own navigation reached /etc/hosts")
    }

    func testARedirectToFileEndsTheLoadWithAnError() async throws {
        var redirect = TestPageServer.Page(status: 302, body: "")
        redirect.headers["Location"] = "file:///etc/hosts"
        server.pages["/bounce"] = redirect
        let reply = try await call(ToolRegistry(), "open_url", ["browser": "webkit", "url": server.url("/bounce").absoluteString, "profile": profile])
        XCTAssertTrue(reply.isError, reply.text)
        let page = WebKitBackend.shared.page(key: WebKitBackend.key(profile: profile, name: "main"))
        XCTAssertNotEqual(page?.currentURL?.hasPrefix("file:"), true)
    }

    func testADownloadIsRefusedNotSaved() async throws {
        var attachment = TestPageServer.Page.html("<!doctype html><p>file contents</p>")
        attachment.headers["Content-Disposition"] = "attachment; filename=\"x.html\""
        server.pages["/download"] = attachment
        var binary = TestPageServer.Page(body: "PK")
        binary.contentType = "application/zip"
        server.pages["/zip"] = binary
        let registry = ToolRegistry()
        for path in ["/download", "/zip"] {
            let reply = try await call(registry, "open_url", ["browser": "webkit", "url": server.url(path).absoluteString, "profile": profile])
            XCTAssertTrue(reply.isError, "\(path): \(reply.text)")
            XCTAssertTrue(reply.text.contains("download refused"), reply.text)
        }
    }

    func testNothingAnswersAnAuthenticationOrTLSChallengeOnItsOwn() {
        let page = WebKitBackend.shared.page(profile: profile, name: "probe", options: .init())
        let selectors = [
            "webView:didReceiveAuthenticationChallenge:completionHandler:",
            "webView:authenticationChallenge:shouldAllowDeprecatedTLS:",
            "webView:navigationAction:didBecomeDownload:",
            "webView:navigationResponse:didBecomeDownload:",
        ]
        for name in selectors { XCTAssertFalse(page.responds(to: NSSelectorFromString(name)), "\(name) would let this view accept a challenge or a download") }
        XCTAssertFalse(page.web.isInspectable, "Web Inspector is a second way into the page's JavaScript")
    }

    func testIdlePagesAreClosedAndTheNumberIsCapped() {
        let backend = WebKitBackend()
        defer { backend.closeAll() }
        for index in 0..<(WebKitBackend.maxPages + 2) {
            _ = backend.page(profile: profile, name: "p\(index)", options: .init())
        }
        XCTAssertLessThanOrEqual(backend.openPageKeys.count, WebKitBackend.maxPages)
        backend.closeIdlePages(now: Date().addingTimeInterval(WebKitBackend.idleLimit + 5))
        XCTAssertTrue(backend.openPageKeys.isEmpty)
    }

    // MARK: - The page itself

    func testAnOffScreenPageIsVisibleAndRunsAtFullRate() async throws {
        server.pages["/live"] = .html("""
        <!doctype html><title>live</title><body><script>
        let ticks = 0, frames = 0, polls = 0;
        setInterval(() => ticks++, 100);
        (function f() { frames++; requestAnimationFrame(f); })();
        setInterval(() => fetch('/poll').then(() => polls++), 250);
        window.rates = () => JSON.stringify({ ticks, frames, polls });
        </script></body>
        """)
        let backend = WebKitBackend()
        defer { backend.closeAll() }
        let page = backend.page(profile: profile, name: "main", options: .init())
        let outcome = await page.load(server.url("/live"))
        XCTAssertTrue(outcome.loaded, "\(outcome)")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let state = await page.state()
        XCTAssertEqual(state["visibility"]?.stringValue, "visible", "a hidden page stops polling and shows skeletons: \(state)")
        XCTAssertEqual(state["hidden"]?.boolValue, false)
        XCTAssertTrue(page.occlusionSPI, "the visibility SPI is missing on this macOS")
        let rates = try await page.script("return window.rates();", inPageWorld: true)
        XCTAssertGreaterThanOrEqual(rates["ticks"]?.intValue ?? 0, 14, "timers were throttled: \(rates)")
        XCTAssertGreaterThanOrEqual(rates["frames"]?.intValue ?? 0, 60, "animation frames were throttled: \(rates)")
        XCTAssertGreaterThanOrEqual(server.hits("/poll"), 6, "the page's polling fetches were throttled")
    }

    func testViewportColorSchemeAndScaleReachThePage() async throws {
        server.pages["/layout"] = .html("""
        <!doctype html><meta name=viewport content="width=device-width"><title>layout</title>
        <style>:root{color-scheme:light dark} body{margin:0;background:Canvas} .m{display:none} @media (max-width:500px){.m{display:block;height:50px;background:red}}</style>
        <div class=m></div><p>hello</p>
        """)
        let backend = WebKitBackend()
        defer { backend.closeAll() }
        let page = backend.page(profile: profile, name: "main", options: .init(width: 390, height: 844, colorScheme: .dark, scale: 3))
        _ = await page.load(server.url("/layout"))
        await page.settle()
        var state = await page.state()
        XCTAssertEqual(state["width"]?.intValue, 390)
        XCTAssertEqual(state["height"]?.intValue, 844)
        XCTAssertEqual(state["dark"]?.boolValue, true)
        XCTAssertEqual(state["dpr"]?.intValue, 3)
        let phone = try await page.image()
        XCTAssertEqual(phone.width, 1170)
        XCTAssertEqual(phone.height, 2532)
        XCTAssertLessThan(Self.luma(phone, x: 600, y: 2000), 0.35, "dark scheme must paint a dark page")

        page.apply(.init(width: 1440, height: 900, colorScheme: .light, scale: 1))
        await page.settle()
        state = await page.state()
        XCTAssertEqual(state["width"]?.intValue, 1440)
        XCTAssertEqual(state["dark"]?.boolValue, false)
        XCTAssertEqual(state["dpr"]?.intValue, 1)
        let desktop = try await page.image()
        XCTAssertEqual(desktop.width, 1440)
        XCTAssertEqual(desktop.height, 900)
        XCTAssertGreaterThan(Self.luma(desktop, x: 700, y: 700), 0.8, "light scheme must paint a light page")
    }

    func testACookieSurvivesTheViewAndIsPerProfile() async throws {
        server.pages["/c"] = .html("<!doctype html><title>c</title><p>cookie page</p>")
        let backend = WebKitBackend()
        defer { backend.closeAll() }
        let first = backend.page(profile: profile, name: "one", options: .init())
        _ = await first.load(server.url("/c"))
        _ = try await first.script("document.cookie = 'session=abc; max-age=3600; path=/'; localStorage.setItem('k','v'); return '1';", inPageWorld: true)
        backend.close(key: first.key)

        let second = backend.page(profile: profile, name: "two", options: .init())
        _ = await second.load(server.url("/c"))
        let seen = try await second.script("return JSON.stringify({ cookie: document.cookie, ls: localStorage.getItem('k') });", inPageWorld: true)
        XCTAssertEqual(seen["cookie"]?.stringValue, "session=abc")
        XCTAssertEqual(seen["ls"]?.stringValue, "v")

        extraProfiles.append("\(profile)-other")
        let other = backend.page(profile: "\(profile)-other", name: "one", options: .init())
        _ = await other.load(server.url("/c"))
        let isolated = try await other.script("return JSON.stringify({ cookie: document.cookie });", inPageWorld: true)
        XCTAssertEqual(isolated["cookie"]?.stringValue, "", "another profile must not see the cookie")
        backend.close(key: other.key)
    }

    func testAFailedLoadIsAnErrorAndNeverAnImage() async throws {
        let registry = ToolRegistry()
        let dead = try await call(registry, "open_url", ["browser": "webkit", "url": "http://127.0.0.1:1/never", "profile": profile])
        XCTAssertTrue(dead.isError, dead.text)
        XCTAssertTrue(dead.text.contains("Could not load"), dead.text)
        let shot = try await call(registry, "screenshot_window", ["browser": "webkit", "profile": profile])
        XCTAssertTrue(shot.isError, "a screenshot of a page that never loaded must not be an image")
        XCTAssertNil(shot.imageData)
    }

    // MARK: - Through the tools

    func testSnapshotClickAndTypeThroughTheTools() async throws {
        server.pages["/form"] = .html("""
        <!doctype html><title>form</title><body>
        <button id=go onclick="document.getElementById('out').textContent='clicked:' + event.isTrusted">Go</button>
        <label>Name <input id=name value="old text"></label>
        <select id=pick aria-label="Colour"><option>Red</option><option>Green</option></select>
        <div id=cover style="position:fixed;left:0;top:0;width:100%;height:100%;display:none"></div>
        <p id=out>none</p>
        <script>document.getElementById('name').addEventListener('keydown', e => window.lastKey = e.key + ':' + e.isTrusted);</script>
        """)
        let registry = ToolRegistry()
        let opened = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/form").absoluteString, "profile": profile, "width": 800, "height": 600])
        XCTAssertFalse(opened.isError, opened.text)
        XCTAssertEqual(opened.json["backend"]?.stringValue, "webkit")
        XCTAssertEqual(opened.json["visibility"]?.stringValue, "visible")
        XCTAssertEqual(opened.json["viewport"]?["width"]?.doubleValue, 800)

        let snap = try await call(registry, "snapshot", ["browser": "webkit", "profile": profile])
        let elements = snap.json["elements"]?.arrayValue ?? []
        func id(_ label: String) throws -> String {
            try XCTUnwrap(elements.first { $0["label"]?.stringValue == label }?["id"]?.stringValue, "no element labelled \(label) in \(elements)")
        }
        let button = try id("Go")
        let field = try id("Name")
        let select = try id("Colour")
        XCTAssertEqual(elements.first { $0["label"]?.stringValue == "Name" }?["value"]?.stringValue, "old text")

        let clicked = try await call(registry, "click", ["elementId": button])
        XCTAssertFalse(clicked.isError, clicked.text)
        let after = try await call(registry, "read_all_text", ["browser": "webkit", "profile": profile])
        XCTAssertTrue(after.json["text"]?.stringValue?.contains("clicked:true") ?? false, "the click was not a trusted pointer click: \(after.text)")

        let typed = try await call(registry, "type_text", ["elementId": field, "text": "new text"])
        XCTAssertFalse(typed.isError, typed.text)
        let value = try await call(registry, "read_text", ["elementId": field])
        XCTAssertEqual(value.json["text"]?.stringValue, "new text", "typing must replace the old content")
        let key = try await call(registry, "run_app_code", ["browser": "webkit", "profile": profile, "code": "window.lastKey", "consent": true])
        XCTAssertEqual(key.json["result"]?.stringValue, "t:true", "key events must be real keystrokes")

        let cleared = try await call(registry, "type_text", ["elementId": field, "text": ""])
        XCTAssertFalse(cleared.isError, cleared.text)
        let empty = try await call(registry, "read_text", ["elementId": field])
        XCTAssertEqual(empty.json["text"]?.stringValue, "", "empty text clears the field")

        let chosen = try await call(registry, "type_text", ["elementId": select, "text": "green"])
        XCTAssertFalse(chosen.isError, chosen.text)
        let option = try await call(registry, "run_app_code", ["browser": "webkit", "profile": profile, "code": "document.getElementById('pick').value", "consent": true])
        XCTAssertEqual(option.json["result"]?.stringValue, "Green")
        let nativeClick = try await call(registry, "click", ["elementId": select])
        XCTAssertTrue(nativeClick.isError, "a native menu must never be opened off screen")
    }

    func testAnIdFromBeforeANavigationIsRefused() async throws {
        server.pages["/a"] = .html("<!doctype html><title>a</title><button>Alpha</button>")
        server.pages["/b"] = .html("<!doctype html><title>b</title><button>Beta</button>")
        let registry = ToolRegistry()
        _ = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/a").absoluteString, "profile": profile])
        let snap = try await call(registry, "snapshot", ["browser": "webkit", "profile": profile])
        let alpha = try XCTUnwrap(snap.json["elements"]?.arrayValue?.first?["id"]?.stringValue)
        _ = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/b").absoluteString, "profile": profile])
        let stale = try await call(registry, "click", ["elementId": alpha])
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.text.contains("snapshot"), stale.text)
    }

    func testWaitForAnElementThatAppearsLater() async throws {
        server.pages["/late"] = .html("""
        <!doctype html><title>late</title><body><script>
        setTimeout(() => { const b = document.createElement('button'); b.textContent = 'Arrived'; document.body.appendChild(b); }, 700);
        </script>
        """)
        let registry = ToolRegistry()
        _ = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/late").absoluteString, "profile": profile, "settleMs": 0])
        let waited = try await call(registry, "wait_for_element", ["browser": "webkit", "profile": profile, "labelContains": "arrived", "timeout": 6])
        XCTAssertEqual(waited.json["found"]?.boolValue, true, waited.text)
        let missing = try await call(registry, "assert_not_visible", ["browser": "webkit", "profile": profile, "labelContains": "nothing like this", "timeout": 1])
        XCTAssertEqual(missing.json["passed"]?.boolValue, true, missing.text)
    }

    func testAnUnsupportedToolSaysSoInsteadOfMatchingAProcess() async throws {
        let registry = ToolRegistry()
        for tool in ["list_windows", "minimize_window", "quit_app", "get_frontmost_app"] {
            let result = try await call(registry, tool, ["app": "webkit"])
            XCTAssertTrue(result.isError, tool)
            XCTAssertTrue(result.text.contains("not supported on WebKit"), "\(tool): \(result.text)")
        }
    }

    func testAChromeDebugPortNeverTakesAWebKitCall() async throws {
        AttachedChrome.resolverOverride = { _ in 9333 }
        let before = BrowserNavigator.launchServicesOpens
        let result = try await call(ToolRegistry(), "open_url", ["browser": "webkit", "url": server.url("/x").absoluteString, "profile": profile])
        XCTAssertEqual(result.json["backend"]?.stringValue ?? "error", "webkit", result.text)
        XCTAssertEqual(BrowserNavigator.launchServicesOpens, before)
    }

    func testFullPageScreenshotIsTallerThanTheViewport() async throws {
        server.pages["/tall"] = .html("<!doctype html><title>t</title><body style='margin:0'><div style='height:2400px;background:linear-gradient(#fff,#08f)'>tall</div>")
        let registry = ToolRegistry()
        _ = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/tall").absoluteString, "profile": profile, "width": 400, "height": 300, "deviceScaleFactor": 1])
        let viewportOnly = try await call(registry, "screenshot_window", ["browser": "webkit", "profile": profile, "maxLongestSide": 5000, "format": "png"])
        let full = try await call(registry, "screenshot_window", ["browser": "webkit", "profile": profile, "fullPage": true, "maxLongestSide": 5000, "format": "png"])
        let small = try XCTUnwrap(viewportOnly.imageSize)
        let big = try XCTUnwrap(full.imageSize)
        XCTAssertEqual(small.height, 300)
        XCTAssertEqual(big.height, 2400)
        let restored = try await call(registry, "get_window_bounds", ["browser": "webkit", "profile": profile])
        XCTAssertEqual(restored.json["viewport"]?["height"]?.doubleValue, 300, "the viewport must be put back")
    }

    /// The sequence a QA agent runs: open, resize to a phone, dark, screenshot; one `run_steps`.
    func testTheQASequenceInOneRunSteps() async throws {
        server.pages["/dash"] = .html("""
        <!doctype html><meta name=viewport content="width=device-width"><title>Dash</title>
        <style>:root{color-scheme:light dark} body{margin:0;background:Canvas;color:CanvasText;font:16px sans-serif}</style>
        <h1>Dashboard</h1><button>Refresh</button>
        """)
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let registry = ToolRegistry()
        let url = server.url("/dash").absoluteString
        let steps: JSONValue = .array([
            .object(["tool": .string("open_url"), "args": .object(["browser": .string("webkit"), "url": .string(url), "profile": .string(profile), "width": .int(390), "height": .int(844), "colorScheme": .string("dark")])]),
            .object(["tool": .string("snapshot"), "args": .object(["browser": .string("webkit"), "profile": .string(profile)])]),
            .object(["tool": .string("screenshot_window"), "args": .object(["browser": .string("webkit"), "profile": .string(profile)])]),
        ])
        let ran = try await call(registry, "run_steps", ["steps": steps])
        XCTAssertFalse(ran.isError, ran.text)
        XCTAssertEqual(ran.json["ran"]?.intValue, 3, ran.text)
        let results = ran.json["results"]?.arrayValue ?? []
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0["isError"]?.boolValue != true }, ran.text)

        // And the real image, taken directly: a phone, dark.
        let shot = try await call(registry, "screenshot_window", ["browser": "webkit", "profile": profile, "maxLongestSide": 4000, "format": "png"])
        let size = try XCTUnwrap(shot.imageSize)
        XCTAssertEqual(size.width, 780)
        XCTAssertEqual(size.height, 1688)
        let decoded = try XCTUnwrap(shot.image)
        XCTAssertLessThan(Self.luma(decoded, x: 700, y: 1500), 0.35, "the phone screenshot must be the dark page, not a blank")
        let page = try XCTUnwrap(WebKitBackend.shared.page(key: WebKitBackend.key(profile: profile, name: "main")))
        let state = await page.state()
        XCTAssertEqual(state["dark"]?.boolValue, true)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontBefore, "rendering a page must not change the frontmost app")
    }

    func testDialogsAreAnsweredAndReported() async throws {
        server.pages["/dialog"] = .html("<!doctype html><title>d</title><script>alert('hello'); window.answer = confirm('sure?');</script><p>after</p>")
        let registry = ToolRegistry()
        let opened = try await call(registry, "open_url", ["browser": "webkit", "url": server.url("/dialog").absoluteString, "profile": profile])
        XCTAssertFalse(opened.isError, opened.text)
        let dialogs = opened.json["dialogs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(dialogs.count, 2, "\(dialogs)")
        let answer = try await call(registry, "run_app_code", ["browser": "webkit", "profile": profile, "code": "window.answer", "consent": true])
        XCTAssertEqual(answer.json["result"]?.boolValue, true)
    }

    // MARK: - Helpers

    /// Brightness (0...1) of one pixel.
    private static func luma(_ image: CGImage, x: Int, y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
    }

    private struct Reply {
        let raw: JSONValue
        var isError: Bool { raw["isError"]?.boolValue == true }
        var text: String { raw["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n") ?? "" }
        var json: JSONValue {
            guard let first = raw["content"]?.arrayValue?.first?["text"]?.stringValue, let data = first.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
            return value
        }
        var imageData: Data? {
            raw["content"]?.arrayValue?.first { $0["type"]?.stringValue == "image" }?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }
        }
        var image: CGImage? {
            guard let data = imageData, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        var imageSize: (width: Int, height: Int)? {
            guard let data = imageData, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (image.width, image.height)
        }
    }

    private func call(_ registry: ToolRegistry, _ tool: String, _ arguments: [String: Any]) async throws -> Reply {
        func value(_ any: Any) -> JSONValue {
            switch any {
            case let v as JSONValue: return v
            case let v as String: return .string(v)
            case let v as Bool: return .bool(v)
            case let v as Int: return .int(v)
            case let v as Double: return .double(v)
            default: return .null
            }
        }
        return Reply(raw: try await registry.callTool(name: tool, arguments: .object(arguments.mapValues(value))))
    }
}

/// A loopback HTTP server with a table of pages and a hit counter per path.
final class TestPageServer: @unchecked Sendable {
    struct Page {
        var status = 200
        var contentType = "text/html; charset=utf-8"
        var body: String
        var headers: [String: String] = [:]
        static func html(_ body: String) -> Page { Page(body: body) }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-page-server")
    private let lock = NSLock()
    private var table: [String: Page] = [:]
    private var counts: [String: Int] = [:]
    private(set) var port: UInt16 = 0

    var pages: [String: Page] {
        get { lock.lock(); defer { lock.unlock() }; return table }
        set { lock.lock(); table = newValue; lock.unlock() }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func hits(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path] ?? 0
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            throw NSError(domain: "TestPageServer", code: 1)
        }
        port = bound
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init)?.split(separator: "?").first.map(String.init) ?? "/"
            lock.lock()
            counts[path, default: 0] += 1
            let page = table[path] ?? (path == "/poll" ? Page(contentType: "text/plain", body: "ok") : Page(status: 404, body: "not found"))
            lock.unlock()
            let body = Data(page.body.utf8)
            let extra = page.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            let head = "HTTP/1.1 \(page.status) OK\r\nContent-Type: \(page.contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
