import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

/// Why a Safari window cannot take the agent's page: a full-screen window or one on another Space
/// cannot be captured (ScreenCaptureKit has no surface for it) or resized, so a page added to it as
/// a tab can be read through accessibility but never seen.
enum SafariWindowUse: String, Equatable, Sendable {
    case usable
    case fullScreen
    case otherSpace

    /// What the user sees, for the notices.
    var phrase: String {
        switch self {
        case .usable: return "usable"
        case .fullScreen: return "full screen"
        case .otherSpace: return "on another Space"
        }
    }
}

/// What the accessibility layer reports about one Safari window.
struct SafariWindowFacts: Equatable, Sendable {
    var isFullScreen: Bool
    var isMinimized: Bool
    /// Listed in the app's `kAXWindows`, which macOS limits to the active Space.
    var inActiveSpace: Bool

    /// A minimized window is not "on another Space": it is in `kAXWindows` and `restore_window`
    /// brings it back, which is the answer the capture error already gives.
    var use: SafariWindowUse {
        if isFullScreen { return .fullScreen }
        if !inActiveSpace && !isMinimized { return .otherSpace }
        return .usable
    }

    /// Why a capture of this window would find nothing, or nil when it would not. Only a window on
    /// the active Space has a surface; a full-screen window the user is looking at has one too, so
    /// it is not refused here (it is for a resize, by `use`).
    var captureBlock: SafariWindowUse? {
        guard !inActiveSpace, !isMinimized else { return nil }
        return isFullScreen ? .fullScreen : .otherSpace
    }
}

struct SafariWindowState: Equatable, Sendable {
    var facts: SafariWindowFacts
    /// The page the window's web area reports.
    var pageURL: String?
}

/// Everything the route decision reads, taken in one pass.
struct SafariSurvey: Equatable, Sendable {
    /// The window a URL handed to Safari would land in: its focused window.
    var front: SafariWindowState?
    /// The window this server opened earlier, when it still exists.
    var agent: AgentWindow?
    /// Safari is the user's frontmost app right now.
    var safariIsFrontmost: Bool

    struct AgentWindow: Equatable, Sendable {
        var id: Int
        var state: SafariWindowState
        /// It is Safari's focused window, so a URL handed to Safari would add a tab to it.
        var isFront: Bool
        /// Why it was opened: the user's window it stood in for.
        var because: SafariWindowUse
    }
}

enum SafariRoute: Equatable, Sendable {
    /// The front window can take a tab: the page goes in through LaunchServices as before.
    case defaultPath
    /// The front window cannot; the window this server opened earlier still can.
    case reuseAgentWindow(id: Int, because: SafariWindowUse)
    /// The front window cannot and there is no agent window: open a normal one.
    case openFreshWindow(because: SafariWindowUse)
    /// The user is looking at their full-screen Safari. A window opened for the agent while
    /// Safari is the active app may pull them to another Space, so none is opened.
    case holdOff
}

/// The one place the decision is made. Pure, so the tests can walk every state.
enum SafariWindowPolicy {
    static func route(_ survey: SafariSurvey) -> SafariRoute {
        guard let front = survey.front else { return .defaultPath }
        // Navigate the agent window's own tab instead of piling a tab per page on it.
        if let agent = survey.agent, agent.isFront, agent.state.facts.use == .usable {
            return .reuseAgentWindow(id: agent.id, because: agent.because)
        }
        let why = front.facts.use
        if why == .usable { return .defaultPath }
        if let agent = survey.agent, agent.state.facts.use == .usable {
            return .reuseAgentWindow(id: agent.id, because: why)
        }
        if survey.safariIsFrontmost, front.facts.isFullScreen, front.facts.inActiveSpace {
            return .holdOff
        }
        return .openFreshWindow(because: why)
    }

    // MARK: - Words the agent reads

    static func freshNotice(page: URL, browser: String, id: Int, because: SafariWindowUse, created: Bool) -> String {
        let lead = created
            ? "Opened \(page.absoluteString) in a NEW normal \(browser) window (id \(id)) in the background"
            : "Showing \(page.absoluteString) in the \(browser) window this server opened earlier (id \(id))"
        return "\(lead), because the user's \(browser) window is \(because.phrase) and cannot be captured or resized. "
            + "Keep using it: snapshot, read_all_text, screenshot_window and set_window_bounds on \(browser) act on this window "
            + "while that one stays \(because.phrase), and later pages reuse it. The user's own window was not touched."
    }

    static func holdOffMessage(browser: String) -> String {
        "The user is looking at their full-screen \(browser) window right now, and a window opened for you could pull them out of "
            + "that Space. Nothing was opened. Retry in a minute, or use another browser (Chrome with a debug port, or headless:true "
            + "for a page that needs no login). Do not ask the user to leave full screen."
    }

    /// For the tools that need pixels or a resize when the window they would use cannot give them.
    static func blockedMessage(browser: String, because: SafariWindowUse) -> String {
        "The \(browser) window is \(because.phrase), so it cannot be captured or resized. Nothing was changed. "
            + "Call open_url {url, browser:\"\(browser)\"} (or pass `url` to this tool): the server opens a fresh normal window in the "
            + "background and every Safari tool then uses it. Do not ask the user to leave full screen or switch Space."
    }

    static func notAllowedMessage(browser: String) -> String {
        "AgentController is not allowed to control \(browser), which it needs to open a window of its own while the user's window is "
            + "full screen or on another Space. Allow it once in System Settings > Privacy & Security > Automation > AgentController "
            + "> \(browser). Nothing was opened. Meanwhile use another browser, or headless:true for a page that needs no login."
    }

    static func timedOutMessage(browser: String) -> String {
        "\(browser) did not answer in time. If macOS is asking whether AgentController may control \(browser), that dialog is waiting "
            + "for the user. Nothing more was opened."
    }
}

/// The window this server opened in a Safari process, per process. `id` is the window server's
/// number for it (Safari's scripting `id` is the same number), which survives title and frame
/// changes. A window the user closed, moved to another Space or made full screen stops being
/// usable and is simply replaced; the old one is never closed or altered.
final class SafariAgentWindows: @unchecked Sendable {
    static let shared = SafariAgentWindows()

    struct Entry: Equatable, Sendable {
        var id: Int
        var because: SafariWindowUse
    }

    private let lock = NSLock()
    private var byPID: [pid_t: Entry] = [:]

    func entry(forPID pid: pid_t) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return byPID[pid]
    }

    func set(_ entry: Entry, forPID pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        byPID[pid] = entry
    }

    func forget(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        byPID.removeValue(forKey: pid)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        byPID.removeAll()
    }
}

/// Picks the accessibility window that is the window-server window with this frame.
/// Two Safari windows opened one after the other differ by a point or two, so the closest frame
/// wins and a title breaks an exact tie.
enum SafariWindowMatch {
    struct Candidate: Equatable, Sendable {
        var frame: CGRect
        var title: String?
    }

    static let tolerance: CGFloat = 1

    static func pick(frame target: CGRect, title: String?, among candidates: [Candidate]) -> Int? {
        func gap(_ c: Candidate) -> CGFloat {
            max(abs(c.frame.minX - target.minX), abs(c.frame.minY - target.minY),
                abs(c.frame.width - target.width), abs(c.frame.height - target.height))
        }
        let close = candidates.enumerated().filter { gap($0.element) <= tolerance }
        guard let best = close.map({ gap($0.element) }).min() else { return nil }
        let nearest = close.filter { gap($0.element) == best }
        if nearest.count > 1, let title, let named = nearest.first(where: { $0.element.title == title }) {
            return named.offset
        }
        return nearest.first?.offset
    }
}

/// The three Apple Events this feature sends, with the page passed as an argument and never
/// spliced into the script text. Only a window id and a fixed application id are fixed in text.
enum SafariScripts {
    enum Failure: Equatable {
        case notAllowed
        case windowGone
        case timedOut
        case other(String)
    }

    /// `bundleId` picks the application constant: nothing the agent sends reaches the script source.
    static func applicationID(for bundleId: String) -> String? {
        switch bundleId {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": return bundleId
        default: return nil
        }
    }

    /// A new normal window with the page. `make new document` is a window, never a tab of the
    /// user's, and it does not activate Safari. The new window is the id not seen before.
    static func open(applicationID: String) -> String {
        """
        on run argv
            set targetURL to item 1 of argv
            tell application id "\(applicationID)"
                set knownIDs to id of every window
                make new document with properties {URL:targetURL}
                set freshIDs to {}
                repeat with w in (every window)
                    set wid to id of w
                    if knownIDs does not contain wid then set end of freshIDs to wid
                end repeat
                if (count of freshIDs) is 0 then error "agentcontroller: no new window appeared"
                return (item 1 of freshIDs) as text
            end tell
        end run
        """
    }

    /// The agent's own window, by id. Fails with -1728 when the window is gone.
    static func navigate(applicationID: String) -> String {
        """
        on run argv
            set targetURL to item 1 of argv
            set wid to (item 2 of argv) as integer
            tell application id "\(applicationID)"
                set URL of current tab of window id wid to targetURL
                return wid as text
            end tell
        end run
        """
    }

    /// Only ever called with the id of a window this server opened and cannot use.
    static func close(applicationID: String) -> String {
        """
        on run argv
            set wid to (item 1 of argv) as integer
            tell application id "\(applicationID)"
                close window id wid
                return wid as text
            end tell
        end run
        """
    }

    static func parseWindowID(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func classify(stderr: String) -> Failure {
        if stderr.contains("-1743") { return .notAllowed }
        if stderr.contains("-1728") || stderr.contains("-1719") { return .windowGone }
        if stderr.contains("-1712") { return .timedOut }
        return .other(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
