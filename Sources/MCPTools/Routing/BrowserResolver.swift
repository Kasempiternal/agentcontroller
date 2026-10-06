import AppKit
import Foundation
import MCPServer

/// A real, installed browser the user can see — as opposed to the dedicated headless
/// Chromium the CDP backend launches with its own throwaway profile.
public struct BrowserTarget: Equatable, Sendable {
    public let bundleId: String
    public let name: String
    public let appURL: URL
}

/// Where a web request should land.
public enum BrowserChoice: Equatable, Sendable {
    /// The user's own browser app, driven in the background (AX, or CDP when that browser
    /// already publishes a DevTools port).
    case browser(BrowserTarget)
    /// A dedicated headless Chromium (separate profile, invisible, CDP refs).
    case headless
}

/// Turns "safari" / "chrome" / "default" / a bundle id into an installed browser, and
/// knows the system default. Before this existed every URL went to Chromium no matter
/// what the user asked for, because nothing in the server ever consulted either.
public enum BrowserResolver {
    /// Spoken names → bundle ids, most specific first. Lowercased keys.
    static let aliases: [String: String] = [
        "safari": "com.apple.Safari",
        "safari technology preview": "com.apple.SafariTechnologyPreview",
        "chrome": "com.google.Chrome",
        "google chrome": "com.google.Chrome",
        "chrome canary": "com.google.Chrome.canary",
        "chromium": "org.chromium.Chromium",
        "firefox": "org.mozilla.firefox",
        "edge": "com.microsoft.edgemac",
        "microsoft edge": "com.microsoft.edgemac",
        "brave": "com.brave.Browser",
        "brave browser": "com.brave.Browser",
        "arc": "company.thebrowser.Browser",
        "opera": "com.operasoftware.Opera",
        "vivaldi": "com.vivaldi.Vivaldi",
    ]

    /// The app macOS opens https links with (System Settings > Desktop & Dock > Default
    /// web browser).
    public static func systemDefault() -> BrowserTarget? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL),
              let bundleId = bundle.bundleIdentifier else { return nil }
        return BrowserTarget(bundleId: bundleId, name: displayName(appURL), appURL: appURL)
    }

    /// Resolve a user-facing browser name, bundle id or "default". nil = not an
    /// installed browser.
    public static func named(_ raw: String) -> BrowserTarget? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty || key == "default" || key == "system" { return systemDefault() }
        let bundleId = aliases[key]
            ?? (AppCatalog.chromiumBundles.first { $0.lowercased() == key })
        guard let bundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return BrowserTarget(bundleId: bundleId, name: displayName(appURL), appURL: appURL)
    }

    /// Is this `app` value naming a browser (by name or bundle id)?
    public static func isBrowserName(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aliases[key] != nil || AppCatalog.chromiumBundles.contains { $0.lowercased() == key }
    }

    /// Decide where a web request goes.
    ///
    /// - browser:  the explicit `browser` argument, if the agent passed one
    ///             ("safari", "chrome", "default", "headless", or a bundle id).
    /// - app:      the `app` argument, when it names a browser.
    /// - headless: an explicit `headless:true`.
    ///
    /// Throws when the agent named a browser that is not installed — silently falling
    /// back to some other browser is exactly the bug this type exists to kill.
    public static func choose(browser: String?, app: String?, headless: Bool?) throws -> BrowserChoice {
        // A named browser is binding — even over headless:true. On macOS the real browser
        // is already driven in the background without taking focus, so it is "headless"
        // in every way the user cares about, and it keeps their logins.
        if let named = [browser, app].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            if named.lowercased() == "headless" { return .headless }
            guard let target = Self.named(named) else {
                throw ToolError.actionFailed(
                    "Browser '\(named)' is not installed. Default browser: \(systemDefault()?.name ?? "unknown"). Not falling back to another browser."
                )
            }
            return .browser(target)
        }
        if headless == true { return .headless }
        guard let target = systemDefault() else {
            throw ToolError.actionFailed("No default web browser is set on this Mac. Name one with `browser`, or pass headless:true.")
        }
        return .browser(target)
    }

    private static func displayName(_ appURL: URL) -> String {
        appURL.deletingPathExtension().lastPathComponent
    }
}
