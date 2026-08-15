import Foundation

/// Serial lanes that own all Accessibility (AXUIElement) and CGEvent work.
///
/// Why this exists:
/// 1. **Responsiveness** — tool handlers used to run inside `await MainActor.run { … }`
///    with blocking `usleep`s, which froze the menu-bar UI and the permission Timer for
///    the duration of every type/drag/scroll. AX APIs and CGEvent posting have no main-
///    thread requirement; they only need to be *serialized*. Running them on a dedicated
///    actor keeps the main thread free.
/// 2. **No interleaving** — the HTTP server spawns a Task per connection, so two
///    `type_text`/`click` calls could otherwise interleave their activate→act steps on
///    the shared system focus.
///
/// **Serialization is PER APP, not global.** A single global actor made every tool call
/// in the process queue behind every other one, so driving N apps cost N × the wall
/// clock even though the operations touch disjoint processes. Two holds made that
/// expensive rather than theoretical: `snapshot` holds its lane for an entire AX tree
/// walk (72s observed on a large app) and `InputSimulator.typeText` holds it with a
/// per-character `usleep`. Under one global actor, either one froze every other app.
///
/// What is still shared, and therefore still globally serialized: operations that drive
/// **system-wide HID** — the `foreground: true` paths that activate an app and post to
/// the global event tap, moving the user's real cursor. Those contend for one cursor and
/// one frontmost app, so they all run on `globalInput`.
///
/// What this deliberately does NOT do: exclude background work from foreground work. A
/// PID-targeted `AXPress`/`postToPid` never moves the cursor and never changes the
/// frontmost app, so it shares no resource with a foreground op and has nothing to be
/// excluded from. Guarding that pair would require a reader/writer gate for no gain.
///
/// Main-thread-only calls (e.g. `NSRunningApplication.activate`) must stay on the
/// MainActor — perform those in a separate `await MainActor.run { … }` before/after the
/// `run` block.
public actor AXExecutor {
    /// Lane for operations that drive system-wide HID (`foreground: true`): they move one
    /// real cursor and change one frontmost app, so they must not overlap each other.
    public static let globalInput = AXExecutor()

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var lanes: [pid_t: AXExecutor] = [:]

    /// Evict dead-process lanes once the registry grows past this. A lane is ~an object
    /// header, so the bound is about not leaking unboundedly across a long session that
    /// drives many short-lived app launches — not about memory pressure.
    private static let laneEvictionThreshold = 64

    private init() {}

    /// The serial lane for PID-targeted work on `pid`. Work on different apps runs
    /// concurrently; work on the same app stays strictly ordered.
    public static func app(_ pid: pid_t) -> AXExecutor {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = lanes[pid] { return existing }
        if lanes.count >= laneEvictionThreshold {
            // Drop lanes whose process is gone. Safe at any moment: a lane holds no
            // state, so a dropped-then-recreated lane is indistinguishable from the
            // original except that in-flight work on the old instance keeps running
            // on it — and that work is for a PID that no longer exists.
            for (existingPID, _) in lanes where kill(existingPID, 0) != 0 {
                lanes.removeValue(forKey: existingPID)
            }
        }
        let lane = AXExecutor()
        lanes[pid] = lane
        return lane
    }

    /// Pick the lane an operation belongs on: the app's own lane normally, the shared
    /// global-input lane when the operation drives system-wide HID.
    public static func lane(pid: pid_t, foreground: Bool) -> AXExecutor {
        foreground ? globalInput : app(pid)
    }

    /// Run a synchronous AX/CGEvent body off the MainActor, serialized against other work
    /// **on this lane**. `T: Sendable` so results cross the actor boundary safely
    /// (`AXElement` is `@unchecked Sendable`).
    @discardableResult
    public func run<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T {
        try body()
    }

    /// Async pacing that suspends without blocking any lane — use between posted CGEvents
    /// instead of `usleep`. Static because pacing is just elapsed time: it needs no
    /// isolation, and running it on a lane would have been a hold with no work in it.
    public static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Number of live lanes. Test/diagnostic use only.
    public static var laneCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        return lanes.count
    }
}
