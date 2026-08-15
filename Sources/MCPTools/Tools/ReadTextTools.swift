import Foundation
import MCPServer
import AccessibilityEngine

/// Cheap text extraction for content verification — no screenshot, no OCR. `read_text`
/// pulls one element's text; `read_all_text` pulls every matching element's text in tree
/// order. Both let an agent assert "the screen says X" for a fraction of a screenshot's
/// token cost.
struct ReadTextTools {
    static func register(in registry: ToolRegistry) {
        registerReadText(in: registry)
        registerReadAllText(in: registry)
    }

    // MARK: - read_text

    private static func registerReadText(in registry: ToolRegistry) {
        registry.register(.init(
            name: "read_text",
            description: "Read the text of a single element matched by selector — returns its value/title/label as {text:...}. Errors if no element matches. Use to grab a label, field contents, or status line without a screenshot. Searches the whole app by default; pass scope:'window' for just the focused window.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "scope": SelectorSchema.scopeProperty(default: "app"),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let text: String? = await AXExecutor.app(pid).run {
                    let root = SearchScope.root(pid: pid, args: args, defaultScope: "app")
                    guard let r = AXElementSearch.find(root: root, criteria: criteria).first else { return nil }
                    let el = r.element
                    return el.stringValue ?? el.title ?? el.label ?? ""
                }

                guard let text else {
                    return ToolResult.error("read_text: no element matched \(AssertTools.selectorDescription(args))")
                }
                return ToolResult.json(.object(["text": .string(text)]))
            }
        ))
    }

    // MARK: - read_all_text

    private static func registerReadAllText(in registry: ToolRegistry) {
        registry.register(.init(
            name: "read_all_text",
            description: "Read all visible text strings from elements of a given role (default AXStaticText), in tree order, dropping empties. Returns {count, texts:[...]}. Use to verify on-screen content cheaply (e.g. confirm a paragraph or list rendered) instead of a screenshot. Searches the whole app by default; pass scope:'window' for just the focused window.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role to collect (default 'AXStaticText')")]),
                    "maxResults": .object(["type": .string("integer"), "description": .string("Max strings to return (default 200)")]),
                    "scope": SelectorSchema.scopeProperty(default: "app"),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let role = args?["role"]?.stringValue ?? "AXStaticText"
                let maxResults = args?["maxResults"]?.intValue ?? 200
                let criteria = AXElementSearchCriteria(role: role, maxResults: maxResults)

                let texts: [String] = await AXExecutor.app(pid).run {
                    let root = SearchScope.root(pid: pid, args: args, defaultScope: "app")
                    let results = AXElementSearch.find(root: root, criteria: criteria)
                    return results.compactMap { r -> String? in
                        let el = r.element
                        let t = el.stringValue ?? el.title ?? el.label
                        guard let t, !t.isEmpty else { return nil }
                        return t
                    }
                }

                return ToolResult.json(.object([
                    "count": .int(texts.count),
                    "texts": .array(texts.map { .string($0) }),
                ]))
            }
        ))
    }
}
