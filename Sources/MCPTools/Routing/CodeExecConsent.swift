import Foundation
import MCPServer

/// Persisted opt-in for `run_app_code`. Arbitrary Python/JS inside the user's
/// apps is RCE; we ask once per backend kind and remember the answer.
public struct CodeExecConsent: Sendable {
    public static let shared = CodeExecConsent()

    public func fileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["AGENTCONTROLLER_CONSENT_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentController/code-exec-consent.json")
    }

    public func isGranted(_ backend: String) -> Bool {
        granted().contains(backend)
    }

    public func grant(_ backend: String) {
        var set = granted()
        set.insert(backend)
        write(set)
    }

    public func granted() -> Set<String> {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let list = json["granted"]?.arrayValue else {
            return []
        }
        return Set(list.compactMap { $0.stringValue })
    }

    private func write(_ set: Set<String>) {
        let url = fileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = JSONValue.object([
            "granted": .array(set.sorted().map { .string($0) }),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
