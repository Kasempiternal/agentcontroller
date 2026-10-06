import Foundation
@preconcurrency import ScreenCaptureKit

/// Time-bounded cache of one expensive async value, with a generation counter so an
/// `invalidate()` that lands while a fetch is in flight discards that fetch's result
/// instead of letting the pre-invalidation snapshot repopulate the cache.
public actor TTLCache<Value: Sendable> {
    public struct Snapshot: Sendable {
        public let value: Value
        /// False when this call waited on a fetch (its own or a concurrent one).
        public let wasCached: Bool
    }

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let fetch: @Sendable () async throws -> Value

    private var entry: (value: Value, at: Date)?
    private var inFlight: (generation: Int, task: Task<Value, Error>)?
    private var generation = 0

    public init(
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        self.ttl = ttl
        self.now = now
        self.fetch = fetch
    }

    public func snapshot() async throws -> Snapshot {
        if let entry, now().timeIntervalSince(entry.at) < ttl {
            return Snapshot(value: entry.value, wasCached: true)
        }

        // Coalesce: every concurrent caller shares the one running fetch instead of
        // each starting its own.
        if let inFlight {
            return Snapshot(value: try await inFlight.task.value, wasCached: false)
        }

        let started = generation
        let fetch = self.fetch
        let task = Task { try await fetch() }
        inFlight = (started, task)
        // A fetch that `invalidate()` already orphaned must not clear the slot its
        // successor now occupies.
        defer { if inFlight?.generation == started { inFlight = nil } }

        let value = try await task.value
        if started == generation { entry = (value, now()) }
        return Snapshot(value: value, wasCached: false)
    }

    public func invalidate() {
        generation += 1
        entry = nil
        inFlight = nil
    }
}

/// System-wide SCShareableContent, shared by every capture. Enumeration costs 50-200ms
/// and nearly every screenshot paid it under the old 100ms TTL (back-to-back screenshots
/// are seconds apart, not milliseconds). The longer TTL is safe because tools that
/// change windows call `invalidate()`, and `withContent` re-enumerates once when a
/// cached listing fails to produce a capture.
public struct ShareableContentCache: Sendable {
    public static let shared = ShareableContentCache()

    private let cache = TTLCache<SCShareableContent>(ttl: 2.5) {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.classify(error)
        }
    }

    /// Drop the cached listing. Called by every tool that opens, closes, hides, moves,
    /// or minimizes a window.
    public func invalidate() async {
        await cache.invalidate()
    }

    /// Runs `body` against the cached listing; `isFresh` is false for a cached one. If
    /// `body` throws on a cached listing, the failure may just be staleness (window
    /// closed, app relaunched since the listing was taken), so it runs once more against
    /// a fresh enumeration. A fresh listing's failure is final.
    public func withContent<T>(
        _ body: (_ content: SCShareableContent, _ isFresh: Bool) async throws -> T
    ) async throws -> T {
        let first = try await cache.snapshot()
        do {
            return try await body(first.value, !first.wasCached)
        } catch where first.wasCached && Self.refreshCanHelp(error) {
            await cache.invalidate()
            let second = try await cache.snapshot()
            return try await body(second.value, true)
        }
    }

    /// A fresh listing cannot fix a missing grant, and a cancelled caller is leaving.
    static func refreshCanHelp(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case CaptureError.permissionDenied = error { return false }
        return true
    }
}
