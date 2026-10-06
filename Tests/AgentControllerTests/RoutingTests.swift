import XCTest
@testable import MCPTools
import MCPServer
#if canImport(Darwin)
import Darwin
#endif

final class RoutingTests: XCTestCase {
    func testIdentityParsesURL() {
        let id = TargetIdentity(raw: "https://example.com/app")
        XCTAssertEqual(id.kind, .url)
        XCTAssertTrue(id.isHTTP)
        XCTAssertEqual(id.url?.host, "example.com")
    }

    func testIdentityParsesUDIDAndBooted() {
        let udid = TargetIdentity(raw: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(udid.kind, .iosSimulator)
        XCTAssertEqual(udid.udid, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(TargetIdentity(raw: "booted").kind, .iosSimulator)
        XCTAssertEqual(TargetIdentity(raw: "sim:booted").udid, "booted")
    }

    func testIdentityParsesPIDAndBundle() {
        let pid = TargetIdentity(raw: "12345")
        XCTAssertEqual(pid.kind, .processID)
        XCTAssertEqual(pid.pid, 12345)
        let app = TargetIdentity(raw: "com.apple.TextEdit")
        XCTAssertEqual(app.kind, .application)
        XCTAssertEqual(app.bundleHint, "com.apple.TextEdit")
    }

    /// The bug this guards: `{app: Safari, url: …}` used to become a URL identity, which
    /// always routes to Chromium. The named app must win; the url is just where to go.
    func testExplicitAppBeatsURL() {
        let args = JSONValue.object([
            "app": .string("Safari"),
            "url": .string("https://localhost:3000"),
        ])
        let id = TargetIdentity.from(arguments: args)
        XCTAssertEqual(id?.kind, .application)
        XCTAssertEqual(id?.raw, "Safari")
        XCTAssertEqual(TargetIdentity.pageURL(arguments: args)?.absoluteString, "https://localhost:3000")
    }

    func testURLOnlyStillParsesAsURL() {
        let id = TargetIdentity.from(arguments: .object(["url": .string("https://x.test")]))
        XCTAssertEqual(id?.kind, .url)
    }

    func testSafariPrefixFrom280StillWorks() {
        let args = JSONValue.object(["app": .string("safari:https://example.com/a")])
        XCTAssertEqual(TargetIdentity.from(arguments: args)?.raw, "com.apple.Safari")
        XCTAssertEqual(TargetIdentity.pageURL(arguments: args)?.absoluteString, "https://example.com/a")
        // A custom-scheme app string is never misread as a browser prefix.
        XCTAssertNil(TargetIdentity.splitBrowserPrefix("myapp:route"))
    }

    func testBrowserNamesResolve() {
        XCTAssertTrue(BrowserResolver.isBrowserName("Safari"))
        XCTAssertTrue(BrowserResolver.isBrowserName("com.apple.Safari"))
        XCTAssertTrue(BrowserResolver.isBrowserName("google chrome"))
        XCTAssertFalse(BrowserResolver.isBrowserName("TextEdit"))
        // Safari ships with macOS, so it always resolves on a Mac.
        XCTAssertEqual(BrowserResolver.named("safari")?.bundleId, "com.apple.Safari")
        XCTAssertNil(BrowserResolver.named("netscape navigator"))
    }

    func testNamedBrowserIsNeverSubstituted() throws {
        XCTAssertEqual(try BrowserResolver.choose(browser: "safari", app: nil, headless: nil),
                       .browser(BrowserResolver.named("safari")!))
        XCTAssertEqual(try BrowserResolver.choose(browser: nil, app: "com.apple.Safari", headless: nil),
                       .browser(BrowserResolver.named("safari")!))
        XCTAssertThrowsError(try BrowserResolver.choose(browser: "netscape navigator", app: nil, headless: nil))
        XCTAssertEqual(try BrowserResolver.choose(browser: "headless", app: nil, headless: nil), .headless)
    }

    /// Owner's policy, decision 1: nothing named → the user's DEFAULT browser, never a
    /// hidden Chromium. This is the "it always picks Chrome" bug, pinned.
    func testNothingNamedGoesToDefaultBrowser() throws {
        XCTAssertEqual(try BrowserResolver.choose(browser: nil, app: nil, headless: nil),
                       .browser(BrowserResolver.systemDefault()!))
        XCTAssertEqual(try BrowserResolver.choose(browser: "default", app: nil, headless: nil),
                       .browser(BrowserResolver.systemDefault()!))
    }

    /// Owner's policy, decision 2: a named browser beats headless:true — on macOS the real
    /// browser already runs in the background without focus. headless only when asked
    /// for with no browser named.
    func testNamedBrowserBeatsHeadlessFlag() throws {
        let safari = BrowserResolver.named("safari")!
        XCTAssertEqual(try BrowserResolver.choose(browser: "safari", app: nil, headless: true), .browser(safari))
        XCTAssertEqual(try BrowserResolver.choose(browser: nil, app: "Safari", headless: true), .browser(safari))
        XCTAssertEqual(try BrowserResolver.choose(browser: nil, app: nil, headless: true), .headless)
    }

    func testNavigationMatchToleratesRedirects() {
        let want = URL(string: "https://example.com/docs")!
        XCTAssertTrue(BrowserNavigator.matches("https://www.example.com/docs/", want))
        XCTAssertTrue(BrowserNavigator.matches("https://example.com/docs/intro?x=1", want))
        XCTAssertFalse(BrowserNavigator.matches("https://github.com/docs", want))
        XCTAssertFalse(BrowserNavigator.matches(nil, want))
    }

    func testClassifyRoutesKnownIdentities() {
        XCTAssertEqual(CapabilityProbe.classify(TargetIdentity(raw: "https://x.test")).backend, .cdp)
        XCTAssertEqual(CapabilityProbe.classify(TargetIdentity(raw: "org.blenderfoundation.blender")).backend, .blenderLab)
        XCTAssertEqual(CapabilityProbe.classify(TargetIdentity(raw: "Blender")).backend, .blenderLab)
        XCTAssertEqual(CapabilityProbe.classify(TargetIdentity(raw: "com.google.Chrome")).backend, .cdp)
        XCTAssertEqual(CapabilityProbe.classify(TargetIdentity(raw: "Safari")).backend, .ax)
        XCTAssertEqual(CapabilityProbe.classify(TargetIdentity(raw: "com.apple.TextEdit")).backend, .ax)
        XCTAssertEqual(CapabilityProbe.classify(TargetIdentity(raw: "booted")).backend, .iosSim)
    }

    func testCDPFlattenKeepsInteractiveNodes() {
        let nodes: [JSONValue] = [
            .object([
                "ignored": .bool(false),
                "role": .object(["value": .string("button")]),
                "name": .object(["value": .string("Save")]),
                "backendDOMNodeId": .int(42),
            ]),
            .object([
                "ignored": .bool(false),
                "role": .object(["value": .string("generic")]),
                "name": .object(["value": .string("layout")]),
                "backendDOMNodeId": .int(7),
            ]),
            .object([
                "ignored": .bool(true),
                "role": .object(["value": .string("button")]),
                "backendDOMNodeId": .int(9),
            ]),
        ]
        let refs = CDPAccessibility.flatten(nodes: nodes, interactiveOnly: true, sessionKey: "https://x")
        XCTAssertEqual(refs.count, 1)
        if case .cdp(let key, let nodeId, let role, let label) = refs[0] {
            XCTAssertEqual(key, "https://x")
            XCTAssertEqual(nodeId, 42)
            XCTAssertEqual(role, "button")
            XCTAssertEqual(label, "Save")
        } else {
            XCTFail("expected cdp ref")
        }
        let ids = ["e1"]
        let compact = CDPAccessibility.compactElements(ids: ids, refs: refs)
        XCTAssertEqual(compact.first?["id"]?.stringValue, "e1")
        XCTAssertEqual(compact.first?["label"]?.stringValue, "Save")
    }

    func testBlenderLabFramingRoundTrip() throws {
        let encoded = try BlenderProtocol.encodeLab(code: "result={'ok': True}")
        XCTAssertEqual(encoded.last, 0)
        let decoded = try BlenderProtocol.decodeLab(encoded)
        XCTAssertEqual(decoded["type"]?.stringValue, "execute")
        XCTAssertEqual(decoded["code"]?.stringValue, "result={'ok': True}")
        XCTAssertEqual(decoded["strict_json"]?.boolValue, true)
        XCTAssertTrue(BlenderProtocol.isLabSuccess(.object(["status": .string("ok"), "result": .object(["ok": .bool(true)])])))
    }

    func testRunStepsOmitsNestedImages() {
        let image = ToolResult.image(base64: "aGVsbG8=", mimeType: "image/jpeg")
        let compact = FlowTools.flattenStepResult(image, includeNestedMedia: false).value
        XCTAssertEqual(compact["omitted"]?.boolValue, true)
        XCTAssertEqual(compact["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertNil(compact["data"], "the base64 payload must not survive")
        let kept = FlowTools.flattenStepResult(image, includeNestedMedia: true).value
        XCTAssertEqual(kept["type"]?.stringValue, "image")
        XCTAssertEqual(kept["data"]?.stringValue, "aGVsbG8=")
    }

    func testInspectCapabilitiesIsRegisteredReadOnly() async throws {
        let registry = ToolRegistry()
        let names = Set(registry.listTools().compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(names.contains("inspect_capabilities"))
        XCTAssertTrue(names.contains("run_app_code"))
        XCTAssertTrue(ToolRegistry.readOnlyTools.contains("inspect_capabilities"))
        XCTAssertFalse(ToolRegistry.readOnlyTools.contains("run_app_code"))

        let result = try await registry.callTool(
            name: "inspect_capabilities",
            arguments: .object(["target": .string("com.apple.TextEdit")])
        )
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("\"backend\":\"ax\""), text)
        XCTAssertFalse(result["isError"]?.boolValue ?? false)
    }

    func testRunAppCodeOnNativeAppErrorsWithoutPretending() async throws {
        let registry = ToolRegistry()
        let result = try await registry.callTool(
            name: "run_app_code",
            arguments: .object([
                "app": .string("com.apple.TextEdit"),
                "code": .string("print(1)"),
                "consent": .bool(true),
            ])
        )
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("No in-process backend"), text)
    }

    func testConsentPersistsInOverrideFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("consent.json").path
        setenv("AGENTCONTROLLER_CONSENT_PATH", path, 1)
        defer {
            unsetenv("AGENTCONTROLLER_CONSENT_PATH")
            try? FileManager.default.removeItem(at: dir)
        }
        let store = CodeExecConsent()
        XCTAssertFalse(store.isGranted("bpy"))
        store.grant("bpy")
        XCTAssertTrue(store.isGranted("bpy"))
        XCTAssertTrue(CodeExecConsent().isGranted("bpy"))
    }

    func testInitializeInstructionsMentionRouter() async {
        let handler = MCPProtocolHandler(toolProvider: ToolRegistry())
        let request = JSONRPCRequest(
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-06-18")]),
            id: .int(1)
        )
        let data = try! JSONEncoder().encode(request)
        let responseData = await handler.handleRequest(data)!
        let response = try! JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        let instructions = response.result?["instructions"]?.stringValue ?? ""
        XCTAssertTrue(instructions.contains("You never pick Playwright vs AX vs bpy vs idb"))
        XCTAssertTrue(instructions.contains("inspect_capabilities"))
        XCTAssertTrue(instructions.contains("run_app_code"))
    }
}
