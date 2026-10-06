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

    /// `startupWait` is how long, from now, a missing endpoint is waited for rather than
    /// reported: an MCP client launches its bridge and the app in no particular order.
    public init(startupWait: TimeInterval = 30,
                pollInterval: TimeInterval = 0.1,
                discover: @escaping () throws -> Endpoint = { try Endpoint.discover() }) {
        self.startupDeadline = Date().addingTimeInterval(startupWait)
        self.pollInterval = pollInterval
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
}
