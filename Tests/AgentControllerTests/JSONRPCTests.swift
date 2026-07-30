import XCTest
@testable import MCPServer

/// Hermetic Codable tests for the JSON-RPC envelope types.
final class JSONRPCTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Encode any Encodable and return the top-level JSON object as a dictionary.
    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            XCTFail("Expected top-level JSON object")
            return [:]
        }
        return dict
    }

    // MARK: - Request

    func testRequestEncodeDecodeRoundTrip() throws {
        let req = JSONRPCRequest(
            method: "tools/call",
            params: .object(["name": .string("click"), "n": .int(2)]),
            id: .int(99)
        )
        let dict = try encodeToObject(req)
        XCTAssertEqual(dict["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(dict["method"] as? String, "tools/call")

        // Decode back and compare salient fields.
        let data = try encoder.encode(req)
        let decoded = try decoder.decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.method, "tools/call")
        XCTAssertEqual(decoded.id, .int(99))
        XCTAssertEqual(decoded.params?["name"]?.stringValue, "click")
        XCTAssertEqual(decoded.params?["n"]?.intValue, 2)
    }

    func testRequestNotification() throws {
        // No id => a notification. Method-only request still encodes jsonrpc 2.0.
        let req = JSONRPCRequest(method: "notifications/initialized")
        let data = try encoder.encode(req)
        let decoded = try decoder.decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(decoded.method, "notifications/initialized")
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.params)
    }

    // MARK: - Response success/failure invariant

    /// A success response must encode `result` and OMIT the `error` key entirely.
    func testSuccessResponseOmitsError() throws {
        let resp = JSONRPCResponse.success(.object(["ok": .bool(true)]), id: .int(1))
        let dict = try encodeToObject(resp)
        XCTAssertEqual(dict["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(dict["result"], "success must carry a result")
        XCTAssertNil(dict["error"], "success must NOT carry an error key (no double result+error)")
        XCTAssertEqual(dict["id"] as? Int, 1)
    }

    /// A failure response must encode `error` and OMIT the `result` key entirely.
    func testFailureResponseOmitsResult() throws {
        let resp = JSONRPCResponse.failure(.methodNotFound, id: .string("abc"))
        let dict = try encodeToObject(resp)
        XCTAssertEqual(dict["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(dict["error"], "failure must carry an error")
        XCTAssertNil(dict["result"], "failure must NOT carry a result key (no double result+error)")
        XCTAssertEqual(dict["id"] as? String, "abc")

        let errorDict = dict["error"] as? [String: Any]
        XCTAssertEqual(errorDict?["code"] as? Int, -32601)
        XCTAssertEqual(errorDict?["message"] as? String, "Method not found")
    }

    func testResponseDecodeRoundTrip() throws {
        let resp = JSONRPCResponse.success(.string("done"), id: .int(7))
        let data = try encoder.encode(resp)
        let decoded = try decoder.decode(JSONRPCResponse.self, from: data)
        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.result?.stringValue, "done")
        XCTAssertNil(decoded.error)
        XCTAssertEqual(decoded.id, .int(7))
    }

    func testResponseNullId() throws {
        // Parse errors carry a null id; ensure it round-trips as nil (key may be present-null or absent).
        let resp = JSONRPCResponse.failure(.parseError, id: nil)
        let data = try encoder.encode(resp)
        let decoded = try decoder.decode(JSONRPCResponse.self, from: data)
        XCTAssertNil(decoded.id)
        XCTAssertEqual(decoded.error?.code, -32700)
    }

    // MARK: - JSONRPCId string vs int

    func testIdStringVsInt() throws {
        let intId = JSONRPCId.int(123)
        let strId = JSONRPCId.string("uuid-1")

        let intData = try encoder.encode(intId)
        XCTAssertEqual(String(data: intData, encoding: .utf8), "123")
        XCTAssertEqual(try decoder.decode(JSONRPCId.self, from: intData), .int(123))

        let strData = try encoder.encode(strId)
        XCTAssertEqual(String(data: strData, encoding: .utf8), "\"uuid-1\"")
        XCTAssertEqual(try decoder.decode(JSONRPCId.self, from: strData), .string("uuid-1"))
    }

    func testIdDecodeFromRaw() throws {
        XCTAssertEqual(try decoder.decode(JSONRPCId.self, from: Data("5".utf8)), .int(5))
        XCTAssertEqual(try decoder.decode(JSONRPCId.self, from: Data("\"x\"".utf8)), .string("x"))
        // A bool is neither string nor int → must throw.
        XCTAssertThrowsError(try decoder.decode(JSONRPCId.self, from: Data("true".utf8)))
    }

    // MARK: - Standard error constants

    func testStandardErrorCodes() {
        XCTAssertEqual(JSONRPCError.parseError.code, -32700)
        XCTAssertEqual(JSONRPCError.invalidRequest.code, -32600)
        XCTAssertEqual(JSONRPCError.methodNotFound.code, -32601)
        XCTAssertEqual(JSONRPCError.invalidParams.code, -32602)
        XCTAssertEqual(JSONRPCError.internalError.code, -32603)

        XCTAssertEqual(JSONRPCError.parseError.message, "Parse error")
        XCTAssertEqual(JSONRPCError.invalidRequest.message, "Invalid Request")
        XCTAssertEqual(JSONRPCError.methodNotFound.message, "Method not found")
        XCTAssertEqual(JSONRPCError.invalidParams.message, "Invalid params")
        XCTAssertEqual(JSONRPCError.internalError.message, "Internal error")
    }

    func testErrorWithDataEncodes() throws {
        let err = JSONRPCError(code: -32000, message: "Custom", data: .object(["detail": .string("info")]))
        let dict = try encodeToObject(err)
        XCTAssertEqual(dict["code"] as? Int, -32000)
        XCTAssertEqual(dict["message"] as? String, "Custom")
        XCTAssertNotNil(dict["data"])
    }
}
