import Foundation

/// Serial actor that owns all Accessibility (AXUIElement) and CGEvent work.
///
/// Why this exists:
/// 1. **Responsiveness** — tool handlers used to run inside `await MainActor.run { … }`
///    with blocking `usleep`s, which froze the menu-bar UI and the permission Timer for
///    the duration of every type/drag/scroll. AX APIs and CGEvent posting have no main-
///    thread requirement; they only need to be *serialized*. Running them on a dedicated
///    actor keeps the main thread free.
/// 2. **No interleaving** — the HTTP server spawns a Task per connection, so two
///    `type_text`/`click` calls could previously interleave their activate→act steps on
///    the shared system focus. Funnelling every input-producing operation through one
///    serial actor makes them run one-at-a-time.
///
/// Main-thread-only calls (e.g. `NSRunningApplication.activate`) must stay on the
/// MainActor — perform those in a separate `await MainActor.run { … }` before/after the
/// `AXExecutor.run` block.
public actor AXExecutor {
    public static let shared = AXExecutor()
    private init() {}

    /// Run a synchronous AX/CGEvent body off the MainActor, serialized against all other
    /// AXExecutor work. `T: Sendable` so results cross the actor boundary safely
    /// (`AXElement` is `@unchecked Sendable`).
    @discardableResult
    public func run<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T {
        try body()
    }

    /// Async pacing that suspends without blocking the executor thread — use between
    /// posted CGEvents instead of `usleep`. Safe to call from inside actor-isolated code
    /// because it awaits rather than spins.
    public func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
