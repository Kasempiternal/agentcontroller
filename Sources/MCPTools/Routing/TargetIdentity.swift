import Foundation
import MCPServer

/// What the agent named as the thing to drive. One string, several shapes:
/// bundle ID, app name, PID, URL, or iOS simulator UDID. The router — not the
/// agent — decides which backend that identity deserves.
public struct TargetIdentity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case url
        case iosSimulator
        case processID
        case application
    }

    public let raw: String
    public let kind: Kind
    public let url: URL?
    public let pid: pid_t?
    public let bundleHint: String?
    public let udid: String?
    /// The page a browser identity is meant to be on, when the caller (not the identity
    /// string) knows it. `BrowserRouting` opens a page in the user's own Chrome and rewrites
    /// the call to name only the app; without this the CDP backend has no way to tell which
    /// of the user's tabs is the one that was just opened. Selects a tab, never navigates.
    public private(set) var pageHint: URL?
    /// The agent passed `headless:true`: the page belongs in the private headless Chromium,
    /// whatever Chrome the user has open with a debug port.
    public private(set) var headless = false

    public init(raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.raw = trimmed
        if let parsed = Self.parseURL(trimmed) {
            self.kind = .url
            self.url = parsed
            self.pid = nil
            self.bundleHint = nil
            self.udid = nil
        } else if let udid = Self.parseUDID(trimmed) {
            self.kind = .iosSimulator
            self.url = nil
            self.pid = nil
            self.bundleHint = nil
            self.udid = udid
        } else if let pid = Self.parsePID(trimmed) {
            self.kind = .processID
            self.url = nil
            self.pid = pid
            self.bundleHint = nil
            self.udid = nil
        } else {
            self.kind = .application
            self.url = nil
            self.pid = nil
            self.bundleHint = trimmed
            self.udid = nil
        }
    }

    /// Pull an identity out of a tool-arguments object. `app` is the historical
    /// field; `target`, `url`, and `udid` are accepted so a URL or simulator
    /// does not have to be stuffed into `app`.
    ///
    /// An explicit app ALWAYS beats `url`. `{app: "Safari", url: …}` means "this page, in
    /// Safari": the url is where to navigate, not who to drive. The old order (url first)
    /// turned every such call into a headless-Chromium session, which is how "use
    /// Safari" kept ending up in Chrome.
    public static func from(arguments: JSONValue?) -> TargetIdentity? {
        if let udid = arguments?["udid"]?.stringValue, parseUDID(udid) != nil {
            return TargetIdentity(raw: udid)
        }
        for key in ["app", "target", "bundleId"] {
            if let value = arguments?[key]?.stringValue, !value.isEmpty {
                // 2.8.0 spelled a Safari page as `safari:<url>`; keep that working.
                if let (browser, _) = splitBrowserPrefix(value) {
                    return TargetIdentity(raw: browser)
                }
                return TargetIdentity(raw: value)
            }
        }
        if let url = arguments?["url"]?.stringValue, parseURL(url) != nil {
            return TargetIdentity(raw: url)
        }
        return nil
    }

    /// A copy that carries the routing hints read from the call's arguments.
    public func routed(pageHint: URL?, headless: Bool) -> TargetIdentity {
        var copy = self
        copy.pageHint = pageHint
        copy.headless = headless
        return copy
    }

    /// The page an `app` + `url` (or `safari:<url>`) call wants the browser on.
    public static func pageURL(arguments: JSONValue?) -> URL? {
        for key in ["app", "target"] {
            if let value = arguments?[key]?.stringValue, let (_, url) = splitBrowserPrefix(value) {
                return url
            }
        }
        if let raw = arguments?["url"]?.stringValue { return parseURL(raw) }
        return nil
    }

    /// `safari:https://x` → ("com.apple.Safari", https://x). Only for browser prefixes,
    /// so `myapp:route`-style strings are never misread.
    static func splitBrowserPrefix(_ raw: String) -> (String, URL)? {
        let prefixes = ["safari:": "com.apple.Safari", "chrome:": "com.google.Chrome"]
        for (prefix, bundle) in prefixes where raw.lowercased().hasPrefix(prefix) {
            if let url = parseURL(String(raw.dropFirst(prefix.count))) { return (bundle, url) }
        }
        return nil
    }

    public var isHTTP: Bool {
        guard let url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file" || scheme == "about" || scheme == "data"
    }

    public static func parseURL(_ raw: String) -> URL? {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("file://") || lowered.hasPrefix("about:")
            || lowered.hasPrefix("data:") {
            return URL(string: raw)
        }
        return nil
    }

    public static func parseUDID(_ raw: String) -> String? {
        let value = raw.hasPrefix("sim:") ? String(raw.dropFirst(4)) : raw
        if value.lowercased() == "booted" { return "booted" }
        let compact = value.replacingOccurrences(of: "-", with: "")
        let hex = compact.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
        // Modern simulator UDIDs are 8-4-4-4-12; devices are 40-char hex.
        if hex && (compact.count == 40 || compact.count == 32) { return value }
        return nil
    }

    public static func parsePID(_ raw: String) -> pid_t? {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isNumber }), let value = Int32(raw), value > 0 else {
            return nil
        }
        return pid_t(value)
    }
}

public enum AppCatalog: Equatable, Sendable {
    public static let chromiumBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    public static let chromiumCDPBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    public static let blenderBundles: Set<String> = [
        "org.blenderfoundation.blender",
    ]

    public static let blenderNames: Set<String> = [
        "blender", "blender.app",
    ]

    public static let browserNames: Set<String> = [
        "google chrome", "chrome", "chromium", "brave", "microsoft edge", "edge",
        "safari", "firefox", "opera", "vivaldi", "arc",
    ]

    public static func isChromium(_ identity: TargetIdentity) -> Bool {
        if identity.kind == .url { return identity.isHTTP }
        let key = identity.bundleHint?.lowercased() ?? ""
        if chromiumCDPBundles.contains(identity.bundleHint ?? "") { return true }
        if chromiumCDPBundles.contains(where: { $0.lowercased() == key }) { return true }
        return ["google chrome", "chrome", "chromium", "brave", "microsoft edge",
                "edge", "opera", "vivaldi", "arc"].contains(key)
    }

    public static func isBrowser(_ identity: TargetIdentity) -> Bool {
        if identity.kind == .url { return identity.isHTTP }
        let hint = identity.bundleHint ?? ""
        if chromiumBundles.contains(hint) { return true }
        return browserNames.contains(hint.lowercased())
    }

    public static func isBlender(_ identity: TargetIdentity) -> Bool {
        let hint = identity.bundleHint ?? ""
        if blenderBundles.contains(hint) { return true }
        return blenderNames.contains(hint.lowercased())
    }

    public static func isSafari(_ identity: TargetIdentity) -> Bool {
        let hint = identity.bundleHint ?? ""
        return hint == "com.apple.Safari" || hint == "com.apple.SafariTechnologyPreview"
            || hint.lowercased() == "safari"
    }
}
