import XCTest
import MCPServer
@testable import MCPTools

/// run_steps as the transport sees it: the result shape an agent pays tokens for, the nesting
/// bound, and cancellation reaching a batch that is already running. Every step here is a
/// tool registered by the test, so nothing touches Accessibility or the screen.
final class FlowTransportTests: XCTestCase {

    private func registry(registering tools: [String: @Sendable (JSONValue?) async throws -> JSONValue]) -> ToolRegistry {
        let registry = ToolRegistry()
        for (name, handler) in tools {
            registry.register(.init(name: name, description: "test", inputSchema: .object([:]), handler: handler))
        }
        return registry
    }

    private func runSteps(_ registry: ToolRegistry, _ steps: [JSONValue], stopOnError: Bool = true,
                          includeNestedMedia: Bool = false) async throws -> JSONValue {
        let result = try await registry.callTool(name: "run_steps", arguments: .object([
            "steps": .array(steps),
            "stopOnError": .bool(stopOnError),
            "includeNestedMedia": .bool(includeNestedMedia),
        ]))
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func step(_ tool: String, _ args: JSONValue = .object([:])) -> JSONValue {
        .object(["tool": .string(tool), "args": args])
    }

    // MARK: - Result shape

    /// The envelope-plus-escaped-string shape cost every step its payload twice. A step's result
    /// is now the payload itself.
    func testStepResultIsTheParsedPayloadNotAnEscapedEnvelope() async throws {
        let reg = registry(registering: [
            "probe": { _ in ToolResult.json(.object(["n": .int(1), "nested": .object(["quote": .string("a\"b")])])) },
        ])
        let parsed = try await runSteps(reg, [step("probe")])

        XCTAssertEqual(parsed["ran"]?.intValue, 1)
        XCTAssertNil(parsed["failedAt"])
        let entry = try XCTUnwrap(parsed["results"]?.arrayValue?.first)
        XCTAssertEqual(entry["tool"]?.stringValue, "probe")
        XCTAssertEqual(entry["isError"]?.boolValue, false)
        XCTAssertNil(entry["step"], "position in `results` is the index; no separate field")
        XCTAssertEqual(entry["result"]?["n"]?.intValue, 1, "payload is embedded as JSON, not as an escaped string")
        XCTAssertEqual(entry["result"]?["nested"]?["quote"]?.stringValue, #"a"b"#)
        XCTAssertNil(entry["result"]?["content"], "the MCP envelope is gone")
    }

    func testProseResultsStayStringsAndFailuresAreMarked() async throws {
        let reg = registry(registering: [
            "number_text": { _ in ToolResult.text("42") },
            "boom": { _ in ToolResult.error("it broke") },
        ])
        let parsed = try await runSteps(reg, [step("number_text"), step("boom"), step("number_text")])

        XCTAssertEqual(parsed["ran"]?.intValue, 2, "stops at the first failure")
        XCTAssertEqual(parsed["failedAt"]?.intValue, 1)
        let results = try XCTUnwrap(parsed["results"]?.arrayValue)
        XCTAssertEqual(results[0]["result"]?.stringValue, "42", "a scalar a tool returned as text is not reinterpreted")
        XCTAssertEqual(results[1]["isError"]?.boolValue, true)
        XCTAssertEqual(results[1]["result"]?.stringValue, "Error: it broke")
    }

    func testNestedImagesAreDescribedNotShippedByDefault() async throws {
        let reg = registry(registering: [
            "shot": { _ in ToolResult.image(base64: "aGVsbG8=", mimeType: "image/jpeg") },
        ])
        let omitted = try await runSteps(reg, [step("shot")])
        let descriptor = try XCTUnwrap(omitted["results"]?.arrayValue?.first?["result"])
        XCTAssertEqual(descriptor["omitted"]?.boolValue, true)
        XCTAssertEqual(descriptor["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertEqual(descriptor["approxBytes"]?.intValue, 6)
        XCTAssertNil(descriptor["data"])

        let kept = try await runSteps(reg, [step("shot")], includeNestedMedia: true)
        XCTAssertEqual(kept["results"]?.arrayValue?.first?["result"]?["data"]?.stringValue, "aGVsbG8=")
    }

    /// FocusWatcher incidents and browser-choice notes ride behind the payload as extra text
    /// items; they must stay visible, as strings, without displacing the payload.
    func testAppendedNoticesSurviveFlattening() {
        let withNotice = ToolResult.appendingNotice("Focus moved", to: ToolResult.json(.object(["ok": .bool(true)])))
        let flat = FlowTools.flattenStepResult(withNotice, includeNestedMedia: false)
        XCTAssertEqual(flat.value["ok"]?.boolValue, true)
        XCTAssertEqual(flat.notices, [.string("Focus moved")])
    }

    func testSizeIsReadFromUTF8LengthOfBase64() {
        let big = String(repeating: "A", count: 4_000_000)
        let flat = FlowTools.flattenStepResult(ToolResult.image(base64: big), includeNestedMedia: false)
        XCTAssertEqual(flat.value["approxBytes"]?.intValue, 3_000_000)
    }

    func testToolResultJSONKeepsItsPayloadWhenANumberIsNotFinite() throws {
        let result = ToolResult.json(.object(["frame": .double(.nan), "count": .int(3)]))
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertNil(result["isError"], "a NaN must not cost the caller the whole snapshot")
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(parsed["count"]?.intValue, 3)
        XCTAssertEqual(parsed["frame"], .null)
    }

    // MARK: - Nesting bound

    /// steps(n): n flow engines deep, innermost running one harmless tool.
    private func nested(_ depth: Int) -> [JSONValue] {
        depth <= 1
            ? [step("list_flows")]
            : [step("run_steps", .object(["steps": .array(nested(depth - 1))]))]
    }

    /// Follows `results[0].result` down through nested run_steps summaries to the innermost
    /// step's own result (a string for an error, an object for a payload).
    private func innermost(_ summary: JSONValue) -> JSONValue {
        var current = summary
        while current["results"] != nil, let inner = current["results"]?.arrayValue?.first?["result"] {
            if inner["results"] == nil { return inner }
            current = inner
        }
        return current
    }

    func testFlowsMayNestToTheLimit() async throws {
        let parsed = try await runSteps(ToolRegistry(), nested(FlowTools.maxFlowDepth))
        XCTAssertNotNil(innermost(parsed)["flows"], "the innermost list_flows should have run: \(parsed)")
    }

    /// A flow that runs itself would otherwise recurse until the process died. The refusal is
    /// the innermost step's result: an error string instead of another level of recursion.
    func testFlowsDeeperThanTheLimitFailInsteadOfRecursing() async throws {
        let parsed = try await runSteps(ToolRegistry(), nested(FlowTools.maxFlowDepth + 1))
        let message = innermost(parsed).stringValue
        XCTAssertTrue(message?.contains("nested more than \(FlowTools.maxFlowDepth)") == true,
                      "got: \(String(describing: message))")
    }

    func testDepthIsScopedToTheRunAndDoesNotLeak() async throws {
        _ = try await runSteps(ToolRegistry(), nested(3))
        XCTAssertEqual(FlowTools.flowDepth, 0)
    }

    // MARK: - Cancellation

    /// Cancelling a batch mid-step must stop it: the parked step sees the cancellation, the
    /// steps after it never start, and the caller gets CancellationError rather than a result
    /// built from whatever had finished.
    func testCancellingARunStopsTheStepInFlightAndSkipsTheRest() async throws {
        let started = Counter(), cancelled = Counter(), after = Counter()
        let reg = registry(registering: [
            "park": { _ in
                started.bump()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled.bump(); throw error }
                return ToolResult.text("never")
            },
            "after": { _ in after.bump(); return ToolResult.text("ran") },
        ])
        let run = Task { try await reg.callTool(name: "run_steps", arguments: .object([
            "steps": .array([step("park"), step("after")]),
            "stopOnError": .bool(false),
        ])) }
        let parked = await eventually { started.value == 1 }
        XCTAssertTrue(parked)

        run.cancel()
        do {
            _ = try await run.value
            XCTFail("a cancelled run returned a result")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(cancelled.value, 1)
        XCTAssertEqual(after.value, 0, "steps after the cancelled one must not run, even with stopOnError off")
    }

    func testCancellationStopsBetweenStepsEvenWhenEachStepIsInstant() async throws {
        let ran = Counter()
        let gate = Gate()
        let reg = registry(registering: [
            "tick": { _ in
                ran.bump()
                await gate.wait()
                return ToolResult.text("tick")
            },
        ])
        let run = Task { try await reg.callTool(name: "run_steps", arguments: .object([
            "steps": .array((0..<50).map { _ in step("tick") }),
        ])) }
        let first = await eventually { ran.value == 1 }
        XCTAssertTrue(first)
        run.cancel()
        await gate.open()
        _ = try? await run.value
        XCTAssertLessThan(ran.value, 50, "the loop kept running steps after the run was cancelled")
    }
}

/// A one-shot latch: `wait` parks until `open`, then never blocks again.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
