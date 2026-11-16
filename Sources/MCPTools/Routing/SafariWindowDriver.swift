import AppKit
import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

/// A failure the agent should read as the answer, not as a broken tool.
struct SafariWindowError: LocalizedError {
    let message: String
    /// The call is refused outright instead of falling back to the usual path.
    var isRefusal = false
    var errorDescription: String? { message }
}

/// What the agent window's web area reports, read through the accessibility window that is it.
struct SafariPage: Equatable, Sendable {
    var use: SafariWindowUse
    var url: String?
    var loaded: Bool
}

/// The Mac, as far as this feature touches it. The live implementation reads accessibility and
/// the window server and sends Apple Events; the tests substitute one that records what was
/// asked, so `swift test` can never create a window in the Safari of the machine running it.
protocol SafariSystem: Sendable {
    func pid(bundleId: String) async -> pid_t?
    func survey(pid: pid_t, entry: SafariAgentWindows.Entry?) async -> SafariSurvey
    func page(pid: pid_t, windowID: Int) async -> SafariPage?
    func openWindow(bundleId: String, url: URL) async throws -> Int
    func navigate(bundleId: String, windowID: Int, to url: URL) async throws
    func closeWindow(bundleId: String, windowID: Int) async
}

/// One Safari window decision at a time. Two calls that arrive together (a snapshot and a
/// screenshot of the same page, sent in one turn) must find the first one's window, not each open one.
final class SafariWindowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

enum SafariWindows {
    private static let gate = SafariWindowGate()

    /// Tests replace it. Never `nonisolated(unsafe)` state shared with a running server.
    nonisolated(unsafe) static var system: SafariSystem = LiveSafariSystem()

    static func isSafariFamily(_ bundleId: String) -> Bool {
        SafariScripts.applicationID(for: bundleId) != nil
    }

    static func displayName(bundleId: String) -> String {
        bundleId == "com.apple.SafariTechnologyPreview" ? "Safari Technology Preview" : "Safari"
    }

    /// How long a fresh window gets to show up in the accessibility window list before it is
    /// called unusable. Safari reports the window before the accessibility layer lists it.
    nonisolated(unsafe) static var appearanceGrace: TimeInterval = 1.5

    // MARK: - Opening

    enum Navigation {
        /// Not a Safari web page, no Safari running, or the front window can take the page: go the usual way.
        case notApplicable
        /// The page is in a normal window of this server's own.
        case handled(BrowserNavigator.Outcome)
        /// A window of its own was wanted and could not be used: go the usual way and say why.
        case fellBack(String)
    }

    /// How long after a fresh window landed off the user's Space the next one is not tried.
    nonisolated(unsafe) static var landingRetryAfter: TimeInterval = 60

    /// `waitForLoad: false` (open_url) returns as soon as the window is confirmed usable. Throws only
    /// to refuse (the user is looking at their full-screen Safari); every other failure falls back.
    static func navigate(_ url: URL, in browser: BrowserTarget, timeout: TimeInterval, waitForLoad: Bool = true)
        async throws -> Navigation {
        guard isSafariFamily(browser.bundleId),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let pid = await system.pid(bundleId: browser.bundleId) else { return .notApplicable }
        await gate.acquire()
        defer { gate.release() }

        let registry = SafariAgentWindows.shared
        var survey = await system.survey(pid: pid, entry: registry.entry(forPID: pid))
        if survey.agent == nil { registry.forget(pid: pid) }
        survey.freshWindowFailedRecently = registry.landingFailed(pid: pid, within: landingRetryAfter)

        let started = Date()
        let windowID: Int
        let because: SafariWindowUse
        let created: Bool
        do {
            switch SafariWindowPolicy.route(survey) {
            case .defaultPath:
                return .notApplicable
            case .holdOff:
                throw SafariWindowError(message: SafariWindowPolicy.holdOffMessage(browser: browser.name), isRefusal: true)
            case .skipFreshWindow:
                return .fellBack(SafariWindowPolicy.fellBackNotice(SafariWindowPolicy.skippedReason(), browser: browser.name))
            case .reuseAgentWindow(let id, let why):
                windowID = id
                because = why
                created = false
                if !BrowserNavigator.sameDocument(survey.agent?.state.pageURL, url) {
                    try await perform(browser) { try await system.navigate(bundleId: browser.bundleId, windowID: id, to: url) }
                }
            case .openFreshWindow(let why):
                because = why
                created = true
                windowID = try await perform(browser) { try await system.openWindow(bundleId: browser.bundleId, url: url) }
                registry.set(.init(id: windowID, because: why), forPID: pid)
            }

            let page = try await settle(pid: pid, windowID: windowID, browser: browser, url: url, started: started,
                                        timeout: waitForLoad ? timeout : 0)
            registry.clearLandingFailure(pid: pid)
            return .handled(BrowserNavigator.Outcome(
                pid: pid, loaded: page.loaded, pageURL: page.url, waitedMs: Int(Date().timeIntervalSince(started) * 1000),
                wasFrontmost: survey.safariIsFrontmost, reused: false,
                agentWindow: .init(id: windowID, created: created, because: because)))
        } catch let failure as SafariWindowError where !failure.isRefusal {
            return .fellBack(SafariWindowPolicy.fellBackNotice(failure.message, browser: browser.name))
        }
    }

    /// Waits until the agent window is listed and usable, then (when asked) until its page has loaded.
    /// A window that never becomes usable is one this server opened and cannot use: it is closed
    /// (the only kind of window this code ever closes), and a new one is not tried for a while.
    private static func settle(pid: pid_t, windowID: Int, browser: BrowserTarget, url: URL, started: Date,
                               timeout: TimeInterval) async throws -> SafariPage {
        let grace = started.addingTimeInterval(appearanceGrace)
        let deadline = started.addingTimeInterval(max(timeout, appearanceGrace))
        var latest: SafariPage?
        while true {
            if let page = await system.page(pid: pid, windowID: windowID) {
                latest = page
                if page.use == .usable {
                    if timeout == 0 || (page.loaded && BrowserNavigator.matches(page.url, url)) { return page }
                } else if Date() >= grace {
                    break
                }
            }
            if Date() >= deadline { break }
            try await AXExecutor.pause(0.1)
        }
        if let latest, latest.use == .usable { return latest }

        await system.closeWindow(bundleId: browser.bundleId, windowID: windowID)
        SafariAgentWindows.shared.forget(pid: pid)
        SafariAgentWindows.shared.noteLandingFailure(pid: pid)
        throw SafariWindowError(message: SafariWindowPolicy.landedElsewhereReason(browser: browser.name))
    }

    /// Apple Events go through here so that every failure reaches the agent in words.
    private static func perform<T>(_ browser: BrowserTarget, _ body: () async throws -> T) async throws -> T {
        FocusWatcher.shared.noteURLHandoff(bundleId: browser.bundleId, selfActivates: false)
        do {
            return try await body()
        } catch let failure as SafariScriptFailure {
            switch failure.failure {
            case .notAllowed: throw SafariWindowError(message: SafariWindowPolicy.notAllowedMessage(browser: browser.name))
            case .timedOut: throw SafariWindowError(message: SafariWindowPolicy.timedOutMessage(browser: browser.name))
            case .windowGone:
                SafariAgentWindows.shared.removeAll()
                throw SafariWindowError(message: "The \(browser.name) window opened for the agent was closed meanwhile. Call again to get a new one.")
            case .other(let text):
                throw SafariWindowError(message: "\(browser.name) could not open the page in a window of its own: \(text)")
            }
        }
    }

    // MARK: - Which window the other tools use

    /// The window a Safari call acts on. Without an agent window this is what every tool always
    /// used (the focused window, else the first). With one, a front window that cannot give pixels
    /// or a resize is stood in for by the agent window, so a call that names only Safari keeps
    /// acting on the page the agent opened.
    static func targetWindow(of app: AXElement, pid: pid_t) -> AXElement? {
        agentStandIn(of: app, pid: pid) ?? app.focusedWindow ?? app.windows.first
    }

    /// The agent window, when it has to stand in for the front window: nil for every app that has
    /// no agent window (no read at all) and whenever the front window is usable.
    static func agentStandIn(of app: AXElement, pid: pid_t) -> AXElement? {
        guard let entry = SafariAgentWindows.shared.entry(forPID: pid) else { return nil }
        let windows = app.windows
        if let front = app.focusedWindow ?? windows.first, LiveSafariSystem.facts(of: front, in: windows).use == .usable {
            return nil
        }
        return LiveSafariSystem.agentWindow(pid: pid, id: entry.id, in: windows)
    }

    /// Why a capture of the window a Safari call would use must not be tried; nil when it may. Only
    /// Safari windows are judged.
    static func captureBlocker(pid: pid_t) async -> String? {
        guard let bundleId = await bundleId(of: pid), isSafariFamily(bundleId) else { return nil }
        let why: SafariWindowUse? = await AXExecutor.app(pid).run {
            let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
            let windows = app.windows
            guard let target = targetWindow(of: app, pid: pid) else { return nil }
            return LiveSafariSystem.facts(of: target, in: windows).captureBlock
        }
        guard let why else { return nil }
        return SafariWindowPolicy.blockedMessage(browser: displayName(bundleId: bundleId), because: why)
    }

    enum BoundsTarget: Equatable, Sendable {
        case passthrough
        case index(Int)
        case blocked(String)
    }

    /// The `windowIndex` a resize should use, or the reason it must not happen. A full-screen window
    /// cannot be resized and one on another Space is not in the accessibility window list at all,
    /// where the old code returned a bare "could not be completed".
    static func boundsTarget(pid: pid_t, requestedIndex: Int?) async -> BoundsTarget {
        guard let bundleId = await bundleId(of: pid), isSafariFamily(bundleId) else { return .passthrough }
        let name = displayName(bundleId: bundleId)
        return await AXExecutor.app(pid).run {
            let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
            let windows = app.windows
            if let requestedIndex {
                guard windows.indices.contains(requestedIndex) else { return .passthrough }
                let use = LiveSafariSystem.facts(of: windows[requestedIndex], in: windows).use
                return use == .usable ? .index(requestedIndex)
                    : .blocked(SafariWindowPolicy.blockedMessage(browser: name, because: use))
            }
            guard let target = targetWindow(of: app, pid: pid) else { return .passthrough }
            let use = LiveSafariSystem.facts(of: target, in: windows).use
            guard use == .usable, let index = windows.firstIndex(where: { CFEqual($0.ref, target.ref) }) else {
                return .blocked(SafariWindowPolicy.blockedMessage(browser: name, because: use == .usable ? .otherSpace : use))
            }
            return .index(index)
        }
    }

    /// The words for a capture that failed: for Safari, the cause an agent can act on instead of the
    /// generic "no capturable content".
    static func captureFailureMessage(_ error: Error, pid: pid_t) async -> String {
        if case CaptureError.surfaceUnavailable = error, let bundleId = await bundleId(of: pid), isSafariFamily(bundleId) {
            return SafariWindowPolicy.blockedMessage(browser: displayName(bundleId: bundleId), because: .otherSpace)
        }
        return error.localizedDescription
    }

    private static func bundleId(of pid: pid_t) async -> String? {
        await MainActor.run { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    }
}

struct SafariScriptFailure: Error {
    let failure: SafariScripts.Failure
}

struct LiveSafariSystem: SafariSystem {
    /// `swift test` must never send an Apple Event to the Safari of the Mac it runs on. XCTest being
    /// loaded is the signal: `swift test` does not set XCTestConfigurationFilePath (measured).
    static var underTest: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func pid(bundleId: String) async -> pid_t? {
        // Under test there is no Safari: whether a test routes to a new window must not depend on
        // which Space the developer's own Safari is on.
        guard !Self.underTest else { return nil }
        return await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { !$0.isTerminated }?.processIdentifier
        }
    }

    func survey(pid: pid_t, entry: SafariAgentWindows.Entry?) async -> SafariSurvey {
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        return await AXExecutor.app(pid).run {
            let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
            let windows = app.windows
            let front = app.focusedWindow ?? windows.first
            func state(_ window: AXElement) -> SafariWindowState {
                SafariWindowState(facts: Self.facts(of: window, in: windows), pageURL: BrowserNavigator.webAreaState(in: window)?.url)
            }
            var agent: SafariSurvey.AgentWindow?
            if let entry {
                if let window = Self.agentWindow(pid: pid, id: entry.id, in: windows) {
                    agent = .init(id: entry.id, state: state(window),
                                  isFront: front.map { CFEqual($0.ref, window.ref) } ?? false, because: entry.because)
                } else if Self.windowServerFrame(pid: pid, id: entry.id) != nil {
                    // Alive but not listed: the user moved it to another Space.
                    let facts = SafariWindowFacts(isFullScreen: false, isMinimized: false, inActiveSpace: false)
                    agent = .init(id: entry.id, state: .init(facts: facts, pageURL: nil), isFront: false, because: entry.because)
                }
            }
            var frontState = front.map(state)
            // Windows the accessibility layer cannot list or focus (Safari never was key, or every
            // window is on another Space) still take a LaunchServices tab, unseen.
            if frontState == nil, Self.windowServerHasWindows(pid: pid) {
                frontState = SafariWindowState(
                    facts: .init(isFullScreen: false, isMinimized: false, inActiveSpace: false), pageURL: nil)
            }
            return SafariSurvey(front: frontState, agent: agent, safariIsFrontmost: frontmost)
        }
    }

    func page(pid: pid_t, windowID: Int) async -> SafariPage? {
        await AXExecutor.app(pid).run {
            let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
            let windows = app.windows
            guard let window = Self.agentWindow(pid: pid, id: windowID, in: windows) else {
                return Self.windowServerFrame(pid: pid, id: windowID) == nil ? nil
                    : SafariPage(use: .otherSpace, url: nil, loaded: false)
            }
            let area = BrowserNavigator.webAreaState(in: window)
            return SafariPage(use: Self.facts(of: window, in: windows).use, url: area?.url, loaded: area?.loaded ?? false)
        }
    }

    func openWindow(bundleId: String, url: URL) async throws -> Int {
        let output = try await Self.osascript(bundleId: bundleId, source: SafariScripts.open, arguments: [url.absoluteString])
        guard let id = SafariScripts.parseWindowID(output) else {
            throw SafariScriptFailure(failure: .other("no window id came back (\(output))"))
        }
        return id
    }

    func navigate(bundleId: String, windowID: Int, to url: URL) async throws {
        _ = try await Self.osascript(bundleId: bundleId, source: SafariScripts.navigate,
                                     arguments: [url.absoluteString, String(windowID)])
    }

    func closeWindow(bundleId: String, windowID: Int) async {
        _ = try? await Self.osascript(bundleId: bundleId, source: SafariScripts.close, arguments: [String(windowID)])
    }

    private static func osascript(bundleId: String, source: (String) -> String, arguments: [String]) async throws -> String {
        guard !underTest else { throw SafariScriptFailure(failure: .other("Apple Events are off under test")) }
        guard let application = SafariScripts.applicationID(for: bundleId) else {
            throw SafariScriptFailure(failure: .other("not a Safari bundle: \(bundleId)"))
        }
        do {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/osascript", arguments: ["-e", source(application), "--"] + arguments, timeout: 12)
            guard result.status == 0 else { throw SafariScriptFailure(failure: SafariScripts.classify(stderr: result.stderrString)) }
            return result.stdoutString
        } catch is ProcessRunner.Failure {
            throw SafariScriptFailure(failure: .timedOut)
        }
    }

    // MARK: - Reading windows

    static func facts(of window: AXElement, in windows: [AXElement]) -> SafariWindowFacts {
        let attributes = window.readAttributes(["AXFullScreen", kAXMinimizedAttribute as String])
        return SafariWindowFacts(
            isFullScreen: (attributes["AXFullScreen"] as? Bool) ?? false,
            isMinimized: (attributes[kAXMinimizedAttribute as String] as? Bool) ?? false,
            inActiveSpace: windows.contains { CFEqual($0.ref, window.ref) })
    }

    /// The accessibility window that is window-server window `id`, among the active Space's windows.
    static func agentWindow(pid: pid_t, id: Int, in windows: [AXElement]) -> AXElement? {
        guard let server = windowServerFrame(pid: pid, id: id) else { return nil }
        let candidates = windows.map { SafariWindowMatch.Candidate(frame: $0.frame ?? .zero, title: $0.title) }
        return SafariWindowMatch.pick(frame: server.frame, title: server.title, among: candidates).map { windows[$0] }
    }

    /// Any real window of this process, whichever Space it is on. Helper surfaces (toolbar shadows,
    /// 16 to 48 points tall) are not windows a page could land in.
    static func windowServerHasWindows(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.width >= 100 && frame.height >= 100
        }
    }

    /// Where the window server has window `id` of this process, whichever Space it is on.
    static func windowServerFrame(pid: pid_t, id: Int) -> (frame: CGRect, title: String?)? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowNumber as String] as? Int) == id && (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (frame, info[kCGWindowName as String] as? String)
        }
        return nil
    }
}
