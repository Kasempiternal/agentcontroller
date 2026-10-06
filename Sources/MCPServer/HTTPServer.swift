import Foundation
import Network
import Security

public actor HTTPServer {
    /// Receives the request body and the caller's `X-AC-Client` id (nil when absent). The task
    /// running it is cancelled if the client hangs up before the response is written.
    public typealias Handler = @Sendable (_ body: Data, _ clientId: String?) async -> Data?

    /// Readable (not settable) so tests can hand `listenerFailed` the live listener.
    private(set) var listener: NWListener?
    private let handler: Handler
    private var port: UInt16 = 0
    private var stopped = false
    private var onPortChange: (@Sendable (UInt16) -> Void)?

    /// Shared with the `@Sendable` connection handlers, which validate the Host header against
    /// it — and which therefore must see the new port after a listener restart.
    private let portBox = PortBox()

    /// Per-launch bearer token. Generated in `init` (before `start()` ever runs)
    /// so there is never an auth-not-armed window. 256 bits of CSPRNG entropy,
    /// hex-encoded. Clients MUST send `Authorization: Bearer <authToken>`.
    public let authToken: String

    /// Max accepted request body size (16 MiB). Larger bodies are rejected with 413.
    private static let maxBodySize = 16 * 1024 * 1024

    /// Cap on the `X-AC-Client` value so a client cannot make us hold arbitrary strings as
    /// in-flight keys.
    private static let maxClientIdLength = 128

    /// Wall-clock deadline for a complete request to arrive (slowloris protection).
    private let readDeadline: TimeInterval

    /// Restart attempts after a listener dies, with doubling backoff from 0.5s.
    private static let restartAttempts = 6

    public var assignedPort: UInt16 { port }

    public init(readDeadline: TimeInterval = 10, handler: @escaping Handler) {
        self.handler = handler
        self.readDeadline = readDeadline
        self.authToken = Self.generateToken()
    }

    /// Called with the new port whenever the listener had to be rebuilt after it failed. The
    /// bridges re-read the port file on a connection failure, so the owner of that file must
    /// rewrite it here. Not called for the initial `start()`.
    public func setPortChangeHandler(_ handler: @escaping @Sendable (UInt16) -> Void) {
        onPortChange = handler
    }

    /// 32 random bytes (256 bits) from the system CSPRNG, hex-encoded.
    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback: SecRandomCopyBytes effectively never fails on macOS, but
            // never ship a predictable token — synthesize from UUIDs if it does.
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func start() async throws -> UInt16 {
        stopped = false
        return try await launchListener(preferring: nil)
    }

    /// Binds a fresh loopback listener, resuming exactly once: on `.ready`, or on a failure or
    /// cancellation that happens before it. A `.failed` AFTER ready is a dead server, and is
    /// routed to `listenerFailed` instead of being dropped.
    private func launchListener(preferring preferred: UInt16?) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Pin the listener to IPv4 loopback so it never binds 0.0.0.0/::.
        let requested = preferred.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: requested)

        let listener = try NWListener(using: params)
        self.listener = listener

        let token = authToken
        let handler = self.handler
        let portBox = self.portBox
        let readDeadline = self.readDeadline

        do {
            let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
                // Single-shot continuation guard. The stateUpdateHandler is @Sendable and
                // may fire concurrently with retries, so guard resume() with a lock-backed box.
                let resumeBox = ContinuationBox()

                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue, resumeBox.claim() {
                            portBox.set(port)
                            continuation.resume(returning: port)
                        }
                    case .failed(let error):
                        if resumeBox.claim() {
                            listener.cancel()
                            continuation.resume(throwing: error)
                        } else {
                            Task { await self?.listenerFailed(listener) }
                        }
                    case .cancelled:
                        // Cancelled before ready (stop() raced start()): without this the
                        // continuation is never resumed and start() hangs forever.
                        if resumeBox.claim() {
                            continuation.resume(throwing: CancellationError())
                        }
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { connection in
                    Task {
                        await Self.handleConnection(
                            connection,
                            handler: handler,
                            authToken: token,
                            expectedPort: portBox.get(),
                            readDeadline: readDeadline
                        )
                    }
                }

                listener.start(queue: DispatchQueue(label: "agentcontroller.http"))
            }
            port = bound
            return bound
        } catch {
            listener.cancel()
            if self.listener === listener { self.listener = nil }
            throw error
        }
    }

    /// The listener died while serving (NWListener reports `.failed` when its socket is torn
    /// down — network stack reset, wake from sleep). Without this the app kept showing
    /// "Running on port N" while nothing listened on it.
    func listenerFailed(_ failed: NWListener) async {
        guard !stopped, listener === failed else { return }
        failed.cancel()
        listener = nil

        var delay: UInt64 = 500_000_000
        for _ in 0..<Self.restartAttempts {
            if stopped { return }
            do {
                // Same port first, so bridges that cached it keep working untouched.
                let reborn: UInt16
                do { reborn = try await launchListener(preferring: port) }
                catch { reborn = try await launchListener(preferring: nil) }
                if stopped {
                    listener?.cancel()
                    listener = nil
                    return
                }
                onPortChange?(reborn)
                return
            } catch {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 8_000_000_000)
            }
        }
        print("AgentController MCP listener failed and could not be restarted")
    }

    public func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
    }

    private static func handleConnection(
        _ connection: NWConnection,
        handler: @escaping Handler,
        authToken: String,
        expectedPort: UInt16,
        readDeadline: TimeInterval
    ) async {
        connection.start(queue: DispatchQueue(label: "agentcontroller.http.conn"))

        let received = await receiveHTTPRequest(connection, deadline: readDeadline)

        guard let requestData = received.data else {
            // Either an empty/closed connection, or an over-limit body (413).
            if received.tooLarge {
                await sendResponse(connection, data: buildSimpleResponse(
                    status: "413 Payload Too Large",
                    message: "Request body exceeds limit"))
            }
            connection.cancel()
            return
        }

        let headers = parseHeaders(from: requestData)

        // P0.2 — reject DNS-rebinding / browser-originated requests.
        // A stdio bridge never sets Origin; only a browser does.
        if headers["origin"] != nil {
            await sendResponse(connection, data: buildSimpleResponse(
                status: "403 Forbidden", message: "Origin not allowed"))
            connection.cancel()
            return
        }
        if !isHostAllowed(headers["host"], expectedPort: expectedPort) {
            await sendResponse(connection, data: buildSimpleResponse(
                status: "403 Forbidden", message: "Host not allowed"))
            connection.cancel()
            return
        }

        // P0.1 — require Authorization: Bearer <authToken>, constant-time compare.
        guard let authValue = headers["authorization"],
              authMatches(authValue, expected: authToken) else {
            await sendResponse(connection, data: buildSimpleResponse(
                status: "401 Unauthorized",
                message: "Missing or invalid bearer token",
                extraHeaders: ["WWW-Authenticate": "Bearer"]))
            connection.cancel()
            return
        }

        let body = extractBody(from: requestData)
        let clientId = headers["x-ac-client"]
            .map { String($0.prefix(maxClientIdLength)) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Its own Task so a client that gives up (curl --max-time, a killed bridge) can stop
        // the work instead of leaving a tool running for a caller that is gone.
        let work = Task { await handler(body, clientId) }
        cancelWhenPeerCloses(connection) { work.cancel() }
        let responseBody = await work.value

        let httpResponse: Data
        if let responseBody {
            httpResponse = buildHTTPResponse(body: responseBody)
        } else {
            httpResponse = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
        }

        await sendResponse(connection, data: httpResponse)
        connection.cancel()
    }

    /// Once the request is read nothing else is expected on the connection, so the only thing
    /// a pending receive can report is the peer going away (FIN, or a reset). That is a hang-up
    /// whether or not the client ever intended to read the response; a client that half-closes
    /// after sending and still waits for a reply would be cancelled here, and no client of this
    /// server does that (bridges use curl/URLSession, which hold the socket open).
    private static func cancelWhenPeerCloses(_ connection: NWConnection, _ onClose: @escaping @Sendable () -> Void) {
        func listen() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { content, _, isComplete, error in
                if error != nil || isComplete {
                    onClose()
                    return
                }
                listen()
            }
        }
        listen()
    }

    /// Result of an attempted request read. `tooLarge` flags an over-limit body so
    /// the caller can answer 413 rather than silently dropping the connection.
    private struct ReceiveResult {
        let data: Data?
        let tooLarge: Bool
    }

    private static func receiveHTTPRequest(_ connection: NWConnection, deadline: TimeInterval) async -> ReceiveResult {
        // Race the receive loop against a wall-clock deadline (slowloris protection).
        let timedOut = Flag()
        let received = await withTaskGroup(of: ReceiveResult?.self) { group -> ReceiveResult? in
            group.addTask {
                await receiveLoop(connection)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                // A cancelled sleep means the request arrived in time.
                guard !Task.isCancelled else { return nil }
                timedOut.set()
                // The receive child is parked in a continuation that group.cancelAll() cannot
                // wake; without this the group waited on it forever and the deadline never
                // fired. Cancelling the connection completes that receive with an error.
                connection.cancel()
                return nil
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        if timedOut.isSet { return ReceiveResult(data: nil, tooLarge: false) }
        return received ?? ReceiveResult(data: nil, tooLarge: false)
    }

    private static let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    private static func receiveLoop(_ connection: NWConnection) async -> ReceiveResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ReceiveResult, Never>) in
            let resumeBox = ContinuationBox()
            var accumulated = Data()
            var headersInspected = false
            func finish(_ result: ReceiveResult) {
                if resumeBox.claim() {
                    continuation.resume(returning: result)
                }
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                    if let data = content {
                        accumulated.append(data)
                    }
                    // Bound total buffered bytes regardless of Content-Length honesty.
                    if accumulated.count > maxBodySize + 65536 {
                        finish(ReceiveResult(data: nil, tooLarge: true))
                        return
                    }
                    // Reject early once headers declare an over-limit body.
                    if let declared = declaredContentLength(accumulated), declared > maxBodySize {
                        finish(ReceiveResult(data: nil, tooLarge: true))
                        return
                    }
                    if let complete = parseHTTPComplete(accumulated) {
                        finish(ReceiveResult(data: complete, tooLarge: false))
                        return
                    }
                    // curl sends `Expect: 100-continue` with bodies over 1 MiB and then WAITS
                    // for the interim response before sending the body — measured 1.004s of
                    // pure stall on a 1.1 MB request, against 6ms once answered.
                    if !headersInspected, findHeaderEnd(in: accumulated) != nil {
                        headersInspected = true
                        if parseHeaders(from: accumulated)["expect"]?.lowercased() == "100-continue" {
                            connection.send(content: continueResponse, completion: .idempotent)
                        }
                    }
                    if error != nil || isComplete {
                        finish(ReceiveResult(data: accumulated.isEmpty ? nil : accumulated, tooLarge: false))
                        return
                    }
                    receive()
                }
            }
            receive()
        }
    }

    private static let headerTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n

    /// Bounds-safe: returns the index just past the first `\r\n\r\n`, or nil.
    /// Safe for 0–3 byte and truncated inputs (no ClosedRange trap).
    private static func findHeaderEnd(in data: Data) -> Int? {
        data.range(of: Data(Self.headerTerminator))?.upperBound
    }

    /// Parse Content-Length from a (possibly partial) buffer, if headers are complete.
    private static func declaredContentLength(_ data: Data) -> Int? {
        guard let bodyStart = findHeaderEnd(in: data) else { return nil }
        let headerStr = String(data: data.prefix(bodyStart), encoding: .utf8) ?? ""
        for line in headerStr.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    private static func parseHTTPComplete(_ data: Data) -> Data? {
        guard let bodyStart = findHeaderEnd(in: data) else { return nil }

        let contentLength = declaredContentLength(data) ?? 0
        guard contentLength >= 0, contentLength <= maxBodySize else { return nil }

        let totalNeeded = bodyStart + contentLength
        if data.count >= totalNeeded {
            return data.prefix(totalNeeded)
        }
        return nil
    }

    /// Bounds-safe for 0–3 byte and header-only inputs.
    private static func extractBody(from data: Data) -> Data {
        guard let bodyStart = findHeaderEnd(in: data) else { return Data() }
        return Data(data.dropFirst(bodyStart))
    }

    /// Parse request headers into a lowercased-key dictionary. The request line is skipped.
    private static func parseHeaders(from data: Data) -> [String: String] {
        guard let bodyStart = findHeaderEnd(in: data) else { return [:] }
        let headerStr = String(data: data.prefix(bodyStart), encoding: .utf8) ?? ""
        var result: [String: String] = [:]
        var isFirstLine = true
        for line in headerStr.split(separator: "\r\n", omittingEmptySubsequences: true) {
            if isFirstLine {
                isFirstLine = false // request line ("POST /mcp HTTP/1.1")
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// Allow only loopback Host values for this server's port (DNS-rebinding defense).
    private static func isHostAllowed(_ host: String?, expectedPort: UInt16) -> Bool {
        guard let host else { return false }
        let allowed: Set<String> = [
            "127.0.0.1:\(expectedPort)",
            "localhost:\(expectedPort)",
        ]
        return allowed.contains(host.lowercased())
    }

    /// Constant-time bearer-token check. Parses "Bearer <token>" then compares the
    /// token bytes without early exit on the first differing byte.
    private static func authMatches(_ headerValue: String, expected: String) -> Bool {
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)
        let prefix = "bearer "
        guard trimmed.lowercased().hasPrefix(prefix) else { return false }
        let presented = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(Array(presented.utf8), Array(expected.utf8))
    }

    /// Length-aware constant-time comparison: accumulate XOR over equal-length arrays.
    private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        // Length difference is itself a (safe) early signal; still fold both lengths
        // into the result so equal-length-but-different inputs take constant time.
        var diff: UInt8 = a.count == b.count ? 0 : 1
        let count = max(a.count, b.count)
        guard count > 0 else { return diff == 0 }
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= (x ^ y)
        }
        return diff == 0
    }

    private static func buildHTTPResponse(body: Data) -> Data {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    /// Generic non-2xx response builder (401/403/413/etc.) with a tiny JSON body.
    private static func buildSimpleResponse(
        status: String,
        message: String,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        let bodyString = "{\"error\":\"\(message)\"}"
        let body = Data(bodyString.utf8)
        var header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in extraHeaders {
            header += "\(k): \(v)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private static func sendResponse(_ connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeBox = ContinuationBox()
            connection.send(content: data, completion: .contentProcessed { _ in
                if resumeBox.claim() {
                    continuation.resume()
                }
            })
        }
    }
}

// MARK: - Concurrency helpers

/// Lock-backed single-shot flag for safely resuming a continuation exactly once
/// from `@Sendable` callbacks that may fire more than once or concurrently.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Returns true exactly once (the first caller), false thereafter.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Lock-backed mutable port holder shared with `@Sendable` connection handlers.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0

    func set(_ p: UInt16) {
        lock.lock(); defer { lock.unlock() }
        value = p
    }

    func get() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Lock-backed one-way flag for `@Sendable` closures that must tell a sibling task something
/// happened (here: the read deadline fired, so a failed receive is a timeout, not a request).
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
