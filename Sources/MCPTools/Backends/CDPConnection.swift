import Foundation
import MCPServer

/// Every way a CDP call can fail, split by what the caller should do next.
/// `transport` means the socket is gone — drop the connection and reconnect; everything
/// else leaves the connection usable.
enum CDPError: Error, LocalizedError, Equatable {
    case transport(String)
    case timeout(method: String, seconds: TimeInterval)
    case remote(String)
    case stale
    case javascript(String)
    case navigationFailed(url: String, reason: String)
    case notClickable(String)

    /// Chrome words "this node id is no longer valid" several ways depending on which
    /// domain method received it. All of them mean the agent's element id is out of date.
    static func fromRemote(message: String) -> CDPError {
        let staleMarkers = [
            "No node with given id",
            "Could not find node with given id",
            "Node is detached from document",
            "Cannot find context with specified id",
        ]
        if staleMarkers.contains(where: { message.contains($0) }) { return .stale }
        return .remote(message)
    }

    var isTransport: Bool {
        if case .transport = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .transport(let reason):
            return "The page connection was lost (\(reason)). Call snapshot again to reconnect."
        case .timeout(let method, let seconds):
            return "Chrome did not answer \(method) within \(Int(seconds))s."
        case .remote(let message):
            return "Chrome rejected the command: \(message)"
        case .stale:
            return "Stale element id: that node is gone from the page (it navigated or re-rendered). Call snapshot again for fresh ids."
        case .javascript(let description):
            return "JavaScript exception: \(description)"
        case .navigationFailed(let url, let reason):
            return "Navigation to \(url) failed: \(reason)"
        case .notClickable(let why):
            return "Element cannot be clicked: \(why)"
        }
    }
}

/// One decoded WebSocket frame from Chrome. Responses carry the `id` of the request that
/// asked for them; events carry only a method name.
enum CDPFrame: Equatable {
    case response(id: Int, result: JSONValue)
    case failure(id: Int, message: String)
    case event(method: String)
    case other

    static func parse(_ data: Data) -> CDPFrame {
        // Chrome serialises events as {"method":"X","params":…}. After Runtime/Page are
        // enabled, console and lifecycle events arrive constantly and their params can
        // be large, so read the method without decoding the payload.
        if let method = peekEventMethod(data) { return .event(method: method) }
        guard let json = JSONValue(jsonData: data) else { return .other }
        if let id = json["id"]?.intValue {
            if let error = json["error"] {
                return .failure(id: id, message: error["message"]?.stringValue ?? "CDP error")
            }
            return .response(id: id, result: json["result"] ?? .object([:]))
        }
        if let method = json["method"]?.stringValue { return .event(method: method) }
        return .other
    }

    static func peekEventMethod(_ data: Data) -> String? {
        let prefix = Array(#"{"method":""#.utf8)
        guard data.count > prefix.count, data.prefix(prefix.count).elementsEqual(prefix) else { return nil }
        let rest = data.dropFirst(prefix.count)
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
    }
}

/// One WebSocket to one page target.
///
/// A single reader loop owns `receive()` and routes each frame to the request that is
/// waiting for its `id`. The previous design had every `send` call `receive()` itself,
/// so two concurrent calls consumed each other's responses and both timed out; it also
/// could not enforce its 15s timeout, because a pending `receive()` is not interruptible
/// from the caller's side.
actor CDPConnection {
    /// URLSessionWebSocketTask defaults to 1 MiB per message. `Accessibility.getFullAXTree`
    /// on a large page is far bigger; the socket was killed on receive and the dead
    /// connection stayed cached.
    static let maximumMessageSize = 256 << 20

    private struct Pending {
        var continuation: CheckedContinuation<JSONValue, Error>
        var timer: Task<Void, Never>?
    }

    private struct EventWaiter {
        var method: String
        var fired = false
        var continuation: CheckedContinuation<Bool, Never>?
        var timer: Task<Void, Never>?
    }

    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var nextWaiter: UInt64 = 1
    private var eventWaiters: [UInt64: EventWaiter] = [:]
    private(set) var closedReason: String?

    init(url: URL) {
        self.url = url
    }

    var isOpen: Bool { task != nil && closedReason == nil }

    /// `enablingPage: false` for the browser-level endpoint, which has no Page domain.
    func open(enablingPage: Bool = true) async throws {
        let task = ChromeLauncher.loopbackSession.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumMessageSize
        self.task = task
        task.resume()
        reader = Task { await self.readLoop(task) }
        guard enablingPage else { return }
        do {
            _ = try await send(method: "Page.enable")
        } catch {
            close(reason: "open failed")
            throw error
        }
    }

    func close(reason: String = "closed") {
        guard closedReason == nil else { return }
        closedReason = reason
        reader?.cancel()
        reader = nil
        task?.cancel(with: .goingAway, reason: nil)
        failEverything(CDPError.transport(reason))
    }

    func send(method: String, params: JSONValue = .object([:]), timeout: TimeInterval = 15) async throws -> JSONValue {
        guard let task, closedReason == nil else {
            throw CDPError.transport(closedReason ?? "socket not open")
        }
        let id = nextID
        nextID += 1
        let envelope = JSONValue.object([
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ])
        guard let text = String(data: try JSONEncoder().encode(envelope), encoding: .utf8) else {
            throw CDPError.remote("could not encode \(method)")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                // Registered before the frame leaves, so a response can never beat its waiter.
                pending[id] = Pending(
                    continuation: continuation,
                    timer: Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        self.settle(id, .failure(CDPError.timeout(method: method, seconds: timeout)))
                    }
                )
                Task {
                    do {
                        try await task.send(.string(text))
                    } catch {
                        self.settle(id, .failure(CDPError.transport(error.localizedDescription)))
                    }
                }
            }
        } onCancel: {
            Task { await self.settle(id, .failure(CancellationError())) }
        }
    }

    /// Register interest in the next `method` event BEFORE sending the command that
    /// triggers it — the event can arrive ahead of the command's own response.
    func armEvent(_ method: String) -> UInt64 {
        let token = nextWaiter
        nextWaiter += 1
        eventWaiters[token] = EventWaiter(method: method)
        return token
    }

    func disarmEvent(_ token: UInt64) {
        guard let waiter = eventWaiters.removeValue(forKey: token) else { return }
        waiter.timer?.cancel()
        waiter.continuation?.resume(returning: false)
    }

    /// True if the event fired, false on timeout or a closed socket.
    func awaitEvent(_ token: UInt64, timeout: TimeInterval) async -> Bool {
        guard let waiter = eventWaiters[token] else { return false }
        if waiter.fired {
            eventWaiters[token] = nil
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            eventWaiters[token]?.continuation = continuation
            eventWaiters[token]?.timer = Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.disarmEvent(token)
            }
        }
    }

    /// Receives and parses off the actor. A getFullAXTree reply can be tens of MB; parsing
    /// it on the actor would hold every other request's response and timeout behind it.
    private nonisolated func readLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let frame: CDPFrame
                switch try await task.receive() {
                case .string(let text): frame = CDPFrame.parse(Data(text.utf8))
                case .data(let data): frame = CDPFrame.parse(data)
                @unknown default: continue
                }
                await route(frame)
            } catch {
                await readerFailed(error)
                return
            }
        }
    }

    private func readerFailed(_ error: Error) {
        guard closedReason == nil else { return }
        closedReason = error.localizedDescription
        failEverything(CDPError.transport(error.localizedDescription))
    }

    private func route(_ frame: CDPFrame) {
        switch frame {
        case .response(let id, let result):
            settle(id, .success(result))
        case .failure(let id, let message):
            settle(id, .failure(CDPError.fromRemote(message: message)))
        case .event(let method):
            deliver(event: method)
        case .other:
            break
        }
    }

    private func settle(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(with: result)
    }

    private func deliver(event method: String) {
        for (token, waiter) in eventWaiters where waiter.method == method && !waiter.fired {
            if let continuation = waiter.continuation {
                waiter.timer?.cancel()
                eventWaiters[token] = nil
                continuation.resume(returning: true)
            } else {
                eventWaiters[token]?.fired = true
            }
        }
    }

    private func failEverything(_ error: Error) {
        let all = pending
        pending.removeAll()
        for (_, entry) in all {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: error)
        }
        let waiters = eventWaiters
        eventWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.timer?.cancel()
            waiter.continuation?.resume(returning: false)
        }
    }
}

extension JSONValue {
    /// Foundation's native parser, then a structural copy. JSONValue's Codable init probes
    /// five types per value and throws on four of them — measured 6.4s for one 19 MB
    /// `Accessibility.getFullAXTree` frame, against well under a second this way.
    init?(jsonData data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(foundation: object)
    }

    init(foundation object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let array as [Any]:
            self = .array(array.map { JSONValue(foundation: $0) })
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { JSONValue(foundation: $0) })
        default:
            self = .null
        }
    }
}
