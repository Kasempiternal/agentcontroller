import Foundation

/// User-controlled hard block on every focus-stealing action.
///
/// Tool descriptions steer agents toward the background-safe paths, but a
/// description is only a hint — a driving model can still call `activate_app`
/// or pass `foreground:true` mid-run and yank the user's focus (observed in the
/// wild: an agent activated the app "to take a screenshot" that never needed
/// it). Focus Guard is the guarantee: while enabled (the default), the tool
/// dispatcher refuses those calls with an instructive error instead of
/// executing them. Toggleable from the menu-bar icon; persisted across
/// launches.
public enum FocusGuard {
    private static let defaultsKey = "focusGuardEnabled"
    private static let lock = NSLock()
    private static var cached: Bool = (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? true

    public static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public static func setEnabled(_ enabled: Bool) {
        lock.lock()
        cached = enabled
        lock.unlock()
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    /// Error text returned to the agent for a refused call. Written to re-steer
    /// the model onto the background path, not just to say "no".
    public static func denialMessage(for action: String) -> String {
        "Focus Guard is ON — refused '\(action)' because it would steal the user's focus and cursor. " +
        "You almost never need it: screenshot_window captures background and even hidden windows, and " +
        "click/type_text/navigate_menu/scroll are background-safe by default — retry without it. " +
        "Only if the app genuinely ignores background (PID-targeted) input should you ask the user to " +
        "toggle Focus Guard off in the Deskestro menu-bar icon."
    }
}
