import XCTest
@testable import MCPServer

/// Hermetic codec + accessor tests for `JSONValue`. No desktop, no permissions.
final class JSONValueTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Encode a value, decode it back, and assert equality (JSONValue is Hashable/Equatable).
    private func roundTrip(_ value: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(value, decoded, file: file, line: line)
    }

    // MARK: - Round-trips for every case

    func testRoundTripNull() throws { try roundTrip(.null) }
    func testRoundTripBool() throws {
        try roundTrip(.bool(true))
        try roundTrip(.bool(false))
    }
    func testRoundTripInt() throws {
        try roundTrip(.int(0))
        try roundTrip(.int(42))
        try roundTrip(.int(-17))
    }
    func testRoundTripDouble() throws {
        // Use a value with a fractional part so the decoder cannot coerce it to .int.
        try roundTrip(.double(3.5))
        try roundTrip(.double(-0.25))
    }
    func testRoundTripString() throws {
        try roundTrip(.string(""))
        try roundTrip(.string("hello world"))
        try roundTrip(.string("unicode: café 🚀 \" \\"))
    }
    func testRoundTripArray() throws {
        try roundTrip(.array([]))
        try roundTrip(.array([.int(1), .string("two"), .bool(false), .null]))
    }
    func testRoundTripObject() throws {
        try roundTrip(.object([:]))
        try roundTrip(.object(["a": .int(1), "b": .string("x"), "c": .null]))
    }

    func testRoundTripNested() throws {
        let nested: JSONValue = .object([
            "name": .string("root"),
            "count": .int(3),
            "ratio": .double(1.5),
            "enabled": .bool(true),
            "tags": .array([.string("x"), .string("y")]),
            "meta": .object([
                "nested": .array([
                    .object(["k": .null]),
                    .int(7),
                ]),
            ]),
            "empty": .null,
        ])
        try roundTrip(nested)
    }

    // MARK: - Decoding from raw JSON

    func testDecodeFromRawJSON() throws {
        let json = #"{"s":"str","i":5,"d":2.5,"b":true,"n":null,"arr":[1,2,3]}"#
        let value = try decoder.decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["s"]?.stringValue, "str")
        XCTAssertEqual(value["i"]?.intValue, 5)
        XCTAssertEqual(value["d"]?.doubleValue, 2.5)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertEqual(value["n"]?.isNull, true)
        XCTAssertEqual(value["arr"]?.arrayValue?.count, 3)
    }

    /// Decoding a payload that is none of the supported scalar/collection shapes should throw.
    /// A bare numeric type the singleValueContainer cannot map (NaN via allowed strategy) is
    /// hard to force, so we exercise the explicit failure on a top-level that is valid JSON
    /// but already covered — instead assert that truly malformed input throws.
    func testDecodeMalformedThrows() {
        let malformed = Data("not json at all".utf8)
        XCTAssertThrowsError(try decoder.decode(JSONValue.self, from: malformed))
    }

    // MARK: - Accessors

    func testSubscriptOnlyWorksOnObject() {
        let obj: JSONValue = .object(["k": .int(1)])
        XCTAssertEqual(obj["k"]?.intValue, 1)
        XCTAssertNil(obj["missing"])
        // Non-object returns nil for any key.
        XCTAssertNil(JSONValue.array([.int(1)])["0"])
        XCTAssertNil(JSONValue.int(1)["k"])
    }

    func testStringValue() {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertNil(JSONValue.int(1).stringValue)
        XCTAssertNil(JSONValue.null.stringValue)
    }

    func testIntValue() {
        XCTAssertEqual(JSONValue.int(7).intValue, 7)
        // double is coerced to Int (truncating).
        XCTAssertEqual(JSONValue.double(7.9).intValue, 7)
        XCTAssertNil(JSONValue.string("7").intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
    }

    func testDoubleValue() {
        XCTAssertEqual(JSONValue.double(2.5).doubleValue, 2.5)
        // int is promoted to Double.
        XCTAssertEqual(JSONValue.int(4).doubleValue, 4.0)
        XCTAssertNil(JSONValue.string("2.5").doubleValue)
    }

    func testBoolValue() {
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertEqual(JSONValue.bool(false).boolValue, false)
        XCTAssertNil(JSONValue.int(1).boolValue)
    }

    func testArrayValue() {
        XCTAssertEqual(JSONValue.array([.int(1)]).arrayValue?.count, 1)
        XCTAssertNil(JSONValue.object([:]).arrayValue)
    }

    func testObjectValue() {
        XCTAssertEqual(JSONValue.object(["a": .int(1)]).objectValue?.count, 1)
        XCTAssertNil(JSONValue.array([]).objectValue)
    }

    func testIsNull() {
        XCTAssertTrue(JSONValue.null.isNull)
        XCTAssertFalse(JSONValue.int(0).isNull)
        XCTAssertFalse(JSONValue.bool(false).isNull)
        XCTAssertFalse(JSONValue.string("").isNull)
    }
}
