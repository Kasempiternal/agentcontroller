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

    func testIdentityFromArgumentsPrefersURL() {
        let args = JSONValue.object([
            "app": .string("com.google.Chrome"),
            "url": .string("https://localhost:3000"),
        ])
        let id = TargetIdentity.from(arguments: args)
        XCTAssertEqual(id?.kind, .url)
        XCTAssertEqual(id?.raw, "https://localhost:3000")
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
        let compact = FlowTools.compactStepResult(image, includeNestedMedia: false)
        XCTAssertEqual(compact["nestedMediaOmitted"]?.boolValue, true)
        let text = compact["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("omitted"))
        XCTAssertFalse(text.contains("aGVsbG8="))
        let kept = FlowTools.compactStepResult(image, includeNestedMedia: true)
        XCTAssertEqual(kept["content"]?.arrayValue?.first?["type"]?.stringValue, "image")
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
