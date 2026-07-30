import XCTest
@testable import MCPTools
import MCPServer

/// The annotation maps live apart from the tool definitions, so nothing but a
/// test stops a rename from silently orphaning a classification — and a wrong
/// readOnlyHint invites a client to auto-approve a mutating tool.
final class AnnotationTests: XCTestCase {
    private func registeredNames() -> Set<String> {
        Set(ToolRegistry().listTools().compactMap { $0["name"]?.stringValue })
    }

    func testAnnotationSetsReferenceOnlyRealTools() {
        let names = registeredNames()
        for tool in ToolRegistry.readOnlyTools {
            XCTAssertTrue(names.contains(tool), "readOnlyTools names unknown tool '\(tool)'")
        }
        for tool in ToolRegistry.destructiveTools {
            XCTAssertTrue(names.contains(tool), "destructiveTools names unknown tool '\(tool)'")
        }
    }

    func testReadOnlyAndDestructiveAreDisjoint() {
        XCTAssertTrue(ToolRegistry.readOnlyTools.isDisjoint(with: ToolRegistry.destructiveTools))
    }

    func testEveryToolCarriesAnnotations() {
        for tool in ToolRegistry().listTools() {
            let name = tool["name"]?.stringValue ?? "?"
            let annotations = tool["annotations"]
            XCTAssertNotNil(annotations, "'\(name)' has no annotations object")
            XCTAssertEqual(annotations?["openWorldHint"]?.boolValue, false, name)
            XCTAssertNotNil(annotations?["destructiveHint"]?.boolValue, name)
            if ToolRegistry.readOnlyTools.contains(name) {
                XCTAssertEqual(annotations?["readOnlyHint"]?.boolValue, true, name)
                XCTAssertEqual(annotations?["destructiveHint"]?.boolValue, false,
                               "'\(name)' cannot be read-only AND destructive")
            }
        }
    }

    /// Guard the token-lean contract: tool JSON payloads must be compact —
    /// pretty-printing is a recurring whitespace tax on every agent call.
    func testToolResultJSONIsCompact() {
        let payload: JSONValue = .object([
            "a": .array([.int(1), .int(2)]),
            "nested": .object(["k": .string("v")]),
        ])
        let text = ToolResult.json(payload)["content"]?.arrayValue?
            .first?["text"]?.stringValue ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("\n"), "tool JSON must not be pretty-printed")
        XCTAssertFalse(text.contains("  "), "tool JSON must not contain indentation")
    }
}
