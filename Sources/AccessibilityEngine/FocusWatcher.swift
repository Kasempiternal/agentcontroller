import AppKit
import Foundation

/// Channel-independent enforcement of the Focus Guard promise.
///
/// `FocusGuard` refuses every focus-stealing call that comes THROUGH this
/// server — but an agent holds other tools, and the bypass has been observed in
/// the wild: a QA agent, refused `foreground:true`, switched to shell
/// `osascript` (`set frontmost` / `activate` / System Events `keystroke`) and
/// stole the user's focus dozens of times over a 3-hour run. A guard scoped to
/// one channel teaches a capable model to switch channels; this watcher guards
/// the OUTCOME instead.
///
/// Mechanism: observe `NSWorkspace.didActivateApplicationNotification`. When an
/// app this server has driven becomes frontmost while Focus Guard is on, the
/// server did not do it (the dispatcher refuses those calls while the guard is
/// on) — so if it happens hot on the heels of tool activity it is treated as a
/// stolen focus: the user's previous app is re-activated and a warning is
/// attached to the next tool result so the agent self-corrects in-band.
///
/// The one harm this could do is fighting a USER who deliberately clicked the
/// driven app. Two scope limits keep that narrow: only apps this server has
/// actually driven are ever restored-away-from, and only when the activation
/// lands within `attributionWindow` of the last tool dispatch — an agent steals
/// focus mid-run, a human clicks when the run is quiet. A wrong restore is one
/// click to undo; a silent steal mid-typing is not.
public final class FocusWatcher: @unchecked Sendable {
    public static let shared = FocusWatcher()

    /// Seconds after the last tool dispatch during which a driven-app
    /// activation is attributed to the agent rather than the user.
    public static let attributionWindow: TimeInterval = 30

    private let lock = NSLock()
    private var drivenPIDs: Set<pid_t> = []
    private var expectedActivations: Set<pid_t> = []
    private var lastDispatchAt: Date?
    private var lastUserPID: pid_t?
    private var pendingIncident: String?
    private var observer: NSObjectProtocol?

    /// Pure attribution rule, extracted so it is testable headless (no AX, no
    /// NSWorkspace). Returns true when the activation should be treated as
    /// stolen focus (restore + warn).
    ///
    /// While the guard is on the dispatcher refuses every server-side
    /// activation path, so `expected` is defense-in-depth for future code paths
    /// and mid-run guard toggles, not the common case.
    public static func isStolenFocus(
        activatedPID: pid_t,
        drivenPIDs: Set<pid_t>,
        expected: Bool,
        guardEnabled: Bool,
        secondsSinceLastDispatch: TimeInterval?
    ) -> Bool {
        guard guardEnabled else { return false }
        guard drivenPIDs.contains(activatedPID) else { return false }
        guard !expected else { return false }
        guard let elapsed = secondsSinceLastDispatch else { return false }
        return elapsed >= 0 && elapsed <= attributionWindow
    }

    /// The in-band warning attached to the next tool result after a restore.
    /// Written to re-steer the agent (name the bypass, name the fix), not just
    /// to report.
    public static func incidentMessage(appName: String) -> String {
        "⚠️ Focus Guard: '\(appName)' took the user's focus mid-run through a channel outside this " +
        "server (e.g. osascript 'activate'/'set frontmost'/System Events keystroke via a shell tool, " +
        "or 'open' without -g). The user's previous app was re-activated. Never take focus by any " +
        "means: use the background-safe tools (click/type_text/send_shortcut/screenshot_window are " +
        "PID-targeted; launch_app takes `paths` to open files without the open panel). If a step has " +
        "no background-safe path, stop and ask the user."
    }

    /// Record that a tool call touched this app. Installs the workspace
    /// observer on first use so the watcher costs nothing until the server
    /// actually drives something.
    public func noteDriven(pid: pid_t) {
        lock.lock()
        drivenPIDs.insert(pid)
        lock.unlock()
        startIfNeeded()
    }

    /// Bump the activity clock. Called once per tool dispatch.
    public func noteDispatch() {
        lock.lock()
        lastDispatchAt = Date()
        lock.unlock()
    }

    /// Mark a server-initiated activation (guard off: `activate_app`,
    /// `foreground:true`, launch/open with activation) so it is never
    /// misread as a steal.
    public func expectActivation(pid: pid_t) {
        lock.lock()
        expectedActivations.insert(pid)
        lock.unlock()
    }

    /// The warning for the most recent incident, cleared on read. The tool
    /// dispatcher attaches it to its next result.
    public func consumeIncident() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let incident = pendingIncident
        pendingIncident = nil
        return incident
    }

    private func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard observer == nil else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !drivenPIDs.contains(frontmost.processIdentifier) {
            lastUserPID = frontmost.processIdentifier
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            self?.handleActivation(of: app)
        }
    }

    private func handleActivation(of app: NSRunningApplication) {
        let pid = app.processIdentifier

        lock.lock()
        let expected = expectedActivations.remove(pid) != nil
        let elapsed = lastDispatchAt.map { Date().timeIntervalSince($0) }
        let stolen = Self.isStolenFocus(
            activatedPID: pid,
            drivenPIDs: drivenPIDs,
            expected: expected,
            guardEnabled: FocusGuard.isEnabled,
            secondsSinceLastDispatch: elapsed
        )
        if !stolen, !drivenPIDs.contains(pid) {
            // A non-driven app coming forward is the user (or the system) — that
            // is the app focus gets restored TO after a future steal.
            lastUserPID = pid
        }
        let restoreTo = lastUserPID
        if stolen {
            pendingIncident = Self.incidentMessage(appName: app.localizedName ?? "pid \(pid)")
        }
        lock.unlock()

        if stolen, let restoreTo, restoreTo != pid {
            NSRunningApplication(processIdentifier: restoreTo)?.activate()
        }
    }
}
