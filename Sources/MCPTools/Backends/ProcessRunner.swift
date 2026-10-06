import Foundation

/// Runs a subprocess to completion without parking a cooperative-pool thread on it.
///
/// A pipe holds 64 KiB. A child that writes more blocks until somebody reads, so the old
/// "poll `isRunning`, then `readDataToEndOfFile`" shape deadlocked on any output past that
/// (measured: `idb ui describe-all` on a screen with ~170 elements always timed out).
/// Both pipes are drained while the child runs, and the result is delivered exactly once —
/// on exit with both pipes at EOF, on exit plus a short grace (a daemon the child spawned
/// may inherit the write end and hold the pipe open for ever), on timeout, or on cancel.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    enum Failure: Error, LocalizedError {
        case timedOut(String, TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timedOut(let what, let seconds): return "\(what) did not finish within \(Int(seconds))s"
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 12,
        graceAfterExit: TimeInterval = 0.5
    ) async throws -> Output {
        let run = Run(
            label: URL(fileURLWithPath: executable).lastPathComponent,
            timeout: timeout,
            grace: graceAfterExit
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(executable: executable, arguments: arguments, continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }

    private final class Run: @unchecked Sendable {
        private let label: String
        private let timeout: TimeInterval
        private let grace: TimeInterval
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()

        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var stdoutEOF = false
        private var stderrEOF = false
        private var status: Int32?
        private var continuation: CheckedContinuation<Output, Error>?
        private var finished = false

        init(label: String, timeout: TimeInterval, grace: TimeInterval) {
            self.label = label
            self.timeout = timeout
            self.grace = grace
        }

        func start(executable: String, arguments: [String], continuation: CheckedContinuation<Output, Error>) {
            // One critical section from "not cancelled yet" to "the child exists", so a
            // cancel can never land in between: it either runs before this (and nothing is
            // launched) or after (and `finish` terminates the child that is now running).
            lock.lock()
            // `withTaskCancellationHandler` runs `onCancel` immediately on a task that is
            // already cancelled — BEFORE this body, so `finish` has already marked the run
            // finished with no continuation to resume. Storing ours then and launching the
            // child would leave the caller waiting on a result nothing will ever deliver.
            if finished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consume(handle.availableData, isStdout: true, handle: handle)
            }
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consume(handle.availableData, isStdout: false, handle: handle)
            }
            process.terminationHandler = { [weak self] process in
                self?.exited(status: process.terminationStatus)
            }

            let launchError: Error?
            do {
                try process.run()
                launchError = nil
            } catch {
                launchError = error
            }
            lock.unlock()
            if let launchError {
                finish(.failure(launchError))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expire()
            }
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }

        private func consume(_ chunk: Data, isStdout: Bool, handle: FileHandle) {
            lock.lock()
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if isStdout { stdoutEOF = true } else { stderrEOF = true }
            } else if isStdout {
                stdout.append(chunk)
            } else {
                stderr.append(chunk)
            }
            let complete = status != nil && stdoutEOF && stderrEOF
            lock.unlock()
            if complete { deliver() }
        }

        private func exited(status: Int32) {
            lock.lock()
            self.status = status
            let complete = stdoutEOF && stderrEOF
            lock.unlock()
            if complete {
                deliver()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
                    self?.deliver()
                }
            }
        }

        private func expire() {
            lock.lock()
            let alreadyDone = finished
            lock.unlock()
            guard !alreadyDone else { return }
            terminateHard()
            finish(.failure(Failure.timedOut(label, timeout)))
        }

        private func deliver() {
            lock.lock()
            let output = Output(status: status ?? -1, stdout: stdout, stderr: stderr)
            lock.unlock()
            finish(.success(output))
        }

        private func finish(_ result: Result<Output, Error>) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if case .failure = result { terminateHard() }
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            continuation?.resume(with: result)
        }

        /// SIGTERM first; a child that ignores it is killed 2s later so a stuck idb can't
        /// outlive the request that spawned it.
        private func terminateHard() {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                // isRunning is false once Foundation has reaped the child, so a recycled
                // pid can never be signalled here.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
