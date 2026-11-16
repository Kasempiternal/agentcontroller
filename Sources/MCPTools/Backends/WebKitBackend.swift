import AppKit
import CryptoKit
import Foundation
import MCPServer
import ObjectiveC
import WebKit

/// A real WebKit page rendered off screen inside this app: no Safari window, no Space, no focus.
///
/// Why it exists: a Safari window that is full screen or on another Space has no capturable surface,
/// and a window opened for the agent lands on Safari's own Space (measured). A WKWebView in an
/// invisible window far outside every display is rendered whatever the user is looking at.
///
/// Measured on macOS 27.2, and what the design rests on:
/// - `document.hidden` is true for every placement unless the window is ordered in AND
///   `-[WKWebView _setWindowOcclusionDetectionEnabled:NO]` is set; then the page runs at full rate
///   (10 timer ticks/s, 60 rAF/s, polling fetches at full rate), also while the user sits in another
///   app's full-screen Space. `inactiveSchedulingPolicy` alone changed nothing.
/// - `prefers-color-scheme` follows `webView.appearance`; the device scale factor needs
///   `-[WKWebView _setOverrideDeviceScaleFactor:]`.
/// - A mouse or key `NSEvent` handed to the view is trusted (`isTrusted`) with no key window and no
///   active app.
/// Both selectors are private: each call is guarded by `responds(to:)` and a missing one is reported
/// in the result instead of failing.
@MainActor
final class WebKitBackend {
    static let shared = WebKitBackend()
    private static var storeCreated = false

    nonisolated static let defaultViewport = CGSize(width: 1440, height: 900)
    nonisolated static let defaultScale: CGFloat = 2
    nonisolated static let maxPages = 6
    nonisolated static let loadTimeout: TimeInterval = 30
    nonisolated static let scriptTimeout: TimeInterval = 20
    nonisolated static let maxViewportSide: CGFloat = 8000

    /// Minutes without a call after which a page is closed: a page forced visible renders at full
    /// rate for as long as it exists.
    nonisolated(unsafe) static var idleLimit: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["AGENTCONTROLLER_WEBKIT_IDLE_MINUTES"], let minutes = Double(raw), minutes > 0 {
            return minutes * 60
        }
        return 600
    }()

    enum ColorScheme: String, Sendable {
        case light, dark, system
    }

    struct Options: Sendable, Equatable {
        var width: CGFloat?
        var height: CGFloat?
        var colorScheme: ColorScheme?
        var scale: CGFloat?
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
        static func noPage(_ key: String) -> Failure {
            Failure(message: "No WebKit page '\(key)' is open (never opened, or closed after \(Int(WebKitBackend.idleLimit / 60)) minutes without a call). Call open_url with browser:\"webkit\" and a url first.")
        }
        static let stale = Failure(message: "Stale element id: that node is gone from the page (it navigated or re-rendered). Call snapshot again for fresh ids.")
    }

    private var pages: [String: WebKitPage] = [:]
    private var stores: [String: WKWebsiteDataStore] = [:]
    private var reaper: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Pages

    func page(key: String) -> WebKitPage? { pages[key] }

    var openPageKeys: [String] { pages.keys.sorted() }

    /// The page for `key`, created (with the profile's own persistent store) when missing.
    func page(profile: String, name: String, options: Options) -> WebKitPage {
        let key = Self.key(profile: profile, name: name)
        if let existing = pages[key] {
            existing.touch()
            existing.reassertVisibility()
            return existing
        }
        evictIfNeeded()
        let store = dataStore(profile: profile)
        let page = WebKitPage(key: key, store: store, options: options)
        pages[key] = page
        startReaper()
        holdActivity()
        return page
    }

    /// While a page exists the app must not be App Napped or have its timers coalesced, and the page
    /// must stay "visible" when the user changes Space or display: a long-lived soak page (measured)
    /// dropped from 10 timer ticks/s to 1 about 20 minutes in, while the user moved between Spaces.
    private func holdActivity() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "WebKit pages keep polling")
        }
        guard observers.isEmpty else { return }
        let reassert: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertAll() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: reassert))
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reassert))
    }

    private func releaseActivity() {
        guard pages.isEmpty else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
    }

    private func reassertAll() {
        for page in pages.values { page.reassertVisibility() }
    }

    nonisolated static func key(profile: String, name: String) -> String { "\(profile)/\(name)" }

    /// A persistent store per profile: a login made on a local page survives between calls and restarts.
    func dataStore(profile: String) -> WKWebsiteDataStore {
        if let store = stores[profile] { return store }
        let store = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(profile: profile))
        Self.storeCreated = true
        stores[profile] = store
        return store
    }

    /// Hashed, not truncated: two long profile names must not share a store.
    nonisolated static func storeIdentifier(profile: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("agentcontroller.webkit.profile.\(profile)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func close(key: String) {
        pages.removeValue(forKey: key)?.shutDown()
        releaseActivity()
    }

    func closeAll() {
        for key in Array(pages.keys) { close(key: key) }
        reaper?.cancel()
        reaper = nil
    }

    /// Forgets a profile's cookies and storage (tests, and a reset the agent can ask for).
    func removeProfile(_ profile: String) async {
        for key in pages.keys where key.hasPrefix("\(profile)/") { close(key: key) }
        stores.removeValue(forKey: profile)
        let identifier = Self.storeIdentifier(profile: profile)
        // remove(forIdentifier:) dereferences a lock WebKit only sets up once a store exists in the process (measured: SIGSEGV on a fresh process).
        if !Self.storeCreated { autoreleasepool { _ = WKWebsiteDataStore(forIdentifier: identifier) }; Self.storeCreated = true }
        // The web view and the network process let go of the store a moment after the view is closed.
        for _ in 0..<30 {
            do { try await WKWebsiteDataStore.remove(forIdentifier: identifier); return } catch {
                guard error.localizedDescription.contains("in use") else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func evictIfNeeded() {
        guard pages.count >= Self.maxPages else { return }
        if let oldest = pages.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key { close(key: oldest) }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.closeIdlePages()
            }
        }
    }

    func closeIdlePages(now: Date = Date()) {
        for (key, page) in pages where now.timeIntervalSince(page.lastUsed) > Self.idleLimit { close(key: key) }
    }
}

// MARK: - What may be loaded

/// Which URLs this view may load, and on whose say-so. An app-initiated load (`WKWebView.load`,
/// `loadFileURL`) skips the checks WebKit applies to a page's own navigation, so a URL that came from
/// page content must never reach one: page-initiated navigation, popups and redirects are limited to
/// web pages, and only the tool caller can start anything else, behind an explicit option.
enum WebKitURLPolicy {
    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isBlank(_ url: URL) -> Bool { url.absoluteString.lowercased() == "about:blank" }

    /// A page may send its main frame to a web page, or to about:blank, and nowhere else.
    static func pageMayNavigate(to url: URL) -> Bool { isWeb(url) || isBlank(url) }

    /// A popup (`window.open`, target=_blank) is shown in this view, so it gets the same limit and
    /// no about:blank: an empty popup would only blank the page the agent is reading.
    static func popupMayOpen(_ url: URL) -> Bool { isWeb(url) }

    /// Why a tool caller may not start this load, or nil.
    static func refusal(forAgentLoad url: URL, allowFile: Bool) -> String? {
        if isWeb(url) || isBlank(url) { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        if allowFile, scheme == "file" || scheme == "data" { return nil }
        if scheme == "file" || scheme == "data" {
            return "A \(scheme): URL is refused on a WebKit target unless the call passes allowFile:true (a file: page can read the files next to it). http(s) and about:blank always load."
        }
        return "WebKit targets load http(s) URLs and about:blank (and file:/data: with allowFile:true), not \(scheme.isEmpty ? "that" : scheme + ":")."
    }

    /// Subframes: web, data, blob and srcdoc content is ordinary page content; `file:` only inside a
    /// file page the agent opened; any other scheme is refused.
    static func frameMayLoad(_ url: URL, topIsFile: Bool) -> Bool {
        if isWeb(url) || isBlank(url) { return true }
        switch url.scheme?.lowercased() {
        case "data", "blob": return true
        case "about": return url.absoluteString.lowercased() == "about:srcdoc"
        case "file": return topIsFile
        default: return false
        }
    }

    static func withoutFragment(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }
}

// MARK: - One page

@MainActor
final class WebKitPage: NSObject {
    let key: String
    let window: NSWindow
    let web: WKWebView

    private(set) var lastUsed = Date()
    /// Bumped on every committed navigation: element ids carry it, so an id from the old document is refused.
    private(set) var epoch = 0
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var statusCode: Int?
    private(set) var crashed = false
    private(set) var dialogs: [String] = []
    /// Navigations, popups and downloads the page asked for and this view refused, for the next result.
    private(set) var blocked: [String] = []
    /// The one URL the tool caller started, which is the only non-web URL a main frame may sit on.
    private var agentStartedURL: String?
    private(set) var occlusionSPI = false
    private(set) var scaleSPI = false
    private(set) var viewport = WebKitBackend.defaultViewport
    private(set) var scale = WebKitBackend.defaultScale
    private(set) var colorScheme: WebKitBackend.ColorScheme = .light

    private var pendingLoad: CheckedContinuation<Void, Never>?
    private var nextEventNumber = 1
    private let world = WKContentWorld.world(name: "agentcontroller.webkit")

    init(key: String, store: WKWebsiteDataStore, options: WebKitBackend.Options) {
        self.key = key
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        web = WKWebView(frame: NSRect(origin: .zero, size: WebKitBackend.defaultViewport), configuration: configuration)
        window = WebKitOffscreenWindow(contentRect: NSRect(origin: WebKitOffscreenWindow.origin, size: WebKitBackend.defaultViewport))
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        // Safari's Web Inspector would be a second way into the page's JavaScript; only on request.
        web.isInspectable = ProcessInfo.processInfo.environment["AGENTCONTROLLER_WEBKIT_INSPECTABLE"] == "1"
        window.contentView = web

        occlusionSPI = WebKitSPI.disableOcclusionDetection(web)
        if !occlusionSPI {
            let script = WKUserScript(source: WebKitScripts.forceVisible, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(script)
        }
        // The window is ordered in (never made key, never activated): WebKit only treats a view as
        // visible once its window is.
        window.orderBack(nil)
        applyAppearance(.light)
        scaleSPI = WebKitSPI.overrideScaleFactor(web, WebKitBackend.defaultScale)
        _ = apply(options)
    }

    func touch() { lastUsed = Date() }

    /// WebKit re-evaluates a view's visibility when its window moves between Spaces or displays;
    /// say again that the window is in and that occlusion does not count.
    func reassertVisibility() {
        if occlusionSPI { _ = WebKitSPI.disableOcclusionDetection(web) }
        if !window.isVisible { window.orderBack(nil) }
    }

    func shutDown() {
        pendingLoad?.resume()
        pendingLoad = nil
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    var currentURL: String? { web.url?.absoluteString }

    // MARK: Viewport, appearance, scale

    /// Applies what the caller asked for and says whether the layout changed. The options persist
    /// on the page until changed again.
    @discardableResult
    func apply(_ options: WebKitBackend.Options) -> Bool {
        var changed = false
        if options.width != nil || options.height != nil {
            let size = CGSize(
                width: min(max(options.width ?? viewport.width, 1), WebKitBackend.maxViewportSide),
                height: min(max(options.height ?? viewport.height, 1), WebKitBackend.maxViewportSide))
            if size != viewport { setViewport(size); changed = true }
        }
        if let scheme = options.colorScheme, scheme != colorScheme { applyAppearance(scheme); changed = true }
        if let factor = options.scale, factor > 0, factor != scale {
            scale = factor
            scaleSPI = WebKitSPI.overrideScaleFactor(web, factor) || scaleSPI
            changed = true
        }
        return changed
    }

    private func setViewport(_ size: CGSize) {
        viewport = size
        window.setContentSize(size)
        web.frame = NSRect(origin: .zero, size: size)
    }

    private func applyAppearance(_ scheme: WebKitBackend.ColorScheme) {
        colorScheme = scheme
        let appearance: NSAppearance? = switch scheme {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
        web.appearance = appearance
        window.appearance = appearance
    }

    /// Lets a resize or an appearance change reach layout, and the page's resize/media listeners run.
    func settle(_ seconds: TimeInterval = 0.2) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Loading

    struct LoadOutcome: Sendable {
        var loaded: Bool
        var error: String?
        var timedOut: Bool
    }

    /// Navigates and waits for the load. A failed load is an error, never a blank page.
    func load(_ url: URL, allowFile: Bool = false, timeout: TimeInterval = WebKitBackend.loadTimeout) async -> LoadOutcome {
        touch()
        if let refusal = WebKitURLPolicy.refusal(forAgentLoad: url, allowFile: allowFile) {
            return LoadOutcome(loaded: false, error: refusal, timedOut: false)
        }
        loaded = false
        loadError = nil
        statusCode = nil
        crashed = false
        pendingLoad?.resume()
        pendingLoad = nil
        if url.isFileURL {
            // Read access ends at the file's own folder: never an ancestor, never the home folder.
            let file = url.standardizedFileURL
            agentStartedURL = WebKitURLPolicy.withoutFragment(file)
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else {
            agentStartedURL = WebKitURLPolicy.withoutFragment(url)
            web.load(URLRequest(url: url))
        }
        return await waitForLoad(timeout: timeout)
    }

    func reload(timeout: TimeInterval = WebKitBackend.loadTimeout) async -> LoadOutcome {
        loaded = false
        loadError = nil
        statusCode = nil
        pendingLoad?.resume()
        pendingLoad = nil
        web.reload()
        return await waitForLoad(timeout: timeout)
    }

    private func waitForLoad(timeout: TimeInterval) async -> LoadOutcome {
        if !loaded && loadError == nil && !crashed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingLoad = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                    self?.resumePendingLoad()
                }
            }
        }
        let timedOut = !loaded && loadError == nil && !crashed
        return LoadOutcome(loaded: loaded, error: crashed ? "The page's web process crashed." : loadError, timedOut: timedOut)
    }

    fileprivate func resumePendingLoad() {
        let continuation = pendingLoad
        pendingLoad = nil
        continuation?.resume()
    }

    /// `true` when the requested page is the one on show and loaded.
    func isShowing(_ url: URL) -> Bool {
        loaded && CDPNavigation.isCurrent(currentURL, requested: url)
    }

    // MARK: Scripts

    /// Runs a script body (an async function body) and returns the JSON object it answers with.
    func script(_ body: String, arguments: [String: Any] = [:], inPageWorld: Bool = false,
                timeout: TimeInterval = WebKitBackend.scriptTimeout) async throws -> JSONValue {
        touch()
        let text: String? = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor [self] in
                let result = try await self.web.callAsyncJavaScript(
                    body, arguments: arguments, in: nil, contentWorld: inPageWorld ? .page : self.world)
                return result as? String
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebKitBackend.Failure(message: "The page did not answer within \(Int(timeout))s (a script that never returns, or the page's web process is stuck).")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
        return JSONValue(any: object)
    }

    /// What the page itself reports: also the proof that it is not being throttled.
    func state() async -> JSONValue {
        (try? await script(WebKitScripts.pageState, inPageWorld: true, timeout: 5)) ?? .null
    }

    // MARK: Pixels

    /// The view as an image at the page's device scale. Refuses when nothing loaded.
    func image(rect: CGRect? = nil) async throws -> CGImage {
        touch()
        try requireUsable()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect ?? CGRect(origin: .zero, size: viewport)
        let snapshot: NSImage = try await withThrowingTaskGroup(of: NSImage.self) { group in
            group.addTask { @MainActor [self] in try await self.web.takeSnapshot(configuration: configuration) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(WebKitBackend.scriptTimeout * 1_000_000_000))
                throw WebKitBackend.Failure(message: "WebKit did not return a snapshot within \(Int(WebKitBackend.scriptTimeout))s.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw WebKitBackend.Failure(message: "No snapshot was taken.") }
            return first
        }
        if let bitmap = snapshot.representations.compactMap({ $0 as? NSBitmapImageRep }).first, let image = bitmap.cgImage {
            return image
        }
        var proposed = CGRect(origin: .zero, size: snapshot.size)
        guard let image = snapshot.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw WebKitBackend.Failure(message: "The WebKit snapshot could not be converted to an image.")
        }
        return image
    }

    func requireUsable() throws {
        if crashed { throw WebKitBackend.Failure(message: "The page's web process crashed. Call open_url again.") }
        if let loadError { throw WebKitBackend.Failure(message: "The page did not load: \(loadError). Nothing to show.") }
        if web.url == nil { throw WebKitBackend.Failure(message: "No page is loaded in this WebKit view. Call open_url with a url first.") }
    }

    // MARK: Input (real NSEvents: trusted, no focus, no cursor)

    func click(at point: CGPoint, count: Int) {
        touch()
        send(.mouseMoved, at: point, clickCount: 0)
        for press in 1...max(count, 1) {
            send(.leftMouseDown, at: point, clickCount: press)
            send(.leftMouseUp, at: point, clickCount: press)
        }
    }

    private func send(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int) {
        let location = NSPoint(x: point.x, y: viewport.height - point.y)
        nextEventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber, clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0) else { return }
        switch type {
        case .leftMouseDown: web.mouseDown(with: event)
        case .leftMouseUp: web.mouseUp(with: event)
        default: web.mouseMoved(with: event)
        }
    }

    func key(_ key: WebKitKey, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode) else { continue }
            if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
        }
    }

    /// Types like a keyboard: one key event per character, so key handlers, input events and form
    /// submission (a newline is Return) all happen as they would for a person.
    func type(_ text: String) {
        touch()
        if text.isEmpty {
            key(.backspace)
            return
        }
        for character in text {
            switch character {
            case "\n", "\r": key(.returnKey)
            case "\t": key(.tab)
            default: key(WebKitKey(characters: String(character), keyCode: 0))
            }
        }
    }

    func takeDialogs() -> [String] {
        defer { dialogs.removeAll() }
        return dialogs
    }

    func takeBlocked() -> [String] {
        defer { blocked.removeAll() }
        return blocked
    }
}

struct WebKitKey: Sendable {
    let characters: String
    let keyCode: UInt16

    static let returnKey = WebKitKey(characters: "\r", keyCode: 36)
    static let tab = WebKitKey(characters: "\t", keyCode: 48)
    static let escape = WebKitKey(characters: "\u{1b}", keyCode: 53)
    static let backspace = WebKitKey(characters: "\u{7f}", keyCode: 51)
    static let space = WebKitKey(characters: " ", keyCode: 49)

    /// The key a `send_shortcut` name stands for; a single character is itself.
    static func named(_ name: String) -> WebKitKey? {
        switch name.lowercased() {
        case "return", "enter": return .returnKey
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "backspace", "delete": return .backspace
        case "space": return .space
        case "up": return WebKitKey(characters: String(UnicodeScalar(0xF700)!), keyCode: 126)
        case "down": return WebKitKey(characters: String(UnicodeScalar(0xF701)!), keyCode: 125)
        case "left": return WebKitKey(characters: String(UnicodeScalar(0xF702)!), keyCode: 123)
        case "right": return WebKitKey(characters: String(UnicodeScalar(0xF703)!), keyCode: 124)
        default:
            guard name.count == 1 else { return nil }
            return WebKitKey(characters: name, keyCode: 0)
        }
    }
}

// MARK: - The window

/// Invisible and unreachable: transparent, click-through, below the desktop, far outside every
/// display, in no window list a person sees. It is ordered in because WebKit only treats a view
/// as visible once its window is; it never becomes key and never activates the app.
public final class WebKitOffscreenWindow: NSWindow {
    static let origin = CGPoint(x: -30_000, y: -30_000)

    /// Marks the window as an implementation detail: it is ordered in, so AppKit counts it as a
    /// visible window, and the app's reopen handling must not.
    public static let identifierValue = "agentcontroller.webkit.offscreen"

    public static func isOffscreenPage(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == identifierValue
    }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]
        isExcludedFromWindowsMenu = true
        identifier = NSUserInterfaceItemIdentifier(Self.identifierValue)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    /// A borderless window is not pulled back on screen.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Private selectors, guarded

enum WebKitSPI {
    /// Without this a page in any window the user cannot see is `document.hidden` and WebKit
    /// throttles it to about one tick a second.
    static func disableOcclusionDetection(_ web: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard web.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(class_getMethodImplementation(type(of: web), selector), to: Setter.self)(web, selector, false)
        return true
    }

    static func overrideScaleFactor(_ web: WKWebView, _ factor: CGFloat) -> Bool {
        let selector = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        guard web.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(class_getMethodImplementation(type(of: web), selector), to: Setter.self)(web, selector, factor)
        return true
    }
}

// MARK: - Delegates

extension WebKitPage: WKNavigationDelegate, WKUIDelegate {
    /// Every navigation the page starts passes here. The tool caller's own load is the only way onto a
    /// non-web URL; everything else is limited to web pages. Downloads are never started.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if navigationAction.shouldPerformDownload {
            refuse("download", url, mainFrame: mainFrame)
            decisionHandler(.cancel)
            return
        }
        let allowed: Bool
        if mainFrame {
            allowed = WebKitURLPolicy.pageMayNavigate(to: url) || WebKitURLPolicy.withoutFragment(url) == agentStartedURL
        } else {
            allowed = WebKitURLPolicy.frameMayLoad(url, topIsFile: webView.url?.isFileURL == true)
        }
        if !allowed { refuse("navigation", url, mainFrame: mainFrame) }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        if attachment || !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            refuse("download", url, mainFrame: navigationResponse.isForMainFrame)
            decisionHandler(.cancel)
            return
        }
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            statusCode = http.statusCode
        }
        decisionHandler(.allow)
    }

    private func refuse(_ what: String, _ url: URL, mainFrame: Bool) {
        let text = "\(what) refused: \(url.absoluteString.prefix(120))"
        blocked.append(text)
        guard mainFrame, pendingLoad != nil else { return }
        loaded = false
        loadError = text
        resumePendingLoad()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        epoch += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        loadError = nil
        resumePendingLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        let nsError = error as NSError
        // A navigation cancelled by the next one is not a failure of the page.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        loaded = false
        // WebKit's answer to a response it cannot show; nothing is ever saved to disk.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            let text = "download refused: the response is not a page this view can show (\(nsError.localizedDescription))"
            if !blocked.contains(text) { blocked.append(text) }
            loadError = text
            resumePendingLoad()
            return
        }
        loadError = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        resumePendingLoad()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashed = true
        loaded = false
        resumePendingLoad()
    }

    // `target=_blank` and window.open stay in the one view: there is no second window to drive. The
    // URL came from page content and the load below is the app's own, so only a web URL may pass.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if WebKitURLPolicy.popupMayOpen(url) {
            webView.load(URLRequest(url: url))
        } else {
            blocked.append("popup refused: \(url.absoluteString.prefix(120))")
        }
        return nil
    }

    // Nobody is there to approve a camera or microphone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        dialogs.append("camera or microphone request (denied)")
        decisionHandler(.deny)
    }

    // A dialog nobody answers would freeze the page's script for ever: answer it and keep the text.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        dialogs.append("alert: \(message)")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        dialogs.append("confirm (accepted): \(message)")
        completionHandler(true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        dialogs.append("prompt (default used): \(prompt)")
        completionHandler(defaultText)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        dialogs.append("file chooser (cancelled)")
        completionHandler(nil)
    }
}

extension JSONValue {
    /// From what `JSONSerialization` produced.
    init(any value: Any) {
        switch value {
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue(any: $0) })
        case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
        case let string as String: self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 { self = .int(number.intValue) }
            else { self = .double(number.doubleValue) }
        default: self = .null
        }
    }
}
