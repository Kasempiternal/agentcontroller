import Foundation
import ScreenCaptureKit
import AVFoundation

/// One-at-a-time window video recorder built on SCRecordingOutput (macOS 15+).
/// `start` wires an SCStream straight to a .mov on disk (no SCStreamOutput / asset-writer
/// plumbing needed); `stop` finalizes the file and reports its path + duration. Used by
/// the start_recording / stop_recording tools so a QA flow can leave visual evidence.
@available(macOS 15.0, *)
public actor WindowRecorder {
    public static let shared = WindowRecorder()

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var fileURL: URL?
    private var startedAt: Date?
    private let delegate = RecorderDelegate()

    private init() {}

    /// `~/Library/Application Support/AgentController/recordings`
    public static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentController/recordings", isDirectory: true)
    }

    public func isRecording() -> Bool { stream != nil }

    @discardableResult
    public func start(pid: pid_t, windowTitle: String?) async throws -> URL {
        if let fileURL, stream != nil {
            throw RecorderError.alreadyRecording(fileURL.path)
        }

        let content = try await ShareableContentCache.shared.current()
        let owned = content.windows.filter { $0.owningApplication?.processID == pid }
        let window: SCWindow?
        if let windowTitle, !windowTitle.isEmpty {
            window = owned.first { $0.title == windowTitle }
        } else {
            window = WindowCapturer.bestWindow(in: owned)
        }
        guard let window else { throw CaptureError.windowNotFound }

        let dir = Self.recordingsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("rec-\(stampFormatter.string(from: Date())).mov")

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale: CGFloat = 2.0
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mov
        recConfig.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = SCRecordingOutput(configuration: recConfig, delegate: delegate)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = output
        self.fileURL = url
        self.startedAt = Date()
        return url
    }

    public func stop() async throws -> (path: String, seconds: Double) {
        guard let stream, let url = fileURL else { throw RecorderError.notRecording }
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        // The stream may already be dead (window closed mid-recording) — the recording
        // output still finalizes the file, so a stop error is not fatal here.
        try? await stream.stopCapture()
        // Give the container a beat to write its moov atom before handing the path out.
        try? await Task.sleep(for: .milliseconds(300))

        self.stream = nil
        self.recordingOutput = nil
        self.fileURL = nil
        self.startedAt = nil

        if let error = delegate.takeError() {
            throw RecorderError.recordingFailed(error.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecorderError.recordingFailed("No file was written at \(url.path)")
        }
        return (url.path, seconds)
    }
}

/// Captures async recording failures (disk full, window destroyed) so `stop` can
/// surface them instead of returning a broken file silently.
@available(macOS 15.0, *)
private final class RecorderDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock(); defer { lock.unlock() }
        self.error = error
    }

    func takeError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        defer { error = nil }
        return error
    }
}

public enum RecorderError: Error, LocalizedError {
    case alreadyRecording(String)
    case notRecording
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording(let path):
            return "A recording is already in progress (\(path)). Call stop_recording first."
        case .notRecording:
            return "No recording in progress. Call start_recording first."
        case .recordingFailed(let reason):
            return "Recording failed: \(reason)"
        }
    }
}
