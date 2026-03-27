import Foundation
import Network

public actor HTTPServer {
    private var listener: NWListener?
    private let handler: @Sendable (Data) async -> Data
    private var port: UInt16 = 0

    public var assignedPort: UInt16 { port }

    public init(handler: @escaping @Sendable (Data) async -> Data) {
        self.handler = handler
    }

    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resumed = true
                        Task { await self?.setPort(port) }
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [handler] connection in
                Task {
                    await Self.handleConnection(connection, handler: handler)
                }
            }

            listener.start(queue: DispatchQueue(label: "macoestro.http"))
        }
    }

    private func setPort(_ p: UInt16) {
        self.port = p
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func handleConnection(
        _ connection: NWConnection,
        handler: @escaping @Sendable (Data) async -> Data
    ) async {
        connection.start(queue: DispatchQueue(label: "macoestro.http.conn"))

        guard let requestData = await receiveHTTPRequest(connection) else {
            connection.cancel()
            return
        }

        let body = extractBody(from: requestData)
        let responseBody = await handler(body)
        let httpResponse = buildHTTPResponse(body: responseBody)

        await sendResponse(connection, data: httpResponse)
        connection.cancel()
    }

    private static func receiveHTTPRequest(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            var accumulated = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                    if let data = content {
                        accumulated.append(data)
                    }
                    if error != nil || isComplete {
                        continuation.resume(returning: accumulated.isEmpty ? nil : accumulated)
                        return
                    }
                    // Check if we have complete HTTP request (headers + body)
                    if let complete = parseHTTPComplete(accumulated) {
                        continuation.resume(returning: complete)
                        return
                    }
                    receive()
                }
            }
            receive()
        }
    }

    private static let headerTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n

    private static func findHeaderEnd(in data: Data) -> Int? {
        let bytes = Array(data)
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
                return i + 4 // index past \r\n\r\n
            }
        }
        return nil
    }

    private static func parseHTTPComplete(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        guard let bodyStart = findHeaderEnd(in: data) else { return nil }

        let headerStr = String(data: data.prefix(bodyStart), encoding: .utf8) ?? ""

        // Extract Content-Length
        var contentLength = 0
        for line in headerStr.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
                break
            }
        }

        let totalNeeded = bodyStart + contentLength
        if data.count >= totalNeeded {
            return data.prefix(totalNeeded)
        }
        return nil
    }

    private static func extractBody(from data: Data) -> Data {
        guard let bodyStart = findHeaderEnd(in: data) else { return Data() }
        return Data(data.dropFirst(bodyStart))
    }

    private static func buildHTTPResponse(body: Data) -> Data {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private static func sendResponse(_ connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
