import Foundation

/// Caps how many gated jobs run at once and queues the rest in arrival order. Ungated jobs
/// bypass the cap entirely.
///
/// The cap exists to keep a model from queueing hundreds of slow accessibility operations at
/// the server. It must not also stop the bridge from reading stdin or from relaying a ping or a
/// `notifications/cancelled` — which is why the bridge gates only `tools/call` and never blocks
/// the reader on a full cap: overflow waits here, in a list, not in the read loop.
public final class BoundedDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var running = 0
    private var waiting: [(_ done: @escaping () -> Void) -> Void] = []

    public init(limit: Int) {
        precondition(limit > 0, "a dispatcher that admits nothing would never run anything")
        self.limit = limit
    }

    /// Starts `work` immediately if it is ungated or a slot is free, else queues it. `work`
    /// is handed a `done` it must call once when the job finishes; calling it again is a
    /// no-op. `work` runs on the calling thread (or on whichever thread finishes a predecessor),
    /// so it must hand off to another queue rather than block.
    public func submit(gated: Bool, _ work: @escaping (_ done: @escaping () -> Void) -> Void) {
        guard gated else {
            work({})
            return
        }
        lock.lock()
        if running < limit {
            running += 1
            lock.unlock()
            work(makeDone())
        } else {
            waiting.append(work)
            lock.unlock()
        }
    }

    public var inFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public var queued: Int {
        lock.lock(); defer { lock.unlock() }
        return waiting.count
    }

    private func makeDone() -> () -> Void {
        let once = NSLock()
        var called = false
        return { [self] in
            once.lock()
            let first = !called
            called = true
            once.unlock()
            if first { finishOne() }
        }
    }

    private func finishOne() {
        lock.lock()
        if waiting.isEmpty {
            running -= 1
            lock.unlock()
        } else {
            // The slot passes straight to the next job, so `running` never dips below the
            // true count and a burst of finishes cannot over-admit.
            let next = waiting.removeFirst()
            lock.unlock()
            next(makeDone())
        }
    }
}
