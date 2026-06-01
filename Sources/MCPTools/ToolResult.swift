import MCPServer
import Foundation

public struct ToolResult {
    public static func text(_ content: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(content),
                ])
            ])
        ])
    }

    public static func json(_ value: JSONValue) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value),
           let str = String(data: data, encoding: .utf8) {
            return text(str)
        }
        return text("{}")
    }

    public static func image(base64: String, mimeType: String = "image/png") -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("image"),
                    "data": .string(base64),
                    "mimeType": .string(mimeType),
                ])
            ])
        ])
    }

    public static func error(_ message: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Error: \(message)"),
                ])
            ]),
            "isError": .bool(true),
        ])
    }

    /// Structured outcome for interaction tools (click/type/scroll/…).
    ///
    /// A *real* miss (no element matched, or the AX action was refused) returns an
    /// `isError` result so the agent's control loop can tell "the UI didn't have what I
    /// asked for" apart from "the tool itself broke" — instead of the old `success:false`
    /// that collapsed both into one indistinguishable shape. A genuine success returns
    /// `{success, method, …extra}` as JSON.
    public static func action(success: Bool, method: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        guard success else {
            return error("Action could not be completed (method: \(method))")
        }
        var fields: [String: JSONValue] = [
            "success": .bool(true),
            "method": .string(method),
        ]
        for (key, value) in extra { fields[key] = value }
        return json(.object(fields))
    }
}

public enum ToolError: Error, LocalizedError {
    case missingParameter(String)
    case appNotFound(String)
    case appNotRunning(String)
    case elementNotFound
    case invalidParameter(String)
    case actionFailed(String)
    case timedOut(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .missingParameter(let p): return "Missing required parameter: \(p)"
        case .appNotFound(let app): return "App not found or not running: \(app)"
        case .appNotRunning(let app): return "App is no longer running: \(app)"
        case .elementNotFound: return "UI element not found matching criteria"
        case .invalidParameter(let p): return "Invalid parameter: \(p)"
        case .actionFailed(let what): return "Action failed: \(what)"
        case .timedOut(let what): return "Timed out: \(what)"
        case .notImplemented(let t): return "Tool not implemented: \(t)"
        }
    }
}
