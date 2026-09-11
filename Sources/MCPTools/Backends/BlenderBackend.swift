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
        let slice = data.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: true).first.map(Data.init) ?? data
        return try JSONDecoder().decode(JSONValue.self, from: slice)
    }

    static let pingCode = "result={'agentcontroller': True, 'objects': len(__import__('bpy').data.objects)}"

    static func isLabSuccess(_ value: JSONValue) -> Bool {
        let status = value["status"]?.stringValue?.lowercased()
        return status == "ok" || status == "success" || value["result"] != nil
    }
}

actor BlenderBackend {
    static let shared = BlenderBackend()

    struct Endpoint: Sendable, Equatable {
        var host: String
        var port: UInt16
        var kind: CapabilityRecord.Backend
        var pid: Int?
        var detail: String
    }

    private var communityWS: URLSessionWebSocketTask?

    func handshake(ports: ClosedRange<UInt16> = BlenderProtocol.defaultPorts) async -> [Endpoint] {
        await withTaskGroup(of: Endpoint?.self) { group in
            for port in ports {
                group.addTask {
                    await self.probe(port: port)
                }
            }
            var found: [Endpoint] = []
            for await item in group {
                if let item { found.append(item) }
            }
            return found.sorted { $0.port < $1.port }
        }
    }

    func execute(endpoint: Endpoint, code: String) async throws -> JSONValue {
        switch endpoint.kind {
        case .blenderLab:
            let payload = try BlenderProtocol.encodeLab(code: code)
            let data = try SocketProbe.roundTrip(
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

    func sceneSnapshot(endpoint: Endpoint) async throws -> [RoutedRef] {
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
            return RoutedRef.blender(name: name, kind: kind)
        }
    }

    private func probe(port: UInt16) async -> Endpoint? {
        // Lab first: a tiny execute. Community sockets will fail to parse this.
        if let endpoint = probeLab(port: port) { return endpoint }
        if let endpoint = await probeCommunity(port: port) { return endpoint }
        return nil
    }

    private func probeLab(port: UInt16) -> Endpoint? {
        guard let payload = try? BlenderProtocol.encodeLab(code: BlenderProtocol.pingCode) else { return nil }
        guard let data = try? SocketProbe.roundTrip(
            host: "127.0.0.1",
            port: port,
            payload: payload,
            timeoutMs: 250,
            readUntilNull: true
        ), !data.isEmpty else { return nil }
        guard let decoded = try? BlenderProtocol.decodeLab(data), BlenderProtocol.isLabSuccess(decoded) else {
            return nil
        }
        return Endpoint(host: "127.0.0.1", port: port, kind: .blenderLab, pid: nil, detail: "Blender Lab MCP (null-terminated JSON)")
    }

    private func probeCommunity(port: UInt16) async -> Endpoint? {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return nil }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        let ping = "{\"type\":\"get_scene_info\"}"
        do {
            try await task.send(.string(ping))
            let message = try await withTimeout(ms: 250) {
                try await task.receive()
            }
            task.cancel(with: .goingAway, reason: nil)
            switch message {
            case .string(let text):
                if text.contains("error") && text.lowercased().contains("unknown") { return nil }
                return Endpoint(host: "127.0.0.1", port: port, kind: .blenderWS, pid: nil, detail: "Blender community WebSocket")
            case .data(let data):
                if let text = String(data: data, encoding: .utf8), text.contains("{") {
                    return Endpoint(host: "127.0.0.1", port: port, kind: .blenderWS, pid: nil, detail: "Blender community WebSocket")
                }
            @unknown default:
                return nil
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            return nil
        }
        return nil
    }

    private func communityExecute(endpoint: Endpoint, code: String) async throws -> JSONValue {
        guard let url = URL(string: "ws://\(endpoint.host):\(endpoint.port)") else {
            throw ToolError.actionFailed("Invalid Blender WebSocket URL")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let body = JSONValue.object([
            "type": .string("execute_code"),
            "params": .object(["code": .string(code)]),
        ])
        let data = try JSONEncoder().encode(body)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.actionFailed("Failed to encode Blender payload")
        }
        try await task.send(.string(text))
        let message = try await withTimeout(ms: 8_000) { try await task.receive() }
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

func withTimeout<T: Sendable>(ms: Int, body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            throw ToolError.timedOut("backend handshake")
        }
        guard let result = try await group.next() else {
            throw ToolError.timedOut("backend handshake")
        }
        group.cancelAll()
        return result
    }
}
