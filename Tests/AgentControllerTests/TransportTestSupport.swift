import Foundation
import XCTest
@testable import MCPServer

/// Polls `condition` until it holds or `timeout` passes. Transport tests wait on real threads
/// and sockets, so a fixed sleep is either flaky or slow; this is neither.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// A tool provider whose behaviour the tests script, recording what happened to each call by
/// the `tag` argument it was given.
///   - `slow`  parks until cancelled (30s ceiling), recording the cancellation
///   - `echo`  returns its arguments
///   - `nan`   returns a result containing non-finite doubles
final class FakeProvider: MCPToolProvider, @unchecked Sendable {
    private let lock = NSLock()
    fileprivate var _started: [String] = []
    fileprivate var _cancelled: [String] = []
    fileprivate var _finished: [String] = []

    var started: [String] { lock.lock(); defer { lock.unlock() }; return _started }
    var cancelled: [String] { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var finished: [String] { lock.lock(); defer { lock.unlock() }; return _finished }

    private func record(_ list: ReferenceWritableKeyPath<FakeProvider, [String]>, _ tag: String) {
        lock.lock(); defer { lock.unlock() }
        self[keyPath: list].append(tag)
    }

    func listTools() -> [JSONValue] { [] }

    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        let tag = arguments?["tag"]?.stringValue ?? "?"
        record(\._started, tag)
        switch name {
        case "slow":
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                record(\._cancelled, tag)
                throw error
            }
            record(\._finished, tag)
            return .object(["content": .array([.object(["type": .string("text"), "text": .string("slow done")])])])
        case "nan":
            return .object([
                "ratio": .double(.nan),
                "limit": .double(.infinity),
                "floor": .double(-.infinity),
                "ok": .int(1),
            ])
        default:
            record(\._finished, tag)
            return arguments ?? .null
        }
    }
}

/// JSON-RPC lines as the bridge would send them.
enum Wire {
    static func call(_ id: Int, _ tool: String, tag: String = "t") -> Data {
        encode(.object([
            "jsonrpc": .string("2.0"), "id": .int(id), "method": .string("tools/call"),
            "params": .object(["name": .string(tool), "arguments": .object(["tag": .string(tag)])]),
        ]))
    }

    static func request(_ id: Int, _ method: String) -> Data {
        encode(.object(["jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method)]))
    }

    static func cancel(_ requestId: Int) -> Data {
        encode(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .int(requestId), "reason": .string("test")]),
        ]))
    }

    static func encode(_ value: JSONValue) -> Data {
        try! JSONEncoder().encode(value)
    }

    static func decode(_ data: Data) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// A bare BSD socket speaking raw HTTP to the server under test. URLSession and curl each
/// behave "correctly"; the transport bugs live in exactly the behaviours they smooth over
/// (half-sent requests, abrupt closes, an interim 100).
final class RawSocket {
    let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            Darwin.close(fd)
            throw NSError(domain: "RawSocket", code: Int(errno))
        }
    }

    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// Bytes available within `timeout`: nil when nothing arrives, empty Data on EOF.
    func receive(timeout: TimeInterval) -> Data? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buffer, buffer.count, 0)
        if n < 0 { return Data() }
        return Data(buffer[0..<n])
    }

    /// Reads until `marker` has appeared in the accumulated text or `timeout` passes.
    func receive(until marker: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        while Date() < deadline, !text.contains(marker) {
            guard let chunk = receive(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { continue }
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        return text
    }

    func close() { Darwin.close(fd) }
}
