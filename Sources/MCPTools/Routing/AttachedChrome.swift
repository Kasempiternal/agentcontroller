import AppKit
import Foundation
import PortOwnership

/// The DevTools port of the very browser a web call resolved to, when that browser publishes one.
///
/// 3.1.1 handed every Chrome page to LaunchServices (`NSWorkspace.open`, activates=false) and then
/// looked for the tab over CDP. Chrome ignores the background request: it came to the front on
/// every call (Focus Guard pulled it back), and every call left one more tab that the tab cap never
/// counted, because only tabs opened over CDP are known to be the agent's. Measured on the release
/// Chrome, 15/10/2026: three snapshots, three new tabs, a focus steal each time. With a port, the
/// page goes in over CDP instead (`Target.createTarget {background:true}`): no LaunchServices, no
/// activation, the user's tabs untouched, the agent's own tabs reused and capped.
enum AttachedChrome {
    /// Tests inject the answer; nil means probe for real.
    nonisolated(unsafe) static var resolverOverride: (@Sendable (BrowserTarget) async -> UInt16?)?

    static func port(for browser: BrowserTarget) async -> UInt16? {
        if let resolverOverride { return await resolverOverride(browser) }
        guard AppCatalog.chromiumCDPBundles.contains(browser.bundleId) else { return nil }
        if let cached = cache.lookup(bundleId: browser.bundleId) { return cached }
        // Whose socket it is settles that it is this browser's DevTools port; no HTTP round trip,
        // whose short timeout a busy or just-started Chrome missed, sending the page back to
        // LaunchServices.
        for port in ChromeLauncher.candidatePorts() {
            guard await SocketProbe.connectAsync(port: port, timeoutMs: 250),
                  let pid = LoopbackListener.owners(port: port).first(where: { bundleIdentifier(of: $0) == browser.bundleId })
            else { continue }
            cache.store(bundleId: browser.bundleId, port: port, pid: pid)
            return port
        }
        return nil
    }

    /// The port belongs to THIS browser when its owner is that app: Edge holding 9222 while the agent
    /// asked for Chrome is not the user's choice. By bundle id, not path: Chrome often runs from a
    /// code-sign clone (`/private/var/folders/…/com.google.Chrome.code_sign_clone/…/Google
    /// Chrome.app.bundle`), so its executable is not inside /Applications/Google Chrome.app.
    static func bundleIdentifier(of pid: pid_t) -> String? {
        if let path = LoopbackListener.executablePath(pid: pid), let id = bundleIdentifier(ofExecutable: path) {
            return id
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// The identifier in the Info.plist of the bundle an executable sits in (…/Contents/MacOS/x).
    static func bundleIdentifier(ofExecutable path: String) -> String? {
        guard let range = path.range(of: "/Contents/MacOS/", options: .backwards) else { return nil }
        let plist = String(path[..<range.lowerBound]) + "/Contents/Info.plist"
        return (NSDictionary(contentsOfFile: plist)?["CFBundleIdentifier"] as? String)
    }

    /// Finding the owner walks every process's sockets; re-checking the one seen last does not.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (port: UInt16, pid: pid_t)] = [:]

        func lookup(bundleId: String) -> UInt16? {
            lock.lock()
            let entry = entries[bundleId]
            lock.unlock()
            guard let entry else { return nil }
            if LoopbackListener.isListening(pid: entry.pid, port: entry.port) { return entry.port }
            lock.lock()
            entries[bundleId] = nil
            lock.unlock()
            return nil
        }

        func store(bundleId: String, port: UInt16, pid: pid_t) {
            lock.lock()
            entries[bundleId] = (port, pid)
            lock.unlock()
        }
    }
}
