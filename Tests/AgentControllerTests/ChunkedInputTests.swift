import XCTest
import CoreGraphics
@testable import AccessibilityEngine
@testable import MCPTools

/// Foreground input is posted to whatever app is frontmost. One frontmost check at the start
/// of a long typing run or drag is stale a second later, so the work is cut into chunks and
/// the target is re-checked before each (S5); a drag that is cut short must still release the
/// mouse (S6); and type_text must not post a single keystroke at a control it could not focus
/// (S4).
final class ChunkedInputTests: XCTestCase {

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int] = []
        private var interrupts = 0
        func add(_ chunk: Int) { lock.lock(); items.append(chunk); lock.unlock() }
        func interrupted() { lock.lock(); interrupts += 1; lock.unlock() }
        var chunks: [Int] { lock.lock(); defer { lock.unlock() }; return items }
        var interruptCount: Int { lock.lock(); defer { lock.unlock() }; return interrupts }
    }

    private final class Sequence: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let answers: [pid_t?]
        init(_ answers: [pid_t?]) { self.answers = answers }
        /// The i-th answer, then the last one for ever.
        func next() -> pid_t? {
            lock.lock(); defer { lock.unlock() }
            defer { calls += 1 }
            return answers[min(calls, answers.count - 1)]
        }
    }

    // MARK: - Chunked foreground delivery

    func testEveryChunkIsPostedWhileTheTargetStaysFrontmost() async throws {
        let log = Log()
        let outcome = try await ForegroundInput.performChunked(
            pid: 7, chunks: 4, onInterrupt: { log.interrupted() }, frontmost: { 7 }
        ) { chunk -> Int in
            log.add(chunk)
            return chunk * 10
        }
        guard case .posted(let results) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(results, [0, 10, 20, 30])
        XCTAssertEqual(log.interruptCount, 0)
    }

    func testSwitchingAppsBetweenChunksStopsTheRestAndReleasesWhatWasHeld() async throws {
        let log = Log()
        // Initial check, then one check before each chunk after the first: 7, 7, then the user
        // is somewhere else before chunk 2.
        let frontmost = Sequence([7, 7, 99])
        let outcome = try await ForegroundInput.performChunked(
            pid: 7, chunks: 5, onInterrupt: { log.interrupted() }, frontmost: { frontmost.next() }
        ) { chunk -> Int in
            log.add(chunk)
            return chunk
        }
        guard case .interrupted(let requested, _, let posted) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(requested, 7)
        XCTAssertEqual(posted, [0, 1], "only the chunks before the switch went out")
        XCTAssertEqual(log.chunks, [0, 1], "a chunk ran after the target stopped being frontmost")
        XCTAssertEqual(log.interruptCount, 1, "a drag cut short must release the mouse button")
    }

    func testATargetThatNeverComesForwardPostsNothingAndHasNothingToRelease() async throws {
        let log = Log()
        // The injected provider only covers the check; activation of a pid that does not exist
        // cannot succeed, which is the case being pinned.
        let outcome = try await ForegroundInput.performChunked(
            pid: 2_147_483_000, chunks: 3, onInterrupt: { log.interrupted() }, frontmost: { 99 }
        ) { chunk -> Int in
            log.add(chunk)
            return chunk
        }
        guard case .interrupted(_, _, let posted) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(log.chunks.isEmpty)
        XCTAssertEqual(log.interruptCount, 0, "nothing was pressed, so there is nothing to release")
    }

    func testCancellationBetweenChunksStopsAndReleasesAndFreesTheGate() async throws {
        let log = Log()
        let task = Task {
            try await ForegroundInput.performChunked(
                pid: 7, chunks: 500, onInterrupt: { log.interrupted() }, frontmost: { 7 }
            ) { chunk -> Int in
                usleep(5_000)
                log.add(chunk)
                return chunk
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled delivery must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(log.chunks.count, 500)
        XCTAssertEqual(log.interruptCount, 1)

        // The gate is shared by every foreground call: a cancelled one that kept it would
        // wedge all later foreground input.
        let next = try await ForegroundInput.performChunked(
            pid: 7, chunks: 1, onInterrupt: {}, frontmost: { 7 }
        ) { _ in 1 }
        guard case .posted = next else { return XCTFail("gate was not released after cancellation: \(next)") }
    }

    func testBackgroundChunkedDeliveryIsOneHopInOrder() async throws {
        let delivery = try await InteractionTools.deliverChunked(
            pid: 4242, foreground: false, chunks: 3,
            progress: { "\($0)" }, onInterrupt: { _ in },
            body: { target, chunk in "\(target ?? -1):\(chunk)" }
        )
        guard case .delivered(let results) = delivery else { return XCTFail("background delivery is never refused") }
        XCTAssertEqual(results, ["4242:0", "4242:1", "4242:2"])
    }

    func testInterruptionMessageSaysHowMuchWentOut() {
        let message = ForegroundInput.interruptionMessage(requested: 123, frontmost: "Mail", progress: "48 of 120 characters")
        XCTAssertTrue(message.contains("48 of 120 characters sent"), message)
        XCTAssertTrue(message.contains("'Mail' is frontmost instead"), message)
        XCTAssertTrue(message.contains("NOT sent"), message)
    }

    // MARK: - Typing chunks

    func testTextIsCutIntoBoundedChunksThatRejoinExactly() {
        let text = String(repeating: "abcdefghij", count: 7)
        let chunks = InteractionTools.typingChunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= InteractionTools.typeChunkCharacters })
        XCTAssertEqual(chunks.count, 3, "70 characters at 24 per chunk")
    }

    func testEmptyTextStillHasOneChunkSoTheFocusStepRuns() {
        XCTAssertEqual(InteractionTools.typingChunks(""), [""])
    }

    func testAGraphemeClusterIsNeverSplitAcrossChunks() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 30)
        let chunks = InteractionTools.typingChunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { chunk in chunk.allSatisfy { $0 == Character(family) } })
    }

    // MARK: - type_text focus gate

    func testKeystrokesNeedConfirmedFocusWheneverATargetWasResolved() {
        XCTAssertTrue(InteractionTools.keystrokesMayBePosted(targetResolved: false, focusConfirmed: false),
                      "no selector means the caller asked for the caret of whatever holds focus")
        XCTAssertTrue(InteractionTools.keystrokesMayBePosted(targetResolved: true, focusConfirmed: true))
        XCTAssertFalse(InteractionTools.keystrokesMayBePosted(targetResolved: true, focusConfirmed: false))
    }

    func testTheUnconfirmedFocusErrorSaysNothingWasTypedAndHowToProceed() throws {
        let text = InteractionTools.focusUnconfirmedError
        XCTAssertTrue(text.contains("NOTHING was typed"), text)
        XCTAssertTrue(text.contains("WITHOUT a selector"), text)
    }

    // MARK: - Drag plan (S6)

    func testNegativeDurationIsClampedInsteadOfTrappingTheUnsignedSleep() {
        let plan = InputSimulator.DragPlan(from: .zero, to: CGPoint(x: 50, y: 50), duration: -3)
        XCTAssertEqual(plan.steps, 10)
        XCTAssertEqual(plan.stepMicros, 0)
    }

    func testDurationIsCappedAtFiveSeconds() {
        let plan = InputSimulator.DragPlan(from: .zero, to: CGPoint(x: 50, y: 50), duration: 1e9)
        XCTAssertEqual(plan.steps, 300, "5s at ~60 events/s")
        XCTAssertEqual(Double(plan.stepMicros) * Double(plan.steps) / 1_000_000, 5, accuracy: 0.05)
    }

    func testNonFiniteDurationFallsBackToTheDefault() {
        XCTAssertEqual(InputSimulator.clampedGestureDuration(.nan), 0.3)
        XCTAssertEqual(InputSimulator.clampedGestureDuration(.infinity), 0.3)
        XCTAssertEqual(InputSimulator.clampedGestureDuration(-.infinity), 0.3)
        XCTAssertEqual(InputSimulator.clampedGestureDuration(2), 2)
    }

    func testDragChunksCoverEveryStepOnceInOrder() {
        for duration in [0.0, 0.3, 1.7, 5.0] {
            let plan = InputSimulator.DragPlan(from: .zero, to: CGPoint(x: 100, y: 0), duration: duration)
            let covered = plan.stepChunks.flatMap { Array($0) }
            XCTAssertEqual(covered, Array(1...plan.steps), "duration \(duration)")
            XCTAssertTrue(plan.stepChunks.allSatisfy { $0.count <= InputSimulator.DragPlan.stepsPerChunk })
        }
    }

    /// Posted at a process that does not exist, so no real pointer or window is touched; the
    /// point is that a negative duration used to trap in `UInt32(...)` mid-drag.
    func testDragWithANegativeDurationCompletes() {
        InputSimulator.drag(from: .zero, to: CGPoint(x: 10, y: 10), duration: -5, pid: 2_147_483_000)
    }
}
