import Foundation
import MCPServer
#if canImport(Darwin)
import Darwin
#endif

/// The headless Chromium this app launched for itself. One per process: every web
/// session shares it as its own tab. Held process-wide (not inside the backend actor) so
/// the synchronous quit hook can terminate it without awaiting anything.
final class OwnedChrome: @unchecked Sendable {
    let process: Process
    let port: UInt16

    init(process: Process, port: UInt16) {
        self.process = process
        self.port = port
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { ChromeLauncher.terminateBlocking(pid: process.processIdentifier) }
        ChromeLauncher.removePIDFile(ifFor: process.processIdentifier)
    }
}

enum OwnedChromeRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chrome: OwnedChrome?

    static var current: OwnedChrome? {
        lock.lock()
        defer { lock.unlock() }
        return chrome
    }

    static func set(_ value: OwnedChrome) {
        lock.lock()
        chrome = value
        lock.unlock()
    }

    static func take() -> OwnedChrome? {
        lock.lock()
        defer { lock.unlock() }
        let value = chrome
        chrome = nil
        return value
    }
}

/// Process-wide teardown for the app's quit path. Synchronous on purpose:
/// `applicationWillTerminate` returns, and the process exits, before a detached Task
/// would get to run — and the headless Chrome this app owns would be orphaned for good.
public enum BackendLifecycle {
    public static func shutdown() {
        OwnedChromeRegistry.take()?.terminate()
    }
}

enum ChromeLauncher {
    struct PageTarget: Sendable, Equatable {
        var id: String
        var url: String
        var webSocketDebuggerURL: URL
    }

    /// Comma-separated ports to probe for a user-run Chrome. 9229 is deliberately not a
    /// default: it is Node's inspector, which also answers /json endpoints.
    static let debugPortsEnv = "AGENTCONTROLLER_CDP_PORTS"

    static func candidatePorts(environment: [String: String] = ProcessInfo.processInfo.environment) -> [UInt16] {
        if let raw = environment[debugPortsEnv] {
            return raw.split(separator: ",").compactMap {
                UInt16($0.trimmingCharacters(in: .whitespaces))
            }
        }
        return [9222, 9333]
    }

    static func findBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["AGENTCONTROLLER_CHROME"] {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/usr/bin/google-chrome",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Discovery

    /// Socket probe first (80ms, off the cooperative pool), HTTP only for ports that
    /// accepted. The previous order did a blocking `Data(contentsOf:)` against every
    /// candidate before it ever checked whether anything was listening.
    static func findExistingDebugPort() async -> UInt16? {
        for port in candidatePorts() {
            guard await SocketProbe.connectAsync(port: port, timeoutMs: 80) else { continue }
            if let browser = await browserName(port: port), isBrowser(browser) { return port }
        }
        return nil
    }

    /// `/json/version`'s `Browser` field ("Chrome/154.0…"). Node's inspector answers the
    /// same endpoint with "node.js/v22…", so presence alone does not make it a browser.
    static func isBrowser(_ browserField: String) -> Bool {
        let value = browserField.trimmingCharacters(in: .whitespaces).lowercased()
        return !value.isEmpty && !value.hasPrefix("node")
    }

    static func browserName(port: UInt16) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version"),
              let data = try? await http(url, timeout: 0.3),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["Browser"]?.stringValue
    }

    static func listPages(port: UInt16) async throws -> [PageTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            throw CDPError.remote("bad debug URL")
        }
        let data = try await http(url, timeout: 2)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return (json.arrayValue ?? []).compactMap(pageTarget)
    }

    /// A fresh tab. Chrome 111+ only accepts PUT here; older builds only accept GET.
    static func newPage(port: UInt16, url: String = "about:blank") async throws -> PageTarget {
        guard let endpoint = URL(string: "http://127.0.0.1:\(port)/json/new?\(url)") else {
            throw CDPError.remote("bad debug URL")
        }
        let data: Data
        do {
            data = try await http(endpoint, method: "PUT", timeout: 3)
        } catch {
            data = try await http(endpoint, method: "GET", timeout: 3)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let target = pageTarget(json) else {
            throw CDPError.remote("Chrome did not return a page target for a new tab")
        }
        return target
    }

    /// A fresh tab in a USER's Chrome that does not take over their window. `/json/new`
    /// opens its tab in the foreground, swapping the page the user is looking at;
    /// `Target.createTarget {background:true}` (browser endpoint only) does not.
    static func newBackgroundPage(port: UInt16) async throws -> PageTarget {
        guard let versionURL = URL(string: "http://127.0.0.1:\(port)/json/version"),
              let data = try? await http(versionURL, timeout: 2),
              let version = try? JSONDecoder().decode(JSONValue.self, from: data),
              let socket = version["webSocketDebuggerUrl"]?.stringValue,
              let socketURL = URL(string: socket) else {
            throw CDPError.remote("Chrome on port \(port) exposes no browser-level DevTools endpoint to open a background tab with")
        }
        let browser = CDPConnection(url: socketURL)
        try await browser.open(enablingPage: false)
        let created: JSONValue
        do {
            created = try await browser.send(
                method: "Target.createTarget",
                params: .object(["url": .string("about:blank"), "background": .bool(true)])
            )
        } catch {
            await browser.close(reason: "createTarget failed")
            throw error
        }
        await browser.close(reason: "tab created")
        guard let id = created["targetId"]?.stringValue else {
            throw CDPError.remote("Chrome did not return a target for the new background tab")
        }
        // /json/list can trail the creation by a few milliseconds.
        for _ in 0..<20 {
            if let page = try await listPages(port: port).first(where: { $0.id == id }) { return page }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CDPError.remote("The new background tab never appeared in Chrome's page list")
    }

    /// Best effort: a tab that is already gone is the outcome we wanted.
    static func closePage(port: UInt16, id: String) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/close/\(id)") else { return }
        _ = try? await http(url, timeout: 2)
    }

    private static func pageTarget(_ item: JSONValue) -> PageTarget? {
        guard let ws = item["webSocketDebuggerUrl"]?.stringValue, let wsURL = URL(string: ws) else { return nil }
        let type = item["type"]?.stringValue ?? "page"
        guard type == "page" || type == "webview" else { return nil }
        return PageTarget(id: item["id"]?.stringValue ?? ws, url: item["url"]?.stringValue ?? "", webSocketDebuggerURL: wsURL)
    }

    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Loopback only. A system proxy that does not exempt 127.0.0.1 would send the
        // DevTools handshake out to the proxy.
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static func http(_ url: URL, method: String = "GET", timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        let (data, response) = try await httpSession.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw CDPError.remote("DevTools HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(method) \(url.path)")
        }
        return data
    }

    // MARK: - Owned browser

    static func launchOwned(headless: Bool) async throws -> OwnedChrome {
        guard let binary = findBinary() else {
            throw ToolError.actionFailed("No Chromium browser found")
        }
        await reapStaleOwnedChrome()

        let port = try freePort()
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-extensions",
            "about:blank",
        ]
        if headless {
            args.insert("--headless=new", at: 0)
        }
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let chrome = OwnedChrome(process: process, port: port)
        for _ in 0..<100 {
            if await browserName(port: port) != nil {
                // Written only now that this Chrome is known to be the one serving our port.
                // A launch that lost the profile lock to another copy of the app exits at
                // once having answered nothing, and the pid file at that path is THAT
                // copy's: writing ours first and deleting it on failure erased its record
                // of the Chrome it has to reap after a crash.
                try? "\(process.processIdentifier) \(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
                OwnedChromeRegistry.set(chrome)
                return chrome
            }
            guard process.isRunning else {
                throw ToolError.actionFailed("Chrome failed to start: it exited with status \(process.terminationStatus) before opening a DevTools port (the profile may be in use by another AgentController)")
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                // Cancelled mid-launch: nothing holds a reference to this Chrome yet.
                chrome.terminate()
                throw error
            }
        }
        chrome.terminate()
        throw ToolError.actionFailed("Chrome failed to start: no DevTools endpoint answered on port \(port) within 5s")
    }

    /// `AGENTCONTROLLER_CDP_PROFILE` redirects the profile (and the pid file inside it) —
    /// how tests keep clear of the profile an installed copy of the app may be using.
    static var profileDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTCONTROLLER_CDP_PROFILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return cacheDir().appendingPathComponent("cdp-profile")
    }

    /// "<chrome pid> <owner pid>": the owner is the AgentController process that launched it.
    static var pidFile: URL {
        profileDirectory.appendingPathComponent("owned-chrome.pid")
    }

    /// Deletes the pid file only when it still records `chromePID` under THIS process as
    /// owner. Anything else is another instance's record (or none), and removing it would
    /// strip a live Chrome of the cleanup that finds it after a crash.
    static func removePIDFile(ifFor chromePID: pid_t) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        let fields = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        guard fields == [chromePID, getpid()] else { return }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// A previous run that died without its quit hook (crash, kill -9) leaves its Chrome
    /// alive, holding the profile directory — a fresh launch against it would hand the
    /// URL to the old process and exit. Two guards keep this from killing the wrong thing:
    /// the owner must be gone (another running copy of the app legitimately owns its
    /// Chrome), and the pid's command line must still name OUR profile directory (a
    /// recycled pid is never signalled).
    static func reapStaleOwnedChrome() async {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        let fields = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        guard let chrome = fields.first, chrome > 1 else {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        if fields.count > 1, fields[1] != getpid(), kill(fields[1], 0) == 0 { return }
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard kill(chrome, 0) == 0,
              let ps = try? await ProcessRunner.run(executable: "/bin/ps", arguments: ["-p", "\(chrome)", "-o", "command="], timeout: 3),
              ps.stdoutString.contains("--user-data-dir=\(profileDirectory.path)") else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                terminateBlocking(pid: chrome)
                continuation.resume()
            }
        }
    }

    /// SIGTERM, up to ~1s for a clean exit, then SIGKILL. Blocking by design: it runs on
    /// the quit path and on a GCD thread, never on the cooperative pool.
    static func terminateBlocking(pid: pid_t) {
        kill(pid, SIGTERM)
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { return }
            usleep(25_000)
        }
        kill(pid, SIGKILL)
    }

    private static func cacheDir() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentController")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentController")
    }

    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError.actionFailed("socket") }
        defer { close(fd) }
        var soAddr = sockaddr_in()
        soAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        soAddr.sin_family = sa_family_t(AF_INET)
        soAddr.sin_port = 0
        let pton = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &soAddr.sin_addr) }
        guard pton == 1 else { throw ToolError.actionFailed("inet_pton") }
        let bindRC: Int32 = withUnsafePointer(to: &soAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else { throw ToolError.actionFailed("bind") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &soAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: soAddr.sin_port)
    }
}
