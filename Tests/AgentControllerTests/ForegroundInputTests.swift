import XCTest
@testable import AccessibilityEngine

/// Foreground input posts to the global HID stream, which lands in whatever app is
/// frontmost. The rules that keep it out of the user's app: never post unless the target
/// was verified frontmost, and never let two foreground sequences interleave.
final class ForegroundInputTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testReturnsImmediatelyWhenAlreadyFrontmost() async throws {
        let polls = Counter()
        let arrived = try await ForegroundInput.waitUntilFrontmost(pid: 7, deadline: 1, pollInterval: 0.01) {
            _ = polls.next()
            return 7
        }
        XCTAssertTrue(arrived)
        XCTAssertEqual(polls.get(), 1)
    }

    func testWaitsForTheTargetToArrive() async throws {
        let polls = Counter()
        let arrived = try await ForegroundInput.waitUntilFrontmost(pid: 7, deadline: 2, pollInterval: 0.01) {
            polls.next() >= 4 ? 7 : 99
        }
        XCTAssertTrue(arrived)
        XCTAssertEqual(polls.get(), 4)
    }

    func testGivesUpAtTheDeadlineWhenAnotherAppStaysFrontmost() async throws {
        let start = Date()
        let arrived = try await ForegroundInput.waitUntilFrontmost(pid: 7, deadline: 0.15, pollInterval: 0.02) { 99 }
        XCTAssertFalse(arrived)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testNoFrontmostAppCountsAsNotArrived() async throws {
        let arrived = try await ForegroundInput.waitUntilFrontmost(pid: 7, deadline: 0.05, pollInterval: 0.01) { nil }
        XCTAssertFalse(arrived)
    }

    func testRefusalMessageNamesWhoHoldsTheFront() {
        let named = ForegroundInput.refusalMessage(requested: 123, frontmost: "Mail")
        XCTAssertTrue(named.contains("pid 123") && named.contains("'Mail' is still frontmost") && named.contains("Nothing was sent"), named)
        XCTAssertTrue(ForegroundInput.refusalMessage(requested: 123, frontmost: nil).contains("no app reported frontmost"))
    }

    // MARK: - Gate

    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var peak = 0
        func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
        func leave() { lock.lock(); current -= 1; lock.unlock() }
        func readPeak() -> Int { lock.lock(); defer { lock.unlock() }; return peak }
    }

    private func peakConcurrency(gate: AsyncGate?) async -> Int {
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await gate?.acquire()
                    gauge.enter()
                    try? await AXExecutor.pause(0.01)
                    gauge.leave()
                    await gate?.release()
                }
            }
        }
        return gauge.readPeak()
    }

    func testGateAdmitsOneHolderAtATime() async {
        let gated = await peakConcurrency(gate: AsyncGate())
        XCTAssertEqual(gated, 1, "two holders were inside the gate at once")
    }

    /// Proves the harness can see overlap, so the test above passing means something.
    func testWithoutTheGateTheSameWorkloadOverlaps() async {
        let ungated = await peakConcurrency(gate: nil)
        XCTAssertGreaterThan(ungated, 1)
    }

    func testGateIsReusableAfterRelease() async {
        let gate = AsyncGate()
        await gate.acquire()
        await gate.release()
        await gate.acquire()
        await gate.release()
    }
}
