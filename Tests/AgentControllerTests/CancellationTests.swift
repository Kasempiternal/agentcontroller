import XCTest
import ApplicationServices
import MCPServer
@testable import AccessibilityEngine
@testable import MCPTools

/// `AXExecutor.pause` used to swallow the cancellation it was woken by, so after a client
/// cancelled a call every later pause returned instantly and the poll loop around it spun a
/// core on AX walks (112,454 iterations/s measured) until its own deadline — still posting
/// real scroll events on the way. Each test cancels a loop whose deadline is far away and
/// requires it to end promptly with `CancellationError`.
final class CancellationTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult func bump() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
        var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// How `task` ended, or nil if it was still running after `seconds`. The failure under
    /// test is a loop that does not end, so the wait itself must be bounded.
    private func settled<T: Sendable>(_ task: Task<T, Error>, within seconds: TimeInterval) async -> Result<T, Error>? {
        let box = Box<Result<T, Error>>()
        let done = expectation(description: "task settled")
        Task {
            box.set(await task.result)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: seconds)
        return box.value
    }

    private func assertCancelled<T>(_ result: Result<T, Error>?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case nil: XCTFail("\(what) was still running 3s after being cancelled", file: file, line: line)
        case .success?: XCTFail("\(what) finished normally instead of throwing CancellationError", file: file, line: line)
        case .failure(let error)?: XCTAssertTrue(error is CancellationError, "\(what) threw \(error)", file: file, line: line)
        }
    }

    // MARK: - The pause itself

    func testPauseEndsWithCancellationErrorWhenTheTaskIsCancelled() async throws {
        let task = Task { try await AXExecutor.pause(30) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        assertCancelled(await settled(task, within: 3), "pause")
    }

    func testPauseOnAnAlreadyCancelledTaskThrowsInsteadOfReturningInstantly() async {
        let task = Task { () -> Void in
            while !Task.isCancelled { await Task.yield() }
            try await AXExecutor.pause(30)
        }
        task.cancel()
        assertCancelled(await settled(task, within: 3), "pause")
    }

    func testAnAbsurdIntervalDoesNotTrapTheNanosecondConversion() async {
        let task = Task { try await AXExecutor.pause(1e300) }
        task.cancel()
        assertCancelled(await settled(task, within: 3), "pause(1e300)")
    }

    // MARK: - The loops built on it

    func testWaitUntilFrontmostStopsPollingOnceCancelled() async throws {
        let polls = Counter()
        let task = Task {
            try await ForegroundInput.waitUntilFrontmost(pid: 7, deadline: 30, pollInterval: 0.02) {
                polls.bump()
                return 99
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        assertCancelled(await settled(task, within: 3), "waitUntilFrontmost")
        let atCancel = polls.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(polls.count, atCancel, "the loop kept polling after it was cancelled")
        XCTAssertLessThan(atCancel, 40, "a 20ms poll for 0.2s is about 10 polls, not a busy loop")
    }

    func testResolveTargetStopsRetryingTheSelectorSearchOnceCancelled() async throws {
        let deadPID: pid_t = 2_147_483_000
        let args: JSONValue = .object(["role": .string("AXButton"), "title": .string("No Such Button \(UUID().uuidString)")])
        let task = Task { try await InteractionTools.resolveTarget(pid: deadPID, args: args, timeout: 30) }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        assertCancelled(await settled(task, within: 3), "resolveTarget")
    }

    func testVerifyWriteStopsPollingOnceCancelled() async throws {
        let deadPID: pid_t = 2_147_483_000
        let element = AXElement.application(pid: deadPID, timeout: 0.5)
        let task = Task { try await InteractionTools.verifyWrite(pid: deadPID, element: element, text: "x", append: false) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        assertCancelled(await settled(task, within: 3), "verifyWrite")
    }

    func testWaitUntilQuitPollingStopsOnceCancelled() async throws {
        let task = Task { try await AppTools.waitUntil(timeout: 30, interval: 0.02) { false } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        assertCancelled(await settled(task, within: 3), "waitUntil")
    }

    // MARK: - ProcessRunner on a task that is already cancelled

    /// `withTaskCancellationHandler` runs `onCancel` BEFORE the body when the task is already
    /// cancelled: the run was finished with no continuation to resume, then `start` stored its
    /// continuation and launched the child, and nothing ever resumed it.
    func testProcessRunnerOnAnAlreadyCancelledTaskEndsWithCancellationAndLaunchesNothing() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ac-cancelled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task { () -> ProcessRunner.Output in
            while !Task.isCancelled { await Task.yield() }
            return try await ProcessRunner.run(executable: "/usr/bin/touch", arguments: [marker.path], timeout: 30)
        }
        task.cancel()
        assertCancelled(await settled(task, within: 3), "ProcessRunner.run")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the child was launched for a request that was already cancelled")
    }

    func testProcessRunnerCancelledMidRunReturnsPromptly() async throws {
        let task = Task { try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 60) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        assertCancelled(await settled(task, within: 3), "ProcessRunner.run")
    }
}
