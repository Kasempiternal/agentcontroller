import AppKit
import Foundation

/// FIFO async mutex. An actor method alone cannot hold exclusivity across an `await`:
/// actors are reentrant, so a task suspended inside `AXExecutor.globalInput` lets the next
/// one in. The activate -> verify-frontmost -> post sequence suspends several times, and
/// two of them interleaving is exactly the bug: call 1 activates A, call 2 activates B,
/// call 1 then posts its global click into B.
actor AsyncGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate straight to the next waiter (`held` stays true) so a newcomer
    /// cannot barge in between the release and the waiter's resumption.
    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Delivery of system-wide HID input (`foreground:true`) into the target app.
///
/// Global events land in whatever app is frontmost, not in the app the caller named. So
/// "activate, then post" is only safe if the post is conditional on the activation having
/// actually happened — `NSRunningApplication.activate()` only *requests* it, and the
/// request is refused when the system decides the caller may not take focus. Posting
/// anyway sends the click or keystrokes into the user's own app. The whole sequence
/// therefore runs under one gate so no other foreground call can change the frontmost app
/// between the check and the post.
public enum ForegroundInput {
    public enum Outcome<T: Sendable>: Sendable {
        case posted(T)
        /// The target never became frontmost, so nothing was posted.
        case notFrontmost(requested: pid_t, frontmost: String?)
    }

    /// A delivery split into chunks so frontmost can be re-checked between them.
    public enum ChunkedOutcome<T: Sendable>: Sendable {
        case posted([T])
        /// The target was not frontmost at some chunk boundary. `posted` holds the results
        /// of the chunks that did go out (empty when the target never came forward); every
        /// later chunk was NOT sent.
        case interrupted(requested: pid_t, frontmost: String?, posted: [T])
    }

    /// How long to wait for the window server to report the target frontmost.
    public static let verifyDeadline: Double = 1.0
    public static let verifyPollInterval: Double = 0.05
    /// Pause after the frontmost flip before posting: the flip is reported before the
    /// app's key window has settled, and an event posted in that gap is dropped.
    public static let settleSeconds: Double = 0.1

    private static let gate = AsyncGate()

    /// Activate `pid` if needed, confirm it is frontmost, and run `body` (which posts the
    /// global events) — all while holding the foreground gate. `body` runs on
    /// `AXExecutor.globalInput` and never runs when the app is not frontmost.
    public static func perform<T: Sendable>(pid: pid_t, _ body: @Sendable () -> T) async throws -> Outcome<T> {
        switch try await performChunked(pid: pid, chunks: 1, onInterrupt: {}, body: { _ in body() }) {
        case .posted(let results):
            return .posted(results[0])
        case .interrupted(let requested, let frontmost, _):
            return .notFrontmost(requested: requested, frontmost: frontmost)
        }
    }

    /// `perform` for a body that holds the keyboard or the mouse for longer than one
    /// instant — typed text, a drag. A single frontmost check at the start is stale a
    /// second later: the user can switch apps mid-way and the rest of the keystrokes land
    /// in whatever they switched to. So the work is cut into `chunks` and the target is
    /// re-checked before each one. The user switching away is not fought: the delivery
    /// stops, and `onInterrupt` runs (releasing a held mouse button) because the chunks
    /// already posted may have left input half-finished.
    ///
    /// `frontmost` is injectable so the chunk-boundary rule is testable without a window
    /// server; activation itself always goes through the real one.
    public static func performChunked<T: Sendable>(
        pid: pid_t,
        chunks: Int,
        onInterrupt: @Sendable () -> Void,
        frontmost: @Sendable () async -> pid_t? = { await ForegroundInput.frontmostPID() },
        body: @Sendable (_ chunk: Int) -> T
    ) async throws -> ChunkedOutcome<T> {
        await gate.acquire()
        do {
            let outcome = try await activateVerifyPost(
                pid: pid, chunks: chunks, onInterrupt: onInterrupt, frontmost: frontmost, body: body)
            await gate.release()
            return outcome
        } catch {
            await gate.release()
            throw error
        }
    }

    private static func activateVerifyPost<T: Sendable>(
        pid: pid_t,
        chunks: Int,
        onInterrupt: @Sendable () -> Void,
        frontmost: @Sendable () async -> pid_t?,
        body: @Sendable (_ chunk: Int) -> T
    ) async throws -> ChunkedOutcome<T> {
        if await frontmost() != pid {
            guard try await activateAndVerify(pid: pid) else { return await interruption(pid, posted: []) }
            try await AXExecutor.pause(settleSeconds)
            // The user can switch apps during the settle; the post must still be checked
            // against the app that is frontmost NOW, not the one that was a moment ago.
            guard await frontmost() == pid else { return await interruption(pid, posted: []) }
        }
        var posted: [T] = []
        for chunk in 0..<max(chunks, 0) {
            if chunk > 0, await frontmost() != pid {
                await AXExecutor.globalInput.run(onInterrupt)
                return await interruption(pid, posted: posted)
            }
            // A cancelled request must not start another chunk of input, and must not
            // leave a half-finished one behind.
            if Task.isCancelled {
                if !posted.isEmpty { await AXExecutor.globalInput.run(onInterrupt) }
                throw CancellationError()
            }
            posted.append(await AXExecutor.globalInput.run { body(chunk) })
        }
        return .posted(posted)
    }

    /// Ask for activation, then wait up to `verifyDeadline` for the window server to
    /// report `pid` frontmost. `activate()`'s own return value only says the request was
    /// accepted; this is the observed outcome. Not gated — callers that post input must go
    /// through `perform`.
    public static func activateAndVerify(pid: pid_t) async throws -> Bool {
        _ = await MainActor.run { AppManager.activate(pid: pid) }
        return try await waitUntilFrontmost(
            pid: pid, deadline: verifyDeadline, pollInterval: verifyPollInterval, frontmost: { await frontmostPID() })
    }

    private static func interruption<T: Sendable>(_ pid: pid_t, posted: [T]) async -> ChunkedOutcome<T> {
        let name = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        return .interrupted(requested: pid, frontmost: name, posted: posted)
    }

    public static func frontmostPID() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    /// Poll `frontmost` until it reports `pid` or `deadline` seconds pass. The provider is
    /// injected so the polling rule is testable without a window server. Throws
    /// `CancellationError` so an abandoned request stops polling instead of spinning.
    static func waitUntilFrontmost(
        pid: pid_t,
        deadline: Double,
        pollInterval: Double,
        frontmost: @Sendable () async -> pid_t?
    ) async throws -> Bool {
        let end = Date().addingTimeInterval(max(0, deadline))
        while true {
            if await frontmost() == pid { return true }
            guard Date() < end else { return false }
            try await AXExecutor.pause(pollInterval)
        }
    }

    /// Message for a chunked delivery that stopped partway. `progress` says what already
    /// went out ("12 of 40 characters"), because the user needs to know what was left in
    /// the target app, not just that something was refused.
    public static func interruptionMessage(requested: pid_t, frontmost: String?, progress: String) -> String {
        let front = frontmost.map { "'\($0)' is frontmost instead" } ?? "no app reported frontmost"
        return "Foreground input stopped partway (\(progress) sent): the target app (pid \(requested)) stopped being frontmost — \(front). The rest was NOT sent, because foreground input goes to whatever is frontmost and posting on would have landed in the wrong app. What was already sent stays in the target; check it before retrying."
    }

    public static func refusalMessage(requested: pid_t, frontmost: String?) -> String {
        let front = frontmost.map { "'\($0)' is still frontmost" } ?? "no app reported frontmost"
        return "Could not bring the target app (pid \(requested)) to the front within \(verifyDeadline)s — \(front). Nothing was sent: foreground input is delivered to the frontmost app, so posting anyway would have landed in the wrong app. Use activate_app first, or drop foreground:true to deliver to the app's PID in the background."
    }
}
