import XCTest
@testable import MCPServer
@testable import MCPTools

/// Tests for the shared `SelectorSchema` JSON-Schema fragments. Pure data, no desktop.
final class SelectorSchemaTests: XCTestCase {

    func testPropertiesIsNonEmpty() {
        XCTAssertFalse(SelectorSchema.properties.isEmpty)
    }

    func testPropertiesIncludesCoreSelectors() {
        let props = SelectorSchema.properties
        XCTAssertNotNil(props["role"])
        XCTAssertNotNil(props["title"])
        XCTAssertNotNil(props["labelContains"])
        XCTAssertNotNil(props["index"])
        // Also advertise the full matcher vocabulary.
        XCTAssertNotNil(props["titleContains"])
        XCTAssertNotNil(props["identifier"])
        XCTAssertNotNil(props["value"])
        XCTAssertNotNil(props["description"])
        XCTAssertNotNil(props["descriptionContains"])
    }

    func testEachPropertyIsATypedObject() {
        // Every advertised property must be a JSON-Schema object carrying a "type".
        for (key, schema) in SelectorSchema.properties {
            XCTAssertNotNil(schema.objectValue, "\(key) schema should be a JSON object")
            XCTAssertNotNil(schema["type"]?.stringValue, "\(key) schema should declare a type")
        }
    }

    func testMergedPreservesBaseKeys() {
        let base: [String: JSONValue] = [
            "customField": .object(["type": .string("string")]),
            "another": .object(["type": .string("integer")]),
        ]
        let merged = SelectorSchema.merged(into: base)

        // Base keys survive unchanged.
        XCTAssertNotNil(merged["customField"])
        XCTAssertNotNil(merged["another"])
        XCTAssertEqual(merged["customField"]?["type"]?.stringValue, "string")

        // Selector keys are added.
        XCTAssertNotNil(merged["role"])
        XCTAssertNotNil(merged["labelContains"])
        XCTAssertNotNil(merged["index"])

        // Count is base + all selector properties (no key collisions in this base).
        XCTAssertEqual(merged.count, base.count + SelectorSchema.properties.count)
    }

    func testMergedIntoEmptyEqualsProperties() {
        let merged = SelectorSchema.merged(into: [:])
        XCTAssertEqual(merged.count, SelectorSchema.properties.count)
        for key in SelectorSchema.properties.keys {
            XCTAssertNotNil(merged[key])
        }
    }

    func testMergedSelectorOverridesCollidingBaseKey() {
        // If the base reuses a selector key, the selector definition wins (selector spread last).
        let base: [String: JSONValue] = ["role": .string("placeholder")]
        let merged = SelectorSchema.merged(into: base)
        XCTAssertEqual(merged["role"], SelectorSchema.properties["role"])
        XCTAssertNotEqual(merged["role"], .string("placeholder"))
    }
}
