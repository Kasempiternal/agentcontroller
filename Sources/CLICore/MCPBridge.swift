import Foundation

/// `agentcontroller mcp`: the stdio transport an MCP client launches, relaying newline-delimited
/// JSON-RPC to the running app's loopback endpoint.
///
/// This replaces the bash bridge on the hot path. That script forks about fifteen processes per
/// request (grep, sed, head, cat, curl, subshells) — measured ~40ms a call against ~1ms for the
/// request itself — and every tool in a `run_steps`-free session pays it. One long-lived process
/// holding a connection-capable URLSession does the same relay in-process.
///
/// Contract, in the order a client meets it:
///   * stdin is read continuously and never blocked on a slow call, so a `ping` or a
///     `notifications/cancelled` is relayed while `tools/call`s are still running;
///   * at most `maxInFlight` `tools/call`s run at once, the rest queue (see `BoundedDispatcher`);
///   * stdout carries whole lines only, written by one serial writer;
///   * a request that cannot be delivered is answered with an error under its own id, so the
///     client does not wait out its timeout; a notification is never answered;
///   * each request has a hard 180s deadline, and a request the client abandons is cancelled on
///     the server by `notifications/cancelled` (relayed untouched) or by the dropped connection.
public final class MCPBridge: @unchecked Sendable {
    public static let maxInFlight = 8
    public static let requestDeadline: TimeInterval = 180

    private let session: URLSession
    private let cache: EndpointCache
    private let listener: ListenerCheck
    private let dispatcher = BoundedDispatcher(limit: MCPBridge.maxInFlight)
    private let output: LineOutput
    private let inFlight = DispatchGroup()
    private let work = DispatchQueue(label: "agentcontroller.mcp.work", attributes: .concurrent)
    private var signalSources: [DispatchSourceSignal] = []

    /// Names this process to the server. Every client numbers its JSON-RPC ids from 0, so the
    /// server keys in-flight requests by (client, id); a pid alone is reused across restarts and
    /// a stale cancel could hit the wrong call, so a random suffix rides along.
    private let clientID = "cli-\(getpid())-\(UUID().uuidString.lowercased().prefix(8))"

    public convenience init() {
        self.init(cache: EndpointCache(), output: StdoutWriter())
    }

    /// `output` is the stdout writer in production; tests substitute a collector.
    init(cache: EndpointCache, output: LineOutput, listener: ListenerCheck = ListenerCheck()) {
        self.cache = cache
        self.output = output
        self.listener = listener

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestDeadline
        // The per-request timeout restarts whenever bytes move; this one does not. It is the
        // real wall-clock ceiling.
        config.timeoutIntervalForResource = Self.requestDeadline
        config.httpMaximumConnectionsPerHost = Self.maxInFlight * 2
        // Loopback traffic must never be routed through a system proxy.
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    /// Runs until stdin closes and every accepted request has been answered, or a termination
    /// signal arrives. Does not return.
    public func run() -> Never {
        // A client that closes our stdout must not kill us with SIGPIPE mid-write; the write
        // error path exits instead.
        signal(SIGPIPE, SIG_IGN)
        signalSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [self] in shutDown() }
            source.resume()
            return source
        }
        readStdin()
        // Stdin closed: the client may still be waiting on replies to requests it already
        // sent, so let each one finish and reach stdout before exiting.
        inFlight.wait()
        output.flush()
        exit(0)
    }

    /// Blocks until every accepted request has been answered, or `timeout` passes (returns false).
    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        inFlight.wait(timeout: .now() + timeout) == .success
    }

    private func shutDown() -> Never {
        session.invalidateAndCancel()
        output.flush()
        exit(0)
    }

    private func readStdin() {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            for line in framer.push(Data(buffer[0..<count])) { accept(line) }
        }
        if let tail = framer.finish() { accept(tail) }
    }

    /// Hands one line to the relay. Returns immediately; the reply, if one is owed, goes to `output`.
    func accept(_ line: Data) {
        inFlight.enter()
        dispatcher.submit(gated: MCPLine.mayBeToolCall(line)) { [self] done in
            // Off the reader thread: resolving the endpoint can block (startup wait) and the
            // reader must keep draining stdin.
            work.async { [self] in
                forward(line) {
                    done()
                    self.inFlight.leave()
                }
            }
        }
    }

    private func forward(_ line: Data, completion: @escaping () -> Void) {
        let endpoint: Endpoint
        do {
            endpoint = try cache.resolve()
        } catch {
            fail(line, "AgentController is not running. Launch the AgentController menu bar app first.")
            completion()
            return
        }
        send(line, to: endpoint, retried: false, completion: completion)
    }

    private func send(_ line: Data, to endpoint: Endpoint, retried: Bool, completion: @escaping () -> Void) {
        // The endpoint is cached, and the port it names is free for any account on the Mac
        // to take once the app restarts or its listener dies. Whatever holds it would get
        // the bearer token and every tool call (typed text, scripts), and could answer in
        // the app's name — so nothing goes to a listener that is not running as this user.
        guard listener.isOurs(endpoint.port) else {
            // Nothing was delivered: as with a refused connection, the files may name the
            // app's new endpoint.
            if !retried, let fresh = cache.refresh(replacing: endpoint) {
                send(line, to: fresh, retried: true, completion: completion)
                return
            }
            fail(line, "Nothing running as you is listening on AgentController's port \(endpoint.port), so the request was not sent. Is the menu bar app running?")
            completion()
            return
        }

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = line
        request.timeoutInterval = Self.requestDeadline
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-AC-Client")

        session.dataTask(with: request) { [self] data, response, error in
            if let error {
                let code = (error as? URLError)?.code
                switch code {
                case .cannotConnectToHost, .cannotFindHost:
                    // Refused means nothing was delivered, so a retry cannot repeat a click.
                    // The app likely restarted on a new port; the files say.
                    if !retried, let fresh = cache.refresh(replacing: endpoint) {
                        send(line, to: fresh, retried: true, completion: completion)
                        return
                    }
                    fail(line, "Cannot connect to AgentController. Is the menu bar app running?")
                case .timedOut:
                    fail(line, "AgentController did not respond within \(Int(Self.requestDeadline))s (server busy or hung on the target app).")
                case .cancelled:
                    break
                default:
                    // Includes a connection lost mid-call. Not retried: the server may have
                    // already acted on the request.
                    fail(line, "AgentController connection failed: \(error.localizedDescription)")
                }
                completion()
                return
            }

            guard let http = response as? HTTPURLResponse else {
                fail(line, "AgentController returned a response the bridge could not read.")
                completion()
                return
            }

            switch http.statusCode {
            case 200:
                if let data, !data.isEmpty { output.writeLine(data) }
            case 204:
                break // notification acknowledged, or a cancelled request: no reply is owed
            case 401:
                // Stale token: the app restarted and reissued it. The server rejects before
                // dispatching, so retrying is safe.
                if !retried, let fresh = cache.refresh(replacing: endpoint) {
                    send(line, to: fresh, retried: true, completion: completion)
                    return
                }
                fail(line, "AgentController rejected the auth token (HTTP 401). Restart the app to reissue one.")
            default:
                fail(line, "AgentController rejected the request (HTTP \(http.statusCode)).")
            }
            completion()
        }.resume()
    }

    /// Answers an undeliverable request under its own id. A notification has nobody waiting, so
    /// it gets a line on stderr instead, which MCP clients surface in their server logs.
    private func fail(_ line: Data, _ message: String) {
        FileHandle.standardError.write(Data("agentcontroller mcp: \(message)\n".utf8))
        guard let id = MCPLine.envelope(of: line).id else { return }
        output.writeLine(MCPLine.errorLine(id: id, code: -32000, message: message))
    }
}

protocol LineOutput: AnyObject, Sendable {
    func writeLine(_ body: Data)
    func flush()
}

/// The only writer to stdout. A serial queue makes each line atomic with respect to the
/// others: replies can be megabytes (a screenshot), far past the pipe's atomic-write size, so
/// unserialised writers would interleave mid-line.
final class StdoutWriter: LineOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "agentcontroller.mcp.stdout")

    func writeLine(_ body: Data) {
        queue.async {
            let line = MCPLine.singleLine(body)
            guard Self.writeAll(line), Self.writeAll(Data([0x0A])) else {
                // The client closed our stdout: nobody is left to answer.
                exit(0)
            }
        }
    }

    /// Returns once every line queued so far has been written.
    func flush() {
        queue.sync {}
    }

    private static func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(STDOUT_FILENO, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { usleep(1_000); continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}
