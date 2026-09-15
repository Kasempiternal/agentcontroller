import XCTest
@testable import CLICore

/// `key=value` on a command line is untyped text, and the tools are not. These pin the
/// schema-driven coercion that keeps a shell word arriving as the type the tool declared.
final class CLIArgumentTests: XCTestCase {

    /// The case the whole design exists for. Every tool declares `app` as a string, a PID
    /// typed at a shell looks exactly like a number, and a numeric `app` resolves to
    /// nothing at all — a silent miss rather than an error.
    func testPIDStaysAStringWhenTheSchemaSaysString() throws {
        let parsed = try Arguments.parse(["app=1234"], types: ["app": "string"])
        XCTAssertEqual(parsed["app"] as? String, "1234")
        XCTAssertNil(parsed["app"] as? Int)
    }

    func testDeclaredTypesDriveEachConversion() throws {
        let types = ["app": "string", "windowIndex": "integer", "quality": "number", "foreground": "boolean"]
        let parsed = try Arguments.parse(
            ["app=com.apple.TextEdit", "windowIndex=2", "quality=0.7", "foreground=true"], types: types)
        XCTAssertEqual(parsed["app"] as? String, "com.apple.TextEdit")
        XCTAssertEqual(parsed["windowIndex"] as? Int, 2)
        XCTAssertEqual(parsed["quality"] as? Double, 0.7)
        XCTAssertEqual(parsed["foreground"] as? Bool, true)
    }

    /// A key the CLI has never seen still has to do something sensible, because the
    /// schema is whatever the running server says it is.
    func testUndeclaredKeysFallBackToInference() throws {
        let parsed = try Arguments.parse(["count=3", "flag=false", "name=hello"], types: [:])
        XCTAssertEqual(parsed["count"] as? Int, 3)
        XCTAssertEqual(parsed["flag"] as? Bool, false)
        XCTAssertEqual(parsed["name"] as? String, "hello")
    }

    func testColonEqualsTakesLiteralJSON() throws {
        let parsed = try Arguments.parse([#"menuPath:=["File","Open…"]"#], types: [:])
        XCTAssertEqual(parsed["menuPath"] as? [String], ["File", "Open…"])
    }

    /// `:=` overrides the schema, which is the point: it is the escape hatch for a value
    /// the declared type would mangle.
    func testColonEqualsOverridesTheDeclaredType() throws {
        let parsed = try Arguments.parse(["app:=1234"], types: ["app": "string"])
        XCTAssertEqual(parsed["app"] as? Int, 1234)
    }

    func testMalformedWordIsRejected() {
        XCTAssertThrowsError(try Arguments.parse(["nonsense"], types: [:]))
        XCTAssertThrowsError(try Arguments.parse(["=novalue"], types: [:]))
    }

    func testInvalidJSONAfterColonEqualsIsRejected() {
        XCTAssertThrowsError(try Arguments.parse(["menuPath:=[File"], types: [:]))
    }

    /// A value containing `=` must survive: selectors legitimately carry them.
    func testOnlyTheFirstEqualsSplits() throws {
        let parsed = try Arguments.parse(["labelContains=a=b=c"], types: ["labelContains": "string"])
        XCTAssertEqual(parsed["labelContains"] as? String, "a=b=c")
    }

    func testDeclaredTypesAreReadOutOfTheToolSchema() {
        let tool: [String: Any] = [
            "name": "click",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "…"],
                    "x": ["type": "number"],
                ],
            ],
        ]
        let types = Arguments.declaredTypes(of: tool)
        XCTAssertEqual(types["app"], "string")
        XCTAssertEqual(types["x"], "number")
    }

    // MARK: - Typo recovery

    func testNearMissNameIsSuggested() {
        let names = ["list_windows", "list_apps", "list_flows", "click", "type_text"]
        XCTAssertTrue(Arguments.suggestions(for: "list_window", among: names).contains("list_windows"))
        XCTAssertTrue(Arguments.suggestions(for: "clock", among: names).contains("click"))
    }

    func testUnrelatedNameSuggestsNothing() {
        XCTAssertTrue(Arguments.suggestions(for: "zzzzzzzz", among: ["click", "type_text"]).isEmpty)
    }
}
