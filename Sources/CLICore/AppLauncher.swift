import Foundation
import PortOwnership

/// Starts the menu-bar app when a client needs it and it is not running.
///
/// Before 3.1.0 the bridge answered a dead app with "launch the menu bar app first", which an
/// agent reads as "ask the human". A client that starts before the app (or after a crash)
/// would then mark the whole server failed for the session. The bridge now starts the app
/// itself, in the background, and waits for it.
public protocol AppLaunching: Sendable {
    /// Starts the app and returns at once. Must never bring it to the front.
    func launch()
}

/// What tests inject: starting a real app from a unit test would be a side effect.
public struct NoLauncher: AppLaunching {
    public init() {}
    public func launch() {}
}

/// `open -g -j`: `-g` keeps the launch from taking the foreground and `-j` starts it hidden,
/// so the user's frontmost app, cursor and Space stay exactly as they were. Plain `open` is
/// what Focus Guard flags as a focus steal.
public struct OpenLauncher: AppLaunching, @unchecked Sendable {
    public static let bundleID = "izotz.agentcontroller"
    public static let installedPaths = [
        "/Applications/AgentController.app",
        "\(NSHomeDirectory())/Applications/AgentController.app",
    ]

    /// Every copy of the app runs an executable whose path ends like this.
    public static let executableSuffix = "/AgentController.app/Contents/MacOS/AgentController"

    private let isRunning: () -> Bool
    private let run: ([String]) -> Void
    private let lockPath: String

    /// Shared by every bridge process (the compiled one and the bash one): several Claude
    /// sessions notice a dead app at the same moment, and only one of them may start it.
    public static let defaultLockPath = "\(NSHomeDirectory())/.agentcontroller/.launch.lock"
    /// A lock older than this is from a launch that is over, whatever its outcome.
    static let lockLifetime: TimeInterval = 20

    /// All three are injectable for tests; the defaults list this user's processes, run `open`
    /// and lock in ~/.agentcontroller.
    public init(isRunning: @escaping () -> Bool = { LoopbackListener.userProcessRuns(executablePathSuffix: OpenLauncher.executableSuffix) },
                run: @escaping ([String]) -> Void = OpenLauncher.runOpen,
                lockPath: String = OpenLauncher.defaultLockPath) {
        self.isRunning = isRunning
        self.run = run
        self.lockPath = lockPath
    }

    /// `mkdir` is atomic across processes: exactly one caller creates the directory. A lock
    /// past its lifetime is taken over.
    func acquireLock(now: Date = Date()) -> Bool {
        if mkdir(lockPath, 0o700) == 0 { return true }
        guard errno == EEXIST,
              let attributes = try? FileManager.default.attributesOfItem(atPath: lockPath),
              let created = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(created) >= Self.lockLifetime else { return false }
        rmdir(lockPath)
        return mkdir(lockPath, 0o700) == 0
    }

    /// The argument list for `/usr/bin/open`. Prefers the installed copy so a stray build
    /// folder copy of the same bundle id is not the one LaunchServices picks.
    static func arguments(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        if let path = installedPaths.first(where: fileExists) { return ["-g", "-j", path] }
        return ["-g", "-j", "-b", bundleID]
    }

    public func launch() {
        // Already running (starting up, or its listener is wedged): `open` would only send a
        // reopen event, which the app answers by showing its window and taking focus.
        guard !isRunning(), acquireLock() else { return }
        run(Self.arguments())
    }

    public static func runOpen(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Lets a burst of failing requests start the app once, not once each. Several requests
/// can fail at the same moment (the bridge runs up to eight at a time) and `open` on an
/// app that is still starting up is wasted work.
public final class ThrottledLauncher: AppLaunching, @unchecked Sendable {
    private let base: AppLaunching
    private let interval: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var last: Date?

    public init(_ base: AppLaunching, interval: TimeInterval = 20, now: @escaping () -> Date = Date.init) {
        self.base = base
        self.interval = interval
        self.now = now
    }

    public func launch() {
        lock.lock()
        let due = last.map { now().timeIntervalSince($0) >= interval } ?? true
        if due { last = now() }
        lock.unlock()
        if due { base.launch() }
    }
}
