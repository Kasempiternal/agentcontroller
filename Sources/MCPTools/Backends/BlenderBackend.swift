import Foundation
import MCPServer

/// Blender Lab (TCP, null-terminated JSON) vs community (WebSocket JSON text).
/// Port open is not enough — both default to :9876.
enum BlenderProtocol {
    static let defaultPorts: ClosedRange<UInt16> = 9876...9896

    static func encodeLab(code: String, strictJSON: Bool = true) throws -> Data {
        let payload = JSONValue.object([
            "type": .string("execute"),
            "code": .string(code),
            "strict_json": .bool(strictJSON),
        ])
        var data = try JSONEncoder().encode(payload)
        data.append(0)
        return data
    }

    static func decodeLab(_ data: Data) throws -> JSONValue {
        let jsonData: Data
        if let null = data.firstIndex(of: 0) {
            jsonData = data[..<null]
        } else {
            jsonData = data
        }
        return try JSONDecoder().decode(JSONValue.self, from: jsonData)
    }

    static let pingCode = "result={'agentcontroller': True, 'objects': len(__import__('bpy').data.objects)}"

    static func isLabSuccess(_ value: JSONValue) -> Bool {
        let status = value["status"]?.stringValue?.lowercased()
        return status == "ok" || status == "success" || value["result"] != nil
    }
}

/// A Blender socket that answered the handshake. Public because `RoutedRef.blender`
/// carries it: an elementId must act on the instance its snapshot came from.
public struct BlenderEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var kind: CapabilityRecord.Backend
    public var pid: Int?
    public var detail: String

    public init(host: String, port: UInt16, kind: CapabilityRecord.Backend, pid: Int? = nil, detail: String) {
        self.host = host
        self.port = port
        self.kind = kind
        self.pid = pid
        self.detail = detail
    }

    public var address: String { "\(host):\(port)" }

    /// The endpoint a probe already found, rebuilt from its record — so a call after the
    /// probe does not handshake 21 ports again just to rediscover it.
    public init?(record: CapabilityRecord) {
        guard record.backend == .blenderLab || record.backend == .blenderWS,
              let address = record.endpoint,
              let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]) else { return nil }
        self.init(host: String(address[..<colon]), port: port, kind: record.backend, pid: record.pid, detail: record.reason)
    }
}

/// Stateless: every call is a socket exchange, and the blocking ones run on GCD threads.
/// This used to be an actor, which serialised the whole handshake — a Blender that
/// accepted and then hung held the actor for its full timeout while the other ports
/// queued behind it.
enum BlenderBackend {
    static func handshake(ports: [UInt16] = Array(BlenderProtocol.defaultPorts)) async -> [BlenderEndpoint] {
        await withTaskGroup(of: BlenderEndpoint?.self) { group in
            for port in ports {
                group.addTask { await probe(port: port) }
            }
            var found: [BlenderEndpoint] = []
            for await item in group {
                if let item { found.append(item) }
            }
            return found.sorted { $0.port < $1.port }
        }
    }

    static func execute(endpoint: BlenderEndpoint, code: String) async throws -> JSONValue {
        switch endpoint.kind {
        case .blenderLab:
            let payload = try BlenderProtocol.encodeLab(code: code)
            let data = try await SocketProbe.roundTripAsync(
                host: endpoint.host,
                port: endpoint.port,
                payload: payload,
                timeoutMs: 8_000,
                readUntilNull: true
            )
            return try BlenderProtocol.decodeLab(data)
        case .blenderWS:
            return try await communityExecute(endpoint: endpoint, code: code)
        default:
            throw ToolError.actionFailed("Not a Blender endpoint")
        }
    }

    static func sceneSnapshot(endpoint: BlenderEndpoint) async throws -> [RoutedRef] {
        let code = """
        import bpy
        result = [{'name': o.name, 'type': o.type, 'location': list(o.location)} for o in bpy.data.objects]
        """
        let raw = try await execute(endpoint: endpoint, code: code)
        let list = raw["result"] ?? raw
        let items: [JSONValue]
        if let array = list.arrayValue {
            items = array
        } else if let array = list["result"]?.arrayValue {
            items = array
        } else {
            items = []
        }
        return items.compactMap { item in
            let name = item["name"]?.stringValue ?? item.stringValue
            guard let name, !name.isEmpty else { return nil }
            let kind = item["type"]?.stringValue ?? "OBJECT"
            return RoutedRef.blender(name: name, kind: kind, endpoint: endpoint)
        }
    }

    private static func probe(port: UInt16) async -> BlenderEndpoint? {
        // Most of the 21 ports have nothing behind them; one cheap connect rules those
        // out before either protocol is attempted.
        guard await SocketProbe.connectAsync(port: port, timeoutMs: 120) else { return nil }
        // Lab first: a tiny execute. Community sockets will fail to parse this.
        if let endpoint = await probeLab(port: port) { return endpoint }
        return await probeCommunity(port: port)
    }

    private static func probeLab(port: UInt16) async -> BlenderEndpoint? {
        guard let payload = try? BlenderProtocol.encodeLab(code: BlenderProtocol.pingCode) else { return nil }
        guard let data = try? await SocketProbe.roundTripAsync(
            host: "127.0.0.1",
            port: port,
            payload: payload,
            timeoutMs: 250,
            readUntilNull: true
        ), !data.isEmpty else { return nil }
        guard let decoded = try? BlenderProtocol.decodeLab(data), BlenderProtocol.isLabSuccess(decoded) else {
            return nil
        }
        return BlenderEndpoint(host: "127.0.0.1", port: port, kind: .blenderLab, detail: "Blender Lab MCP (null-terminated JSON)")
    }

    private static func probeCommunity(port: UInt16) async -> BlenderEndpoint? {
        guard let url = URL(string: "ws://127.0.0.1:\(port)"),
              let message = try? await WebSocketIO.roundTrip(url: url, text: "{\"type\":\"get_scene_info\"}", timeoutMs: 250)
        else { return nil }
        let detail = "Blender community WebSocket"
        switch message {
        case .string(let text):
            if text.contains("error") && text.lowercased().contains("unknown") { return nil }
            return BlenderEndpoint(host: "127.0.0.1", port: port, kind: .blenderWS, detail: detail)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8), text.contains("{") {
                return BlenderEndpoint(host: "127.0.0.1", port: port, kind: .blenderWS, detail: detail)
            }
            return nil
        @unknown default:
            return nil
        }
    }

    private static func communityExecute(endpoint: BlenderEndpoint, code: String) async throws -> JSONValue {
        guard let url = URL(string: "ws://\(endpoint.host):\(endpoint.port)") else {
            throw ToolError.actionFailed("Invalid Blender WebSocket URL")
        }
        let body = JSONValue.object([
            "type": .string("execute_code"),
            "params": .object(["code": .string(code)]),
        ])
        let data = try JSONEncoder().encode(body)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.actionFailed("Failed to encode Blender payload")
        }
        let message = try await WebSocketIO.roundTrip(url: url, text: text, timeoutMs: 8_000)
        switch message {
        case .string(let s):
            return try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
        case .data(let d):
            return try JSONDecoder().decode(JSONValue.self, from: d)
        @unknown default:
            throw ToolError.actionFailed("Unexpected Blender WebSocket frame")
        }
    }
}

/// One WebSocket request/reply with a deadline that actually fires.
///
/// `URLSessionWebSocketTask.receive()` ignores Swift task cancellation, so racing it
/// against a sleep in a task group (the old `withTimeout`) only works once `receive`
/// returns — measured: a 250ms timeout came back after 6.02s. The deadline has to cancel
/// the socket task itself, which is what makes the pending `receive` throw.
enum WebSocketIO {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func roundTrip(
        url: URL,
        text: String,
        timeoutMs: Int,
        maximumMessageSize: Int = 64 << 20
    ) async throws -> URLSessionWebSocketTask.Message {
        let task = ChromeLauncher.loopbackSession.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let expired = Flag()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    try await task.send(.string(text))
                    return try await task.receive()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    expired.set()
                    task.cancel(with: .goingAway, reason: nil)
                    throw ToolError.timedOut("WebSocket reply after \(timeoutMs)ms")
                }
                do {
                    guard let message = try await group.next() else {
                        throw ToolError.timedOut("WebSocket reply after \(timeoutMs)ms")
                    }
                    group.cancelAll()
                    return message
                } catch {
                    group.cancelAll()
                    task.cancel(with: .goingAway, reason: nil)
                    if expired.isSet { throw ToolError.timedOut("WebSocket reply after \(timeoutMs)ms") }
                    throw error
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }
}
