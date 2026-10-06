import Foundation

/// Running `tools/call` requests, keyed so `notifications/cancelled` can find the one to stop.
///
/// The key carries a client id because the server is shared: every stdio bridge (one per
/// Claude Code session) numbers its JSON-RPC ids from 0, so a bare id would let one session's
/// cancel kill another session's unrelated call.
///
/// A cancel can overtake its own request — the bridges forward lines concurrently, and a
/// notification is a few bytes while the request it names may be a megabyte — so a cancel
/// that finds nothing running leaves a short-lived tombstone that `register` consumes.
actor InFlightRegistry {
    struct Key: Hashable, Sendable {
        let client: String
        let id: JSONRPCId
    }

    private struct Entry {
        let token: UInt64
        let cancel: @Sendable () -> Void
    }

    private var running: [Key: Entry] = [:]
    private var tombstones: [Key: Date] = [:]
    private var nextToken: UInt64 = 0

    private let tombstoneTTL: TimeInterval
    /// Hard bound so a client spraying cancels for ids that never arrive cannot grow this
    /// without limit between expiry sweeps.
    private let tombstoneCapacity = 256

    init(tombstoneTTL: TimeInterval = 30) {
        self.tombstoneTTL = tombstoneTTL
    }

    /// Returns the token to pass to `finish`, or nil when a cancel for this key already
    /// arrived — in which case `cancel` has been invoked and the caller must not wait on it.
    func register(_ key: Key, cancel: @escaping @Sendable () -> Void) -> UInt64? {
        if let stamp = tombstones.removeValue(forKey: key), Date().timeIntervalSince(stamp) < tombstoneTTL {
            cancel()
            return nil
        }
        nextToken += 1
        running[key] = Entry(token: nextToken, cancel: cancel)
        return nextToken
    }

    /// Drops the entry only if it is still the one `register` returned `token` for, so a
    /// client that reuses an id cannot have its new request unregistered by the old one.
    func finish(_ key: Key, token: UInt64) {
        if running[key]?.token == token { running[key] = nil }
    }

    func cancel(_ key: Key) {
        if let entry = running[key] {
            entry.cancel()
            return
        }
        pruneTombstones()
        tombstones[key] = Date()
    }

    private func pruneTombstones() {
        let now = Date()
        tombstones = tombstones.filter { now.timeIntervalSince($0.value) < tombstoneTTL }
        if tombstones.count >= tombstoneCapacity,
           let oldest = tombstones.min(by: { $0.value < $1.value }) {
            tombstones[oldest.key] = nil
        }
    }

    var runningCount: Int { running.count }
    var tombstoneCount: Int { tombstones.count }
}
