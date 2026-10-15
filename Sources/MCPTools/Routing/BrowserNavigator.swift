import AppKit
import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

/// Opens a URL in the user's real browser WITHOUT activating it, then waits until the page
/// is actually loaded so the next snapshot sees the new page instead of the old one.
enum BrowserNavigator {
    struct Outcome: Sendable {
        var pid: pid_t
        var loaded: Bool
        /// The page URL the browser reports, when it exposes one (WebKit does).
        var pageURL: String?
        var waitedMs: Int
        /// The browser was the user's frontmost app when the page was opened, so the new
        /// tab landed in their view.
        var wasFrontmost: Bool
        /// The page was already the front tab of the browser's focused window, so nothing
        /// was opened.
        var reused = false
    }

    /// Pages handed to a browser through LaunchServices, for tests: a page for a Chrome with a
    /// debug port must never get here.
    @MainActor private(set) static var launchServicesOpens = 0

    /// Tests set it: a page must never reach the real browsers of the Mac running them.
    @MainActor static var refuseLaunchServices = false

    /// `activates = false` is the whole point: the URL lands in a tab of the browser's
    /// window while the user keeps their frontmost app. Same mechanism `open -g -a` uses.
    /// Safari honours it; Chrome does not, and comes to the front on every hand-off, which
    /// Focus Guard is told about so it can undo it and say who did it.
    @MainActor
    static func open(_ url: URL, in browser: BrowserTarget, activates: Bool = false) async throws -> NSRunningApplication {
        launchServicesOpens += 1
        if refuseLaunchServices {
            throw ToolError.actionFailed("LaunchServices is off in tests: \(url.absoluteString) was not handed to \(browser.name)")
        }
        if !activates { FocusWatcher.shared.noteURLHandoff(bundleId: browser.bundleId) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        config.addsToRecentItems = false
        do {
            return try await NSWorkspace.shared.open([url], withApplicationAt: browser.appURL, configuration: config)
        } catch {
            throw ToolError.actionFailed("\(browser.name) could not open \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    /// Open and wait for load. Bounded by `timeout`; returns `loaded:false` rather than
    /// throwing when the deadline passes, so the caller still gets a snapshot of whatever
    /// rendered (a slow page is not an error, and saying so is better than hanging).
    static func navigate(_ url: URL, in browser: BrowserTarget, timeout: TimeInterval = 10) async throws -> Outcome {
        let wasFrontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.bundleId
        }
        if let showing = await alreadyShowing(url, in: browser, wasFrontmost: wasFrontmost) { return showing }
        let app = try await open(url, in: browser)
        let pid = app.processIdentifier
        // Deliberately NOT FocusWatcher.noteDriven: opening a page in the background is not
        // driving the browser, and marking the user's everyday browser as driven would make
        // FocusWatcher yank them out of it the next time they switch to it within the window.
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)

        // Let the navigation start before the first poll, or the old page reports
        // loaded=1 and we return instantly with stale content.
        try await AXExecutor.pause(0.15)

        var lastURL: String?
        var sawWebArea = false
        while Date() < deadline {
            let state = await AXExecutor.app(pid).run { webAreaState(pid: pid) }
            if let state {
                sawWebArea = true
                lastURL = state.url
                if state.loaded && matches(state.url, url) {
                    return Outcome(pid: pid, loaded: true, pageURL: state.url, waitedMs: ms(since: started), wasFrontmost: wasFrontmost)
                }
            } else if !sawWebArea && Date().timeIntervalSince(started) > 1.5 {
                // Browser exposes no web area to AX (Firefox without its a11y engine
                // warmed up, or a non-WebKit page). Nothing to wait on, so don't burn
                // the whole deadline pretending.
                break
            }
            try await AXExecutor.pause(0.1)
        }
        return Outcome(pid: pid, loaded: false, pageURL: lastURL, waitedMs: ms(since: started), wasFrontmost: wasFrontmost)
    }

    /// The page is already the front tab of the browser's focused window: drive it as it is.
    /// Every navigating call used to hand the URL over again, one more tab in the user's own
    /// window per call (`snapshot` then `read_all_text` on one page left two).
    private static func alreadyShowing(_ url: URL, in browser: BrowserTarget, wasFrontmost: Bool) async -> Outcome? {
        let pid = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleId).first?.processIdentifier
        }
        guard let pid,
              let state = await AXExecutor.app(pid).run({ webAreaState(pid: pid) }),
              state.loaded, sameDocument(state.url, url) else { return nil }
        return Outcome(pid: pid, loaded: true, pageURL: state.url, waitedMs: 0, wasFrontmost: wasFrontmost, reused: true)
    }

    /// The same document: scheme, host and query equal, the path equal but for a trailing slash,
    /// the fragment ignored. Stricter than `matches`, which accepts any page under the path:
    /// taking a tab on another page for the requested one would drive the user's page as ours.
    static func sameDocument(_ reported: String?, _ requested: URL) -> Bool {
        guard let reported, let got = URLComponents(string: reported),
              let want = URLComponents(url: requested, resolvingAgainstBaseURL: false) else { return false }
        func path(_ c: URLComponents) -> String {
            let p = c.percentEncodedPath
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : (p.isEmpty ? "/" : p)
        }
        return got.scheme?.lowercased() == want.scheme?.lowercased()
            && got.host?.lowercased() == want.host?.lowercased()
            && got.port == want.port
            && path(got) == path(want)
            && (got.percentEncodedQuery ?? "") == (want.percentEncodedQuery ?? "")
    }

    /// The focused window's web area: (AXURL, AXLoaded). Read through the focused window,
    /// not AXWindows — a fullscreen or other-Space Safari window is missing from
    /// AXWindows but still reachable as AXFocusedWindow.
    private static func webAreaState(pid: pid_t) -> (url: String?, loaded: Bool)? {
        let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
        guard let window = app.focusedWindow ?? app.windows.first else { return nil }
        guard let area = findWebArea(in: window) else { return nil }
        let attrs = area.readAttributes(["AXURL", "AXLoaded"])
        var urlString: String?
        if let raw = attrs["AXURL"] {
            if CFGetTypeID(raw) == CFURLGetTypeID() {
                urlString = (raw as! URL).absoluteString
            } else if let s = raw as? String {
                urlString = s
            }
        }
        let loaded = (attrs["AXLoaded"] as? Bool) ?? ((attrs["AXLoaded"] as? NSNumber)?.boolValue ?? false)
        return (urlString, loaded)
    }

    /// BFS for the first AXWebArea. Browser chrome is shallow (window → split group →
    /// tab group → scroll area → web area), so a small depth and node budget suffice and
    /// keep this cheap enough to poll at 10 Hz.
    private static func findWebArea(in root: AXElement) -> AXElement? {
        var queue: [(AXElement, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count && head < 400 {
            let (el, depth) = queue[head]
            head += 1
            if el.role == "AXWebArea" { return el }
            if depth < 8 {
                for child in el.children { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    /// Same page, tolerant of the redirects every site does: trailing slash, http→https,
    /// www. prefix, added query. Host + path prefix is the signal that the navigation we
    /// asked for is the one that finished.
    static func matches(_ reported: String?, _ requested: URL) -> Bool {
        guard let reported, let got = URL(string: reported) else { return false }
        if requested.scheme == "file" || requested.scheme == "about" || requested.scheme == "data" {
            return reported.hasPrefix(requested.absoluteString.prefix(20))
        }
        func host(_ u: URL) -> String {
            let h = (u.host ?? "").lowercased()
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        guard host(got) == host(requested) else { return false }
        let wantPath = requested.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let gotPath = got.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return wantPath.isEmpty || gotPath.hasPrefix(wantPath)
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
