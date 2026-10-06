import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation

public struct RecordingResult: Sendable {
    public let path: String
    public let seconds: Double
    /// Set when AgentController ended the recording itself (time limit, app quit) rather
    /// than a `stop_recording` call; the agent still collects the file via `stop_recording`.
    public let autoStopReason: String?
}

/// Bounds for one recording. A recording nobody stops grows until the disk is full, so
/// there is always a limit; the agent may shorten or lengthen it, within the ceiling.
public enum RecordingLimit {
    public static let defaultSeconds: TimeInterval = 600
    public static let ceilingSeconds: TimeInterval = 3600

    public static func seconds(requested: Double?) -> TimeInterval {
        guard let requested, requested.isFinite else { return defaultSeconds }
        return min(max(requested, 1), ceilingSeconds)
    }
}

/// One-shot latch that `wait` can block on with a timeout. `SCRecordingOutputDelegate`
/// callbacks arrive on an SCK-owned queue at an unspecified moment after `stopCapture`
/// returns, so the signal may land before or after the waiter arrives, and the timeout
/// may race the signal: whichever comes first resumes the waiter, exactly once. One
/// waiter at a time; the latch never resets.
final class FinishSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: true)
    }

    /// True if signaled before `timeout` elapsed.
    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiter = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let pending = waiter
                waiter = nil
                lock.unlock()
                pending?.resume(returning: false)
            }
        }
    }
}

/// One-at-a-time window video recorder built on SCRecordingOutput (macOS 15+).
/// `start` wires an SCStream straight to a .mov on disk (no SCStreamOutput / asset-writer
/// plumbing needed); `stop` finalizes the file and reports its path + duration. Used by
/// the start_recording / stop_recording tools so a QA flow can leave visual evidence.
@available(macOS 15.0, *)
public actor WindowRecorder {
    public static let shared = WindowRecorder()

    typealias Outcome = Result<RecordingResult, Error>

    /// An actor suspends at every `await`, so two `start` calls can interleave. `.starting`
    /// is set before the first one so the second sees it and refuses, instead of both
    /// passing the guard and the later stream overwriting the earlier (which then records
    /// forever with nothing holding a handle to stop it).
    private enum State {
        case idle
        case starting
        case recording(Session)
        /// Finalizing. A second `stop` (or the quit hook) joins this task rather than
        /// stopping the same stream twice.
        case stopping(Task<Outcome, Never>)
    }

    private struct Session {
        let id = UUID()
        let stream: SCStream
        let output: SCRecordingOutput
        let delegate: RecorderDelegate
        let url: URL
        let startedAt: Date
        var limit: Task<Void, Never>?
    }

    private var state = State.idle
    /// Outcome of a recording that ended without a `stop_recording` call, kept until the
    /// agent collects it.
    private var unclaimed: Outcome?

    private init() {}

    /// `~/Library/Application Support/AgentController/recordings`
    public static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentController/recordings", isDirectory: true)
    }

    public func isRecording() -> Bool {
        if case .recording = state { return true }
        return false
    }

    @discardableResult
    public func start(
        pid: pid_t,
        windowTitle: String?,
        windowOrigin: CGPoint? = nil,
        maxSeconds: Double? = nil
    ) async throws -> URL {
        switch state {
        case .idle: break
        case .starting: throw RecorderError.startInProgress
        case .recording(let session): throw RecorderError.alreadyRecording(session.url.path)
        case .stopping: throw RecorderError.stillStopping
        }
        state = .starting
        unclaimed = nil

        do {
            var session = try await ShareableContentCache.shared.withContent { content, isFresh in
                let window = try WindowCapturer.resolveWindow(
                    in: content, isFresh: isFresh, pid: pid, windowTitle: windowTitle, windowOrigin: windowOrigin
                )
                return try await Self.beginSession(window: window)
            }
            let limit = RecordingLimit.seconds(requested: maxSeconds)
            let id = session.id
            session.limit = Task {
                do { try await Task.sleep(for: .seconds(limit)) } catch { return }
                await self.stopIfCurrent(id, reason: "reached the \(Int(limit))s recording limit")
            }
            state = .recording(session)
            return session.url
        } catch {
            state = .idle
            throw error
        }
    }

    public func stop() async throws -> RecordingResult {
        let outcome: Outcome
        switch state {
        case .starting:
            throw RecorderError.startInProgress
        case .recording(let session):
            outcome = await beginStopping(session, reason: nil).value
        case .stopping(let task):
            outcome = await task.value
        case .idle:
            guard let kept = unclaimed else { throw RecorderError.notRecording }
            outcome = kept
        }
        unclaimed = nil
        return try outcome.get()
    }

    /// Quit hook: finalize a live recording so its .mov has a moov atom. Without it a
    /// recording still running at app quit is left unplayable on disk.
    func stopForTermination() async {
        switch state {
        case .recording(let session): _ = await beginStopping(session, reason: "AgentController quit").value
        case .stopping(let task): _ = await task.value
        case .idle, .starting: break
        }
    }

    private func stopIfCurrent(_ id: UUID, reason: String) async {
        guard case .recording(let session) = state, session.id == id else { return }
        _ = await beginStopping(session, reason: reason).value
    }

    /// Finalizes on a task so every caller (initiator, a concurrent `stop`, the quit
    /// hook) awaits the same work. The task body records the outcome and returns to
    /// `.idle` with no `await` between, so anyone resuming from it sees both.
    private func beginStopping(_ session: Session, reason: String?) -> Task<Outcome, Never> {
        let task = Task {
            let outcome = await self.finalize(session, autoStopReason: reason)
            self.unclaimed = outcome
            self.state = .idle
            return outcome
        }
        state = .stopping(task)
        return task
    }

    private func finalize(_ session: Session, autoStopReason: String?) async -> Outcome {
        session.limit?.cancel()
        // The stream may already be dead (window closed mid-recording) — the recording
        // output still finalizes the file, so a stop error is not fatal here.
        try? await session.stream.stopCapture()
        let finalized = await session.delegate.finished.wait(timeout: Self.finalizeTimeout)
        let seconds = Date().timeIntervalSince(session.startedAt)

        if let error = session.delegate.takeError() {
            return .failure(RecorderError.recordingFailed(error.localizedDescription))
        }
        guard FileManager.default.fileExists(atPath: session.url.path) else {
            return .failure(RecorderError.recordingFailed("No file was written at \(session.url.path)"))
        }
        guard finalized else {
            return .failure(RecorderError.recordingFailed(
                "The recording did not finish writing within \(Int(Self.finalizeTimeout))s; \(session.url.path) may be unplayable"
            ))
        }
        return .success(RecordingResult(path: session.url.path, seconds: seconds, autoStopReason: autoStopReason))
    }

    private static let finalizeTimeout: TimeInterval = 5

    private static func beginSession(window: SCWindow) async throws -> Session {
        let dir = recordingsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("rec-\(stampFormatter.string(from: Date())).mov")

        let filter = SCContentFilter(desktopIndependentWindow: window)
        // The display's own scale, held to what H.264 can encode: a window spanning a 5K
        // display is 5120x2880 at 2x, past the 4096x2304 the encoder accepts.
        let size = CaptureSizing.pixelSize(
            points: window.frame.size,
            backingScale: CGFloat(filter.pointPixelScale),
            maxLongestSide: CaptureSizing.h264MaxLongestSide,
            maxPixelCount: CaptureSizing.h264MaxPixelCount
        )
        let config = SCStreamConfiguration()
        config.scalesToFit = true
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mov
        recConfig.videoCodecType = .h264

        // Per-recording delegate: its finish signal belongs to this file alone.
        let delegate = RecorderDelegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = SCRecordingOutput(configuration: recConfig, delegate: delegate)
        try stream.addRecordingOutput(output)
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.classify(error)
        }
        return Session(stream: stream, output: output, delegate: delegate, url: url, startedAt: Date())
    }
}

/// Callable from AppDelegate on any supported macOS: `WindowRecorder` itself is
/// macOS 15+, and a call site would otherwise need its own availability check.
public enum RecordingShutdown {
    /// Blocks (bounded) until a live recording is finalized. `applicationWillTerminate`
    /// is synchronous and the process exits as soon as it returns, so a fire-and-forget
    /// `Task` would never get to write the moov atom.
    public static func finalizeActiveRecording(timeout: TimeInterval = 3) {
        guard #available(macOS 15.0, *) else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await WindowRecorder.shared.stopForTermination()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }
}

/// Captures async recording failures (disk full, window destroyed) so `stop` can
/// surface them instead of returning a broken file silently, and signals when the
/// file is finished (or has failed, which ends the wait just as well).
@available(macOS 15.0, *)
private final class RecorderDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    let finished = FinishSignal()
    private let lock = NSLock()
    private var error: Error?

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished.signal()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
        finished.signal()
    }

    func takeError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        defer { error = nil }
        return error
    }
}

public enum RecorderError: Error, LocalizedError {
    case alreadyRecording(String)
    case startInProgress
    case stillStopping
    case notRecording
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording(let path):
            return "A recording is already in progress (\(path)). Call stop_recording first."
        case .startInProgress:
            return "A recording is still starting. Wait for start_recording to return, then call stop_recording."
        case .stillStopping:
            return "The previous recording is still being finalized. Call stop_recording to collect it, then start again."
        case .notRecording:
            return "No recording in progress. Call start_recording first."
        case .recordingFailed(let reason):
            return "Recording failed: \(reason)"
        }
    }
}
