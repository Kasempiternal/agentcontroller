import XCTest
import MCPServer
import PortOwnership
@testable import CLICore

/// 3.1.0: the bridge starts a dead app itself, in the background, once across all sessions,
/// and tells the agent what to run when it cannot, instead of "launch the app first".
final class BridgeLaunchTests: XCTestCase {

    func testLauncherNeverActivatesTheApp() {
        let installed = OpenLauncher.arguments { $0 == "/Applications/AgentController.app" }
        XCTAssertEqual(installed, ["-g", "-j", "/Applications/AgentController.app"])
        let bundle = OpenLauncher.arguments { _ in false }
        XCTAssertEqual(bundle, ["-g", "-j", "-b", "izotz.agentcontroller"])
        for arguments in [installed, bundle] {
            XCTAssertTrue(arguments.contains("-g"), "-g keeps the launch from taking the foreground")
            XCTAssertTrue(arguments.contains("-j"), "-j starts it hidden")
        }
    }

    private func tempLock() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ac-lock-\(UUID().uuidString)").path
    }

    func testLauncherLeavesARunningAppAlone() {
        let calls = Recorder<[String]>()
        OpenLauncher(isRunning: { true }, run: { calls.add($0) }, lockPath: tempLock()).launch()
        XCTAssertTrue(calls.values.isEmpty, "open on a running app sends a reopen event, and the app answers it by taking focus")
        let lock = tempLock()
        defer { rmdir(lock) }
        OpenLauncher(isRunning: { false }, run: { calls.add($0) }, lockPath: lock).launch()
        XCTAssertEqual(calls.values.count, 1)
        XCTAssertEqual(Array(calls.values[0].prefix(2)), ["-g", "-j"])
    }

    /// Several Claude sessions find the app dead at the same moment: one launch, not one each.
    func testOnlyOneProcessWinsTheLaunchLockUntilItExpires() {
        let lock = tempLock()
        defer { rmdir(lock) }
        let first = OpenLauncher(isRunning: { false }, run: { _ in }, lockPath: lock)
        let second = OpenLauncher(isRunning: { false }, run: { _ in }, lockPath: lock)
        XCTAssertTrue(first.acquireLock())
        XCTAssertFalse(second.acquireLock(), "a second bridge must not start the app again")
        XCTAssertTrue(second.acquireLock(now: Date().addingTimeInterval(OpenLauncher.lockLifetime + 1)),
                      "a lock from a launch that is over is taken over")
    }

    func testRunningCheckFindsThisTestProcessAndNotAMadeUpOne() {
        let me = ProcessInfo.processInfo.arguments[0]
        let name = "/" + (me as NSString).lastPathComponent
        XCTAssertTrue(LoopbackListener.userProcessRuns(executablePathSuffix: name), name)
        XCTAssertFalse(LoopbackListener.userProcessRuns(executablePathSuffix: "/NoSuchApp-\(UUID().uuidString)"))
    }

    private final class CountingLauncher: AppLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var onLaunch: (() -> Void)?
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func launch() { lock.lock(); _count += 1; lock.unlock(); onLaunch?() }
    }

    func testThrottledLauncherStartsTheAppOncePerWindow() {
        let base = CountingLauncher()
        var clock = Date(timeIntervalSince1970: 1_000)
        let throttled = ThrottledLauncher(base, interval: 20, now: { clock })
        throttled.launch(); throttled.launch(); throttled.launch()
        XCTAssertEqual(base.count, 1, "a burst of failing requests is one launch")
        clock = clock.addingTimeInterval(21)
        throttled.launch()
        XCTAssertEqual(base.count, 2, "after the window a second launch is allowed")
    }

    func testCacheReportsAMissingEndpointOnceAndKeepsWaiting() {
        let missing = Counter()
        let cache = EndpointCache(startupWait: 0.1, pollInterval: 0.01, onMissing: { missing.bump() }) {
            throw Endpoint.Failure.notRunning
        }
        XCTAssertThrowsError(try cache.resolve())
        XCTAssertThrowsError(try cache.resolve())
        XCTAssertEqual(missing.value, 1, "the launch hook fires once, not per poll")
    }

    func testAwaitEndpointSkipsAStaleListenerAndReturnsTheLiveOne() {
        let stale = Endpoint(port: 1, token: "old")
        let live = Endpoint(port: 2, token: "new")
        let box = Recorder<Endpoint>()
        box.add(stale)
        let cache = EndpointCache(startupWait: 0) { box.values.last ?? stale }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { box.add(live) }
        let found = cache.awaitEndpoint(timeout: 5) { $0.port == 2 }
        XCTAssertEqual(found, live)
    }

    func testAwaitEndpointGivesUpWhenNothingComesUp() {
        let cache = EndpointCache(startupWait: 0, pollInterval: 0.01) { Endpoint(port: 1, token: "t") }
        XCTAssertNil(cache.awaitEndpoint(timeout: 0.1) { _ in false })
    }

    private final class Collector: LineOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [Data] = []
        func writeLine(_ body: Data) { lock.lock(); _lines.append(body); lock.unlock() }
        func flush() {}
        var lines: [Data] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    /// The failure that cost a week: the app was not running, so the bridge answered "launch
    /// it first" and the agent handed the problem to the user. Now the request launches the
    /// app, waits for the new endpoint and is delivered.
    func testRequestToADeadAppLaunchesItAndIsDelivered() async throws {
        let handler = MCPProtocolHandler(toolProvider: FakeProvider())
        let server = HTTPServer { body, clientId in await handler.handleRequest(body, clientId: clientId) }
        let port = try await server.start()
        let token = await server.authToken
        defer { Task { await server.stop() } }

        let dead = Endpoint(port: 1, token: "stale")
        let live = Endpoint(port: port, token: token)
        let box = Recorder<Endpoint>()
        box.add(dead)
        let launcher = CountingLauncher()
        // The app "starts" the moment it is asked to: it publishes its real endpoint.
        launcher.onLaunch = { box.add(live) }

        // Only the live port has a listener of ours; port 1 (the stale file) has none.
        let listener = ListenerCheck(owner: { $0 == port ? getpid() : nil }, holds: { _, p in p == port })
        let out = Collector()
        let relay = MCPBridge(cache: EndpointCache(startupWait: 0) { box.values.last ?? dead },
                              output: out, listener: listener, launcher: launcher, relaunchWait: 5)

        relay.accept(Wire.request(7, "ping"))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 10))

        XCTAssertEqual(launcher.count, 1)
        XCTAssertEqual(out.lines.count, 1)
        let reply = Wire.decode(out.lines[0])
        XCTAssertEqual(reply["id"], .int(7))
        XCTAssertNil(reply["error"], "delivered after the launch, not refused")
    }

    /// Hours into a session the app quits and removes its files. The startup window is long
    /// closed, so the cache throws at once; the request must still start the app.
    func testAppThatQuitMidSessionIsStartedByTheNextRequest() async throws {
        let handler = MCPProtocolHandler(toolProvider: FakeProvider())
        let server = HTTPServer { body, clientId in await handler.handleRequest(body, clientId: clientId) }
        let port = try await server.start()
        let token = await server.authToken
        defer { Task { await server.stop() } }

        let live = Endpoint(port: port, token: token)
        let box = Recorder<Endpoint>()
        let launcher = CountingLauncher()
        launcher.onLaunch = { box.add(live) }
        let cache = EndpointCache(startupWait: 0) {
            guard let found = box.values.last else { throw Endpoint.Failure.notRunning }
            return found
        }
        let listener = ListenerCheck(owner: { $0 == port ? getpid() : nil }, holds: { _, p in p == port })
        let out = Collector()
        let relay = MCPBridge(cache: cache, output: out, listener: listener, launcher: launcher, relaunchWait: 5)

        relay.accept(Wire.request(11, "ping"))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 10))
        XCTAssertEqual(launcher.count, 1)
        XCTAssertNil(Wire.decode(out.lines[0])["error"], "answered by the app it just started")
    }

    func testDeadAppThatNeverStartsAnswersWithAnInstructionForTheAgent() {
        let out = Collector()
        let launcher = CountingLauncher()
        let listener = ListenerCheck(owner: { _ in nil }, holds: { _, _ in false })
        let relay = MCPBridge(cache: EndpointCache(startupWait: 0) { Endpoint(port: 1, token: "t") },
                              output: out, listener: listener, launcher: launcher, relaunchWait: 0.1)
        relay.accept(Wire.request(5, "ping"))
        XCTAssertTrue(relay.waitUntilIdle(timeout: 5))
        let message = Wire.decode(out.lines[0])["error"]?["message"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("not running"), message)
        XCTAssertTrue(message.contains("open -g -j"), "the fix is a command the agent can run: \(message)")
        XCTAssertTrue(message.contains("Do not ask the user"), message)
    }
}
