import Foundation
import MCPServer
import AccessibilityEngine

/// Replayable flows. A flow is just an ordered list of `{tool, args}` steps. `run_steps`
/// executes them inline by calling back into the registry (so every existing tool composes);
/// `save_flow` / `list_flows` / `run_saved_flow` persist and replay them from disk. This is
/// what turns the one-shot tools into a regression suite an agent can record once and re-run.
///
/// The handlers capture `registry` so they can invoke `registry.callTool(...)`. `ToolRegistry`
/// is `@unchecked Sendable`, so capturing it in the `@Sendable` closures is safe.
struct FlowTools {
    /// `~/Library/Application Support/AgentController/flows`
    private static var flowsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentController/flows", isDirectory: true)
    }

    static func register(in registry: ToolRegistry) {
        registerRunSteps(in: registry)
        registerSaveFlow(in: registry)
        registerListFlows(in: registry)
        registerRunSavedFlow(in: registry)
    }

    // MARK: - run_steps

    private static func registerRunSteps(in registry: ToolRegistry) {
        registry.register(.init(
            name: "run_steps",
            description: "THE default way to drive a UI: run an ordered list of tool steps in ONE call instead of one call per action. Each step is {tool, args} naming any tool in this server. Returns {ran, failedAt?, results}, where results[i] is {tool, isError, result} for step i and result is that tool's own payload (parsed JSON, or text for an error). Nested screenshot/image payloads are omitted from step results by default so a batch stays token-cheap (includeNestedMedia:true to keep them). With stopOnError (default true) it aborts at the first step whose result isError; otherwise it runs them all. Pair it with a single `snapshot` — take the element ids from the snapshot, then send the whole click → type → click → assert sequence as one run_steps. Steps may name DIFFERENT `app` values, so driving several apps is still one call. Every step re-enters the same dispatcher, so permission and Focus Guard rules apply exactly as they would to a direct call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "steps": .object([
                        "type": .string("array"),
                        "description": .string("Ordered steps. Each: {\"tool\": \"<tool name>\", \"args\": { ... }}"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "tool": .object(["type": .string("string")]),
                                "args": .object(["type": .string("object")]),
                            ]),
                            "required": .array([.string("tool")]),
                        ]),
                    ]),
                    "stopOnError": .object(["type": .string("boolean"), "description": .string("Abort at the first failing step (default true)")]),
                    "includeNestedMedia": .object(["type": .string("boolean"), "description": .string("Keep nested screenshot/image payloads in step results (default false)")]),
                ]),
                "required": .array([.string("steps")]),
            ]),
            handler: { args in
                guard let steps = args?["steps"]?.arrayValue else {
                    throw ToolError.missingParameter("steps")
                }
                let stopOnError = args?["stopOnError"]?.boolValue ?? true
                let includeNestedMedia = args?["includeNestedMedia"]?.boolValue ?? false
                return try await runSteps(steps, stopOnError: stopOnError, includeNestedMedia: includeNestedMedia, registry: registry)
            }
        ))
    }

    // MARK: - save_flow

    private static func registerSaveFlow(in registry: ToolRegistry) {
        registry.register(.init(
            name: "save_flow",
            description: "Persist a named flow (ordered list of {tool, args} steps) to disk for later replay with run_saved_flow. Overwrites an existing flow of the same name.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Flow name (used as the filename)")]),
                    "steps": .object([
                        "type": .string("array"),
                        "description": .string("Ordered steps, same shape as run_steps"),
                        "items": .object(["type": .string("object")]),
                    ]),
                ]),
                "required": .array([.string("name"), .string("steps")]),
            ]),
            handler: { args in
                guard let name = args?["name"]?.stringValue, !name.isEmpty else {
                    throw ToolError.missingParameter("name")
                }
                guard let steps = args?["steps"]?.arrayValue else {
                    throw ToolError.missingParameter("steps")
                }
                let url = try fileURL(for: name)
                try FileManager.default.createDirectory(at: flowsDirectory, withIntermediateDirectories: true)

                let payload = JSONValue.object(["name": .string(name), "steps": .array(steps)])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(payload)
                try data.write(to: url, options: .atomic)

                return ToolResult.json(.object([
                    "saved": .bool(true),
                    "name": .string(name),
                    "path": .string(url.path),
                    "steps": .int(steps.count),
                ]))
            }
        ))
    }

    // MARK: - list_flows

    private static func registerListFlows(in registry: ToolRegistry) {
        registry.register(.init(
            name: "list_flows",
            description: "List the names of saved flows that can be replayed with run_saved_flow.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                let dir = flowsDirectory
                let names: [String]
                if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    names = contents
                        .filter { $0.pathExtension == "json" }
                        .map { $0.deletingPathExtension().lastPathComponent }
                        .sorted()
                } else {
                    names = []
                }
                return ToolResult.json(.object([
                    "count": .int(names.count),
                    "flows": .array(names.map { .string($0) }),
                ]))
            }
        ))
    }

    // MARK: - run_saved_flow

    private static func registerRunSavedFlow(in registry: ToolRegistry) {
        registry.register(.init(
            name: "run_saved_flow",
            description: "Load a saved flow by name and run it through the same engine as run_steps. Returns {ran, failedAt?, results}, shaped as in run_steps. Flows may nest (a flow can run another) up to 4 levels deep.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Saved flow name")]),
                    "stopOnError": .object(["type": .string("boolean"), "description": .string("Abort at the first failing step (default true)")]),
                ]),
                "required": .array([.string("name")]),
            ]),
            handler: { args in
                guard let name = args?["name"]?.stringValue, !name.isEmpty else {
                    throw ToolError.missingParameter("name")
                }
                let stopOnError = args?["stopOnError"]?.boolValue ?? true
                let url = try fileURL(for: name)
                guard let data = try? Data(contentsOf: url) else {
                    return ToolResult.error("Flow not found: \(name)")
                }
                let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
                guard let steps = decoded["steps"]?.arrayValue else {
                    return ToolResult.error("Saved flow '\(name)' has no steps array")
                }
                let includeNestedMedia = args?["includeNestedMedia"]?.boolValue ?? false
                return try await runSteps(steps, stopOnError: stopOnError, includeNestedMedia: includeNestedMedia, registry: registry)
            }
        ))
    }

    // MARK: - Engine

    /// Cap on flow-in-flow nesting. A saved flow can call `run_saved_flow` (itself included),
    /// and each level re-enters this engine, so an unbounded chain is a stack and memory
    /// bomb sitting behind one innocuous tool call.
    static let maxFlowDepth = 4

    /// How many flow engines enclose the current call. A task-local rather than a parameter
    /// because the nesting passes through `registry.callTool`, which has no room for one.
    @TaskLocal static var flowDepth = 0

    /// Shared engine for run_steps and run_saved_flow. Calls back into the registry per
    /// step, records each result, and honors stopOnError by aborting on the first `isError`.
    ///
    /// Result shape: `{ran, failedAt?, results}`, with `results[i]` describing step `i`
    /// (position is the index, so there is no separate field for it). Each entry is
    /// `{tool, isError, result, notices?}` where `result` is the step's own payload — parsed
    /// JSON when the tool returned JSON, a string otherwise — not the MCP envelope wrapping an
    /// escaped copy of it: every quote and backslash in a payload was doubled, and every step
    /// paid for a `content` array around it.
    static func runSteps(_ steps: [JSONValue], stopOnError: Bool,
                         includeNestedMedia: Bool = false,
                         registry: ToolRegistry) async throws -> JSONValue {
        guard flowDepth < maxFlowDepth else {
            return ToolResult.error("Flows are nested more than \(maxFlowDepth) levels deep (a flow that runs itself?)")
        }
        return try await $flowDepth.withValue(flowDepth + 1) {
            try await execute(steps, stopOnError: stopOnError,
                              includeNestedMedia: includeNestedMedia, registry: registry)
        }
    }

    private static func execute(_ steps: [JSONValue], stopOnError: Bool,
                                includeNestedMedia: Bool,
                                registry: ToolRegistry) async throws -> JSONValue {
        var results: [JSONValue] = []
        var failedAt: Int? = nil

        for (i, step) in steps.enumerated() {
            // A cancelled run stops between steps; a step already in flight is stopped by
            // the tool's own cancellation points: every poll loop paces itself through
            // `AXExecutor.pause` or `Task.sleep`, and both throw CancellationError.
            try Task.checkCancellation()
            guard let toolName = step["tool"]?.stringValue else {
                results.append(stepEntry(tool: .null,
                                         result: ToolResult.error("step \(i) missing 'tool'"),
                                         includeNestedMedia: includeNestedMedia))
                failedAt = i
                if stopOnError { break } else { continue }
            }
            let stepArgs = step["args"] ?? .object([:])
            // A handler that THROWS (missing param, unresolvable app) must be
            // recorded like an isError result — not abort the loop and discard
            // every accumulated step result.
            let result: JSONValue
            do {
                result = try await registry.callTool(name: toolName, arguments: stepArgs)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result = ToolResult.error(error.localizedDescription)
            }
            let isError = (result["isError"]?.boolValue) ?? false
            results.append(stepEntry(tool: .string(toolName), result: result,
                                     includeNestedMedia: includeNestedMedia))

            if isError {
                failedAt = i
                if stopOnError { break }
            }
        }

        var summary: [String: JSONValue] = [
            "ran": .int(results.count),
            "results": .array(results),
        ]
        if let failedAt { summary["failedAt"] = .int(failedAt) }
        return ToolResult.json(.object(summary))
    }

    private static func stepEntry(tool: JSONValue, result: JSONValue, includeNestedMedia: Bool) -> JSONValue {
        let flat = flattenStepResult(result, includeNestedMedia: includeNestedMedia)
        var entry: [String: JSONValue] = [
            "tool": tool,
            "isError": .bool((result["isError"]?.boolValue) ?? false),
            "result": flat.value,
        ]
        if !flat.notices.isEmpty { entry["notices"] = .array(flat.notices) }
        return .object(entry)
    }

    /// A tool result is `content: [item, notice…]`: one payload item, plus any text notices
    /// the dispatcher appended (a Focus Watcher incident, a browser-choice note). Returns the
    /// payload itself and the notices as plain strings.
    ///
    /// Image items are replaced by a descriptor unless the caller asked to keep them: a
    /// screenshot inside run_steps otherwise ships the JPEG on every step of the batch, which
    /// is exactly the token/turn tax batching is meant to avoid. The size is read off the
    /// base64 string's UTF-8 length (O(1) for a native string); `String.count` walks every
    /// grapheme of a multi-megabyte string.
    static func flattenStepResult(_ result: JSONValue, includeNestedMedia: Bool) -> (value: JSONValue, notices: [JSONValue]) {
        guard let items = result["content"]?.arrayValue, let payload = items.first else {
            return (result, [])
        }
        let notices = items.dropFirst().map { item -> JSONValue in
            if item["type"]?.stringValue == "text", let text = item["text"]?.stringValue { return .string(text) }
            return flattenItem(item, includeNestedMedia: includeNestedMedia)
        }
        return (flattenItem(payload, includeNestedMedia: includeNestedMedia), notices)
    }

    private static func flattenItem(_ item: JSONValue, includeNestedMedia: Bool) -> JSONValue {
        switch item["type"]?.stringValue {
        case "image":
            guard !includeNestedMedia else { return item }
            return .object([
                "omitted": .bool(true),
                "kind": .string("image"),
                "mimeType": .string(item["mimeType"]?.stringValue ?? "image"),
                "approxBytes": .int(((item["data"]?.stringValue?.utf8.count ?? 0) * 3) / 4),
            ])
        case "text":
            guard let text = item["text"]?.stringValue else { return item }
            return parsedJSON(text) ?? .string(text)
        default:
            return item
        }
    }

    /// The JSON value inside `text`, only when it is an object or array. Scalars stay text:
    /// a tool that returned the string "42" or "true" meant a string.
    private static func parsedJSON(_ text: String) -> JSONValue? {
        guard let first = text.utf8.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x09 && $0 != 0x0D }),
              first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return nil }
        // JSONSerialization + a manual walk measured 25ms on a 500KB snapshot payload, against
        // 70ms for JSONDecoder into JSONValue (whose init probes six types per node by throwing).
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        return jsonValue(from: object)
    }

    private static func jsonValue(from object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number) ? .double(number.doubleValue) : .int(number.intValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(jsonValue(from:)))
        case let dict as [String: Any]:
            return .object(dict.mapValues(jsonValue(from:)))
        default:
            return .null
        }
    }

    /// Resolve a flow name to its on-disk file, rejecting path-traversal in the name.
    private static func fileURL(for name: String) throws -> URL {
        let sanitized = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        guard !sanitized.isEmpty else { throw ToolError.invalidParameter("name") }
        return flowsDirectory.appendingPathComponent("\(sanitized).json")
    }
}
