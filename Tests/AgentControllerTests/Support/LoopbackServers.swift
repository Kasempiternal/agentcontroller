import Foundation
import Network

/// A real WebSocket server on a loopback port, so the CDP/Blender transport is exercised
/// against actual frames (fragmentation, sizes, close) rather than a mock of URLSession.
final class LoopbackWebSocketServer: @unchecked Sendable {
    typealias Handler = (_ text: String, _ reply: @escaping (String) -> Void) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-ws-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0
    var handler: Handler = { _, _ in }

    init() throws {
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: params)
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            throw NSError(domain: "LoopbackWebSocketServer", code: 1)
        }
        port = bound
    }

    func stop() {
        listener.cancel()
        closeAll()
    }

    func closeAll() {
        lock.lock()
        let all = connections
        connections.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let data, metadata?.opcode == .text, let text = String(data: data, encoding: .utf8) {
                self.handler(text) { [weak self] reply in self?.send(reply, on: connection) }
            }
            self.receive(on: connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

/// Accepts TCP connections and never says anything: a Blender that is up but hung.
final class SilentTCPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-silent-server")
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.held.append(connection)
            self.lock.unlock()
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            throw NSError(domain: "SilentTCPServer", code: 1)
        }
        port = bound
    }

    func stop() {
        listener.cancel()
        lock.lock()
        held.forEach { $0.cancel() }
        held.removeAll()
        lock.unlock()
    }
}

/// A user's Chrome as far as debug-port discovery can tell: it answers every HTTP request
/// with a browser version document, and counts both the connections it was offered and the
/// requests it was asked.
final class FakeDebugPortServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-debug-port-server")
    private let lock = NSLock()
    private var connectionTotal = 0
    private var requestTotal = 0
    private(set) var port: UInt16 = 0

    var connections: Int { lock.lock(); defer { lock.unlock() }; return connectionTotal }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return requestTotal }

    init() throws {
        listener = try NWListener(using: .tcp)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            throw NSError(domain: "FakeDebugPortServer", code: 1)
        }
        port = bound
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        lock.lock(); connectionTotal += 1; lock.unlock()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, data != nil else {
                connection.cancel()
                return
            }
            self.lock.lock(); self.requestTotal += 1; self.lock.unlock()
            let body = #"{"Browser":"Chrome/154.0.0.0","webSocketDebuggerUrl":"ws://127.0.0.1:1/devtools/browser/x"}"#
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data((head + body).utf8), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}
