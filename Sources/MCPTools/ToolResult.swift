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
}

public enum ToolError: Error, LocalizedError {
    case missingParameter(String)
    case appNotFound(String)
    case elementNotFound
    case invalidParameter(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .missingParameter(let p): return "Missing required parameter: \(p)"
        case .appNotFound(let app): return "App not found or not running: \(app)"
        case .elementNotFound: return "UI element not found matching criteria"
        case .invalidParameter(let p): return "Invalid parameter: \(p)"
        case .notImplemented(let t): return "Tool not implemented: \(t)"
        }
    }
}
