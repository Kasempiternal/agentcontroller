import CryptoKit
import Foundation
import MCPServer
import Network

/// A user's Chrome as the CDP backend sees it: the /json endpoints AND the pages' DevTools
/// WebSockets on one loopback port, the way a real debug port serves them. Tests script the
/// CDP answers through `respond` and read back every method the backend sent.
final class FakeChrome: @unchecked Sendable {
    /// The `result` for one CDP command, or nil to leave it unanswered.
    typealias Responder = @Sendable (_ method: String, _ params: JSONValue) -> JSONValue?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-fake-chrome")
    private let lock = NSLock()
    private var received: [String] = []
    private var sockets = 0
    private var open: [NWConnection] = []
    private var bodies: [String: String] = [:]
    private var responder: Responder = { _, _ in .object([:]) }
    private(set) var port: UInt16 = 0

    /// CDP methods received over WebSockets, in arrival order.
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return received }
    /// WebSocket handshakes completed.
    var socketCount: Int { lock.lock(); defer { lock.unlock() }; return sockets }

    init() throws {
        listener = try NWListener(using: .tcp)
    }

    /// The body served at `path` (query ignored). Unset paths get a browser version document.
    func serve(_ path: String, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        bodies[path] = body
    }

    func respond(_ responder: @escaping Responder) {
        lock.lock(); defer { lock.unlock() }
        self.responder = responder
    }

    func forgetMethods() {
        lock.lock(); defer { lock.unlock() }
        received.removeAll()
    }

    /// A /json/list entry whose socket is on this same port, as Chrome reports it.
    func pageEntry(id: String, url: String) -> String {
        #"{"id":"\#(id)","type":"page","url":"\#(url)","webSocketDebuggerUrl":"ws://127.0.0.1:\#(port)/devtools/page/\#(id)"}"#
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            throw NSError(domain: "FakeChrome", code: 1)
        }
        port = bound
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let all = open
        open.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        lock.lock(); open.append(connection); lock.unlock()
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil && !isComplete { self.readRequest(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let rest = Data(buffer[end.upperBound...])
            self.handle(head: head, rest: rest, on: connection)
        }
    }

    private func handle(head: String, rest: Data, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n"
            lock.lock(); sockets += 1; lock.unlock()
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            readFrames(connection, buffer: rest)
            return
        }

        lock.lock()
        let body = bodies[path]
            ?? #"{"Browser":"Chrome/154.0.0.0","webSocketDebuggerUrl":"ws://127.0.0.1:\#(port)/devtools/browser/fake"}"#
        lock.unlock()
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - WebSocket

    private func readFrames(_ connection: NWConnection, buffer: Data) {
        var buffer = buffer
        while let (opcode, payload, used) = Self.frame(in: buffer) {
            buffer.removeFirst(used)
            switch opcode {
            case 0x1: command(String(decoding: payload, as: UTF8.self), on: connection)
            case 0x8: connection.cancel(); return
            case 0x9: write(opcode: 0xA, payload, on: connection)
            default: break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else { return }
            self.readFrames(connection, buffer: buffer + data)
            if isComplete { connection.cancel() }
        }
    }

    /// One complete client frame at the start of `buffer`: (opcode, unmasked payload, bytes used).
    private static func frame(in buffer: Data) -> (UInt8, Data, Int)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let mask = masked ? Array(bytes[offset..<min(offset + 4, bytes.count)]) : []
        if masked { offset += 4 }
        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<offset + length])
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        return (bytes[0] & 0x0F, Data(payload), offset + length)
    }

    private func command(_ text: String, on connection: NWConnection) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let id = message["id"]?.intValue, let method = message["method"]?.stringValue else { return }
        lock.lock()
        received.append(method)
        let responder = self.responder
        lock.unlock()
        guard let result = responder(method, message["params"] ?? .object([:])),
              let reply = try? JSONEncoder().encode(JSONValue.object(["id": .int(id), "result": result])) else { return }
        write(opcode: 0x1, reply, on: connection)
    }

    private func write(opcode: UInt8, _ payload: Data, on connection: NWConnection) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        } else {
            frame.append(127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) })
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
