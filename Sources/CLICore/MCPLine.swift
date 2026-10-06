import Foundation

/// Splits a byte stream into newline-delimited lines. MCP's stdio transport is exactly that:
/// one JSON-RPC message per line, with no embedded newlines.
///
/// A line can be megabytes (a `run_steps` batch), so the scan resumes where the last chunk
/// left off instead of re-reading everything buffered so far.
public struct LineFramer {
    private var buffer = Data()
    private var scanned = 0

    public init() {}

    /// Complete lines now available, terminator removed. Blank lines are dropped: the
    /// transport has no use for them, and forwarding one only earns a parse error.
    public mutating func push(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var lines: [Data] = []
        var lineStart = 0
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var from = scanned
            while from < raw.count,
                  let hit = memchr(base + from, 0x0A, raw.count - from) {
                let newline = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                lines.append(Data(bytes: base + lineStart, count: newline - lineStart))
                lineStart = newline + 1
                from = lineStart
            }
        }
        if lineStart > 0 { buffer.removeSubrange(0..<lineStart) }
        scanned = buffer.count
        return lines.compactMap(Self.normalized)
    }

    /// The unterminated tail at end of input, if any. A client that exits without a final
    /// newline has still sent that message.
    public mutating func finish() -> Data? {
        defer { buffer.removeAll(); scanned = 0 }
        return Self.normalized(buffer)
    }

    /// Strips a CR left by CRLF input; nil for a line with nothing in it.
    private static func normalized(_ line: Data) -> Data? {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return nil }
        return line.last == 0x0D ? line.dropLast() : line
    }
}

/// What the stdio bridge needs to know about a JSON-RPC line without understanding it.
///
/// The happy path never parses: the server already answers `204` to a notification and a full
/// response to a request, so the bridge just relays. Parsing is for the failure path, where a
/// request that could not be delivered still has to be answered under its own id.
public enum MCPLine {

    public struct Envelope: Equatable {
        /// The request id as a JSON token, ready to splice into a reply: `7`, or `"abc"`
        /// with its quotes and escapes. Nil for a notification, or when no id is recoverable.
        public let id: String?
        public let method: String?
    }

    public static func envelope(of line: Data) -> Envelope {
        guard let parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            // Not an object: a truncated or mangled line. The id is often still readable.
            return Envelope(id: scrapeID(line), method: nil)
        }
        let method = parsed["method"] as? String
        guard let raw = parsed["id"], !(raw is NSNull) else { return Envelope(id: nil, method: method) }
        return Envelope(id: idToken(raw), method: method)
    }

    /// A JSON-RPC error reply addressed to `id` (a token from `Envelope.id`).
    public static func errorLine(id: String, code: Int, message: String) -> Data {
        Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":\#(jsonString(message))}}"#.utf8)
    }

    /// Whether the line could be a `tools/call`. Deliberately a substring test, not a parse:
    /// it runs on every line from the reader thread, and a wrong "yes" only means a cheap
    /// request waits its turn behind the in-flight cap. A wrong "no" needs an exotic escape
    /// (`tools\/call`) and merely skips the cap for that one request.
    public static func mayBeToolCall(_ line: Data) -> Bool {
        line.range(of: toolCallNeedle) != nil
    }

    /// The reply with any raw CR/LF replaced by spaces. Compact JSON has none, and JSON forbids
    /// raw newlines inside strings, so only whitespace between tokens can be touched; one stray
    /// newline would otherwise split a response into two lines and desynchronise the client.
    public static func singleLine(_ body: Data) -> Data {
        let needsFix = body.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return memchr(base, 0x0A, raw.count) != nil || memchr(base, 0x0D, raw.count) != nil
        }
        guard needsFix else { return body }
        return Data(body.map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
    }

    private static let toolCallNeedle = Data("tools/call".utf8)

    private static func idToken(_ raw: Any) -> String? {
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard raw is NSNumber || raw is String else { return nil }
        return serialize(raw)
    }

    private static func jsonString(_ text: String) -> String {
        serialize(text) ?? "\"\""
    }

    private static func serialize(_ fragment: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: fragment, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Same pattern the bash bridge used. Only the head of the line is searched: a truncated
    /// line that still carries its id carries it early, and a megabyte of garbage is not worth
    /// a regular expression.
    private static let idPattern = try! NSRegularExpression(
        pattern: #""id"\s*:\s*("(?:\\.|[^"\\])*"|-?[0-9]+)"#)

    private static func scrapeID(_ line: Data) -> String? {
        let head = String(decoding: line.prefix(4096), as: UTF8.self)
        let range = NSRange(head.startIndex..., in: head)
        guard let match = idPattern.firstMatch(in: head, range: range),
              let token = Range(match.range(at: 1), in: head) else { return nil }
        return String(head[token])
    }
}
