import Foundation

/// The app's port and token, read once and re-read only when they stop working.
///
/// The bash bridge re-read both files for every request (two forks of `cat` apiece). They only
/// change when the app restarts, and a restart announces itself: connections are refused, or
/// the old token draws a 401.
public final class EndpointCache: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Endpoint?
    private let discover: () throws -> Endpoint
    private let startupDeadline: Date
    private let pollInterval: TimeInterval
    private let onMissing: (() -> Void)?
    private var missingReported = false

    /// `startupWait` is how long, from now, a missing endpoint is waited for rather than
    /// reported: an MCP client launches its bridge and the app in no particular order.
    ///
    /// `onMissing` runs once, the first time the files are not there: the production wiring
    /// starts the app in the background, so the wait that follows is for a launch already
    /// under way instead of for a human to notice.
    public init(startupWait: TimeInterval = 30,
                pollInterval: TimeInterval = 0.1,
                onMissing: (() -> Void)? = nil,
                discover: @escaping () throws -> Endpoint = { try Endpoint.discover() }) {
        self.startupDeadline = Date().addingTimeInterval(startupWait)
        self.pollInterval = pollInterval
        self.onMissing = onMissing
        self.discover = discover
    }

    /// The cached endpoint, or the files' contents. Blocks (polling) until the startup window
    /// closes, then throws if the app has still not published an endpoint.
    public func resolve() throws -> Endpoint {
        while true {
            lock.lock()
            if let current { lock.unlock(); return current }
            lock.unlock()

            do {
                let found = try discover()
                lock.lock()
                current = found
                lock.unlock()
                return found
            } catch {
                reportMissingOnce()
                guard Date() < startupDeadline else { throw error }
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
    }

    /// Called when `bad` just failed. Re-reads the files and returns the endpoint to retry
    /// with — or nil when they hold nothing new, since repeating the same request at the same
    /// address would only fail the same way. The cache is dropped in that case so the next
    /// request starts from the files again.
    public func refresh(replacing bad: Endpoint) -> Endpoint? {
        let fresh = try? discover()
        lock.lock()
        defer { lock.unlock() }
        if let fresh, fresh != bad {
            current = fresh
            return fresh
        }
        if current == bad { current = nil }
        return nil
    }

    /// Polls the files until they name a listener `accept` approves, or `timeout` passes.
    /// For a request that just found the app dead: the files may still name its old port, so
    /// the caller's `accept` (is one of this user's processes listening there?) is what tells
    /// the relaunched app's endpoint from the stale one.
    public func awaitEndpoint(timeout: TimeInterval, accept: (Endpoint) -> Bool) -> Endpoint? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = try? discover(), accept(found) {
                lock.lock()
                current = found
                lock.unlock()
                return found
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return nil
    }

    private func reportMissingOnce() {
        lock.lock()
        let first = !missingReported
        missingReported = true
        lock.unlock()
        if first { onMissing?() }
    }
}
