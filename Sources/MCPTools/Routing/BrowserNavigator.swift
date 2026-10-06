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
    }

    /// `activates = false` is the whole point: the URL lands in a tab of the browser's
    /// window while the user keeps their frontmost app. Same mechanism `open -g -a` uses.
    @MainActor
    static func open(_ url: URL, in browser: BrowserTarget) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
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
