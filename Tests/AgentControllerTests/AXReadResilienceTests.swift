import XCTest
import ApplicationServices
@testable import AccessibilityEngine

/// The retry decision and the stall breaker are pure given an elapsed time and a clock,
/// so the hung-app behavior is testable without a hung app.
final class AXReadResilienceTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    // MARK: - Retry decision

    func testFastCannotCompleteIsRetriedAsBusy() {
        XCTAssertTrue(AXTransientRetry.shouldRetry(result: .cannotComplete, elapsedNanos: 5 * ms, attempt: 1))
        XCTAssertTrue(AXTransientRetry.shouldRetry(result: .cannotComplete, elapsedNanos: 5 * ms, attempt: 2))
    }

    func testRetriesAreBounded() {
        XCTAssertFalse(AXTransientRetry.shouldRetry(
            result: .cannotComplete, elapsedNanos: 5 * ms, attempt: AXTransientRetry.maxAttempts))
    }

    /// The bug: a 2s messaging timeout surfaces as .cannotComplete too, and retrying it
    /// tripled the cost of every attribute read against a hung app.
    func testTimedOutCannotCompleteIsNotRetried() {
        XCTAssertFalse(AXTransientRetry.shouldRetry(result: .cannotComplete, elapsedNanos: 2_000 * ms, attempt: 1))
        XCTAssertTrue(AXTransientRetry.isStall(result: .cannotComplete, elapsedNanos: 2_000 * ms))
    }

    func testSlowButNotTimedOutNeitherRetriesNorTrips() {
        let elapsed = 200 * ms
        XCTAssertFalse(AXTransientRetry.shouldRetry(result: .cannotComplete, elapsedNanos: elapsed, attempt: 1))
        XCTAssertFalse(AXTransientRetry.isStall(result: .cannotComplete, elapsedNanos: elapsed))
    }

    /// Found live: Safari mid-page-load answers .cannotComplete in 0.5-1.9s. Counting that
    /// as a stall opened the breaker and the post-navigation snapshot returned 0 elements.
    func testSlowLoadingBrowserDoesNotTripTheBreaker() {
        for elapsed in [600 * ms, 1_200 * ms, 1_700 * ms] {
            XCTAssertFalse(AXTransientRetry.isStall(result: .cannotComplete, elapsedNanos: elapsed), "\(elapsed / ms)ms")
        }
    }

    func testStableErrorsAreNeverRetriedOrCountedAsStalls() {
        for error in [AXError.attributeUnsupported, .noValue, .invalidUIElement, .apiDisabled] {
            XCTAssertFalse(AXTransientRetry.shouldRetry(result: error, elapsedNanos: 1 * ms, attempt: 1), "\(error)")
            XCTAssertFalse(AXTransientRetry.isStall(result: error, elapsedNanos: 3_000 * ms), "\(error)")
        }
    }

    // MARK: - Breaker

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: UInt64 = 1_000
        func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return now }
        func advance(by nanos: UInt64) { lock.lock(); now += nanos; lock.unlock() }
    }

    func testBreakerOpensAfterTripAndClosesAfterTheWindow() {
        let clock = FakeClock()
        let breaker = AXStallBreaker(clock: { clock.read() })
        XCTAssertFalse(breaker.isOpen(pid: 42))

        breaker.trip(pid: 42)
        XCTAssertTrue(breaker.isOpen(pid: 42))

        clock.advance(by: AXStallBreaker.windowNanos - 1)
        XCTAssertTrue(breaker.isOpen(pid: 42))

        clock.advance(by: 2)
        XCTAssertFalse(breaker.isOpen(pid: 42), "the first read after the window must go through as the probe")
    }

    func testBreakerIsPerPid() {
        let clock = FakeClock()
        let breaker = AXStallBreaker(clock: { clock.read() })
        breaker.trip(pid: 1)
        XCTAssertTrue(breaker.isOpen(pid: 1))
        XCTAssertFalse(breaker.isOpen(pid: 2))
    }

    func testRetripExtendsTheWindow() {
        let clock = FakeClock()
        let breaker = AXStallBreaker(clock: { clock.read() })
        breaker.trip(pid: 7)
        clock.advance(by: AXStallBreaker.windowNanos - 10)
        breaker.trip(pid: 7)
        clock.advance(by: AXStallBreaker.windowNanos - 10)
        XCTAssertTrue(breaker.isOpen(pid: 7))
    }

    // MARK: - Real reads against a pid that is not there

    func testReadsAgainstADeadPidReturnNothingQuickly() {
        let started = Date()
        let element = AXElement.application(pid: 2_147_483_000, timeout: 0.5)
        XCTAssertNil(element.role)
        XCTAssertTrue(element.readAttributes(["AXRole", "AXTitle"]).isEmpty)
        XCTAssertTrue(element.actionNames.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testProcessLiveness() {
        XCTAssertTrue(AXElement.isProcessAlive(getpid()))
        XCTAssertFalse(AXElement.isProcessAlive(2_147_483_000))
    }
}

/// Lanes block on synchronous AX IPC, so each one runs on its own dispatch queue rather
/// than on a Swift cooperative-pool thread that the server's other Tasks need.
final class AXExecutorIsolationTests: XCTestCase {
    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    func testEachLaneRunsOnItsOwnDispatchQueue() async {
        let first = await AXExecutor.app(pid_t(910_001)).run { Self.currentQueueLabel() }
        let second = await AXExecutor.app(pid_t(910_002)).run { Self.currentQueueLabel() }
        let global = await AXExecutor.globalInput.run { Self.currentQueueLabel() }

        XCTAssertEqual(first, "agentcontroller.ax.app.910001")
        XCTAssertEqual(second, "agentcontroller.ax.app.910002")
        XCTAssertEqual(global, "agentcontroller.ax.globalInput")
    }

    func testLaneForTheSamePidIsReused() async {
        let a = await AXExecutor.app(pid_t(910_003)).run { Self.currentQueueLabel() }
        let b = await AXExecutor.app(pid_t(910_003)).run { Self.currentQueueLabel() }
        XCTAssertEqual(a, b)
    }

    func testWorkOnOneLaneNeverOverlaps() async {
        let lane = AXExecutor.app(pid_t(920_000))
        let probe = OverlapProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await lane.run { probe.enter(); usleep(2_000); probe.leave() } }
            }
        }
        XCTAssertEqual(probe.entries, 20)
        XCTAssertEqual(probe.maxConcurrent, 1)
    }

    private final class OverlapProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxConcurrent = 0
        private(set) var entries = 0
        func enter() {
            lock.lock(); active += 1; entries += 1; maxConcurrent = max(maxConcurrent, active); lock.unlock()
        }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
    }
}
