import Foundation

/// Turns `key=value` shell words into the JSON a tool expects.
///
/// Types come from the tool's own `inputSchema`, not from guessing at the text. Guessing
/// gets `app=1234` wrong in the one case that matters: every tool declares `app` as a
/// string, a PID typed on the command line looks like a number, and a numeric `app`
/// silently resolves to nothing. Fetching the schema costs one loopback round trip, which
/// is cheaper than the class of bug it removes.
public enum Arguments {

    public enum Failure: Error, CustomStringConvertible {
        case malformed(String)
        case badJSON(key: String)
        case unknownTool(String, suggestions: [String])

        public var description: String {
            switch self {
            case .malformed(let word):
                return "Expected key=value, got '\(word)'. Use key=value for a plain value, or key:=<json> for a literal array/object."
            case .badJSON(let key):
                return "Value for '\(key):=' is not valid JSON."
            case .unknownTool(let name, let suggestions):
                let hint = suggestions.isEmpty ? "" : "\n\nDid you mean: \(suggestions.joined(separator: ", "))"
                return "No tool named '\(name)'. Run `agentcontroller tools` for the full list.\(hint)"
            }
        }
    }

    /// Property name to declared JSON type, flattened out of a tool's input schema.
    public static func declaredTypes(of tool: [String: Any]) -> [String: String] {
        guard let schema = tool["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return [:] }
        return properties.compactMapValues { ($0 as? [String: Any])?["type"] as? String }
    }

    public static func parse(_ words: [String], types: [String: String]) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for word in words {
            // `key:=value` forces the value to be read as literal JSON, which is how you
            // pass an array or an object without fighting the schema.
            if let range = word.range(of: ":=") {
                let key = String(word[word.startIndex..<range.lowerBound])
                let raw = String(word[range.upperBound...])
                guard let parsed = try? JSONSerialization.jsonObject(
                    with: Data(raw.utf8), options: [.fragmentsAllowed]
                ) else { throw Failure.badJSON(key: key) }
                out[key] = parsed
                continue
            }
            guard let range = word.range(of: "=") else { throw Failure.malformed(word) }
            let key = String(word[word.startIndex..<range.lowerBound])
            let raw = String(word[range.upperBound...])
            guard !key.isEmpty else { throw Failure.malformed(word) }
            out[key] = coerce(raw, to: types[key])
        }
        return out
    }

    /// A value declared `string` stays a string however numeric it looks. Anything the
    /// schema does not describe falls back to inference, which is the right default for a
    /// key the CLI has never heard of.
    public static func coerce(_ raw: String, to declared: String?) -> Any {
        switch declared {
        case "string":
            return raw
        case "boolean":
            return raw == "true" || raw == "1" || raw == "yes"
        case "integer":
            return Int(raw) ?? raw
        case "number":
            return Double(raw) ?? raw
        case "array", "object":
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? raw
        default:
            return infer(raw)
        }
    }

    public static func infer(_ raw: String) -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if let int = Int(raw) { return int }
        if let double = Double(raw) { return double }
        if raw.hasPrefix("[") || raw.hasPrefix("{") {
            if let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) { return parsed }
        }
        return raw
    }

    /// Tool names within one edit of `name`, so a typo gets a pointer instead of a list of
    /// forty-nine. Cheap Levenshtein-ish: prefix, substring, then equal length with one
    /// differing character.
    public static func suggestions(for name: String, among names: [String]) -> [String] {
        let lowered = name.lowercased()
        return names.filter { candidate in
            if candidate.hasPrefix(lowered) || candidate.contains(lowered) || lowered.contains(candidate) {
                return true
            }
            guard candidate.count == lowered.count else { return false }
            return zip(candidate, lowered).filter(!=).count <= 1
        }.prefix(5).map { $0 }
    }
}
