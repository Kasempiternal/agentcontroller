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
    /// `~/Library/Application Support/Macoestro/flows`
    private static var flowsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Macoestro/flows", isDirectory: true)
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
            description: "Run an ordered list of tool steps inline. Each step is {tool, args}. Returns {ran, failedAt?, results}. With stopOnError (default true) it aborts at the first step whose result isError; otherwise it runs them all. Use to compose multi-step QA flows (click → type → assert).",
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
                ]),
                "required": .array([.string("steps")]),
            ]),
            handler: { args in
                guard let steps = args?["steps"]?.arrayValue else {
                    throw ToolError.missingParameter("steps")
                }
                let stopOnError = args?["stopOnError"]?.boolValue ?? true
                return try await runSteps(steps, stopOnError: stopOnError, registry: registry)
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
            description: "Load a saved flow by name and run it through the same engine as run_steps. Returns {ran, failedAt?, results}.",
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
                return try await runSteps(steps, stopOnError: stopOnError, registry: registry)
            }
        ))
    }

    // MARK: - Engine

    /// Shared engine for run_steps and run_saved_flow. Calls back into the registry per
    /// step, records each result, and honors stopOnError by aborting on the first `isError`.
    private static func runSteps(_ steps: [JSONValue], stopOnError: Bool,
                                 registry: ToolRegistry) async throws -> JSONValue {
        var results: [JSONValue] = []
        var failedAt: Int? = nil

        for (i, step) in steps.enumerated() {
            guard let toolName = step["tool"]?.stringValue else {
                let msg = "step \(i) missing 'tool'"
                results.append(.object([
                    "step": .int(i),
                    "tool": .null,
                    "isError": .bool(true),
                    "result": ToolResult.error(msg),
                ]))
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
            } catch {
                result = ToolResult.error(error.localizedDescription)
            }
            let isError = (result["isError"]?.boolValue) ?? false

            results.append(.object([
                "step": .int(i),
                "tool": .string(toolName),
                "isError": .bool(isError),
                "result": result,
            ]))

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

    /// Resolve a flow name to its on-disk file, rejecting path-traversal in the name.
    private static func fileURL(for name: String) throws -> URL {
        let sanitized = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        guard !sanitized.isEmpty else { throw ToolError.invalidParameter("name") }
        return flowsDirectory.appendingPathComponent("\(sanitized).json")
    }
}
