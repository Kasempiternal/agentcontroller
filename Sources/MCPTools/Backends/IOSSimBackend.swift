import Foundation
import MCPServer

/// idb-driven simulator access. An actor only for its caches (the booted-simulator list
/// and the idb path); every subprocess goes through `ProcessRunner`, so nothing here
/// blocks a thread or can deadlock on a full pipe.
actor IOSSimBackend {
    static let shared = IOSSimBackend()

    /// `simctl` costs ~100ms per call and the booted set changes on a human timescale.
    static let cacheLifetime: TimeInterval = 30

    struct Resolution: Equatable {
        var udid: String
        var ask: CapabilityRecord.Ask?
        var detail: String?

        init(udid: String, ask: CapabilityRecord.Ask? = nil, detail: String? = nil) {
            self.udid = udid
            self.ask = ask
            self.detail = detail
        }
    }

    private var booted: (at: Date, udids: [String])?
    private var cachedIDB: String?

    /// Called on any failure: a simulator that was shut down or crashed would otherwise
    /// keep resolving as booted for the rest of the cache window.
    func invalidate() {
        booted = nil
    }

    func bootedUDIDs() async -> [String] {
        if let booted, Date().timeIntervalSince(booted.at) < Self.cacheLifetime { return booted.udids }
        guard let out = try? await ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "booted", "-j"],
            timeout: 10
        ), out.status == 0 else { return [] }
        let udids = Self.parseBooted(out.stdout)
        booted = (Date(), udids)
        return udids
    }

    func resolveUDID(_ requested: String) async -> Resolution {
        Self.resolve(requested: requested, booted: await bootedUDIDs())
    }

    static func parseBooted(_ data: Data) -> [String] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let runtimes = json["devices"]?.objectValue else { return [] }
        return runtimes.values
            .compactMap(\.arrayValue)
            .flatMap { $0 }
            .filter { $0["state"]?.stringValue == "Booted" || $0["state"] == nil }
            .compactMap { $0["udid"]?.stringValue }
            .sorted()
    }

    /// "booted" resolves to the one booted simulator's real UDID — idb has no such alias
    /// and rejects it ("no matching target in available udids"). A concrete UDID that is
    /// not among the booted ones is reported as not booted instead of being passed on to
    /// fail inside idb.
    static func resolve(requested: String, booted udids: [String]) -> Resolution {
        if requested.lowercased() == "booted" {
            if udids.count == 1 { return Resolution(udid: udids[0]) }
            if udids.isEmpty {
                return Resolution(udid: "booted", ask: .missingAddon, detail: "No booted iOS simulator. Boot one with xcrun simctl boot, or run the iOS MCP setup.")
            }
            return Resolution(udid: "booted", ask: .multiInstance, detail: "Multiple booted simulators (\(udids.joined(separator: ", "))); pass a UDID.")
        }
        if let match = udids.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            return Resolution(udid: match)
        }
        let state = udids.isEmpty ? "No simulator is booted." : "Booted: \(udids.joined(separator: ", "))."
        return Resolution(
            udid: requested,
            ask: .missingAddon,
            detail: "Simulator \(requested) is not booted (or xcrun simctl is unavailable). \(state)"
        )
    }

    // MARK: - idb

    func idbBinary() async -> String? {
        if let cachedIDB, FileManager.default.isExecutableFile(atPath: cachedIDB) { return cachedIDB }
        cachedIDB = await Self.locateIDB()
        return cachedIDB
    }

    private static func locateIDB() async -> String? {
        if let override = ProcessInfo.processInfo.environment["AGENTCONTROLLER_IDB"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.agentcontroller/ios/idb-companion/bin/idb",
            "\(home)/.agentcontroller/ios/venv/bin/idb",
            "/opt/homebrew/bin/idb",
            "/usr/local/bin/idb",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        guard let out = try? await ProcessRunner.run(executable: "/usr/bin/which", arguments: ["idb"], timeout: 3),
              out.status == 0 else { return nil }
        let path = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // `--udid` is an option of each idb subcommand, not of idb itself: `idb --udid X ui …`
    // is an argparse error (exit 2), so the whole backend failed against a real idb.
    static func describeArguments(udid: String) -> [String] {
        ["ui", "describe-all", "--udid", udid, "--json"]
    }

    /// idb parses coordinates as ints — a Double's "201.0" is rejected.
    static func tapArguments(udid: String, x: Double, y: Double) -> [String] {
        ["ui", "tap", "--udid", udid, String(Int(x.rounded())), String(Int(y.rounded()))]
    }

    /// `--` ends option parsing, so text that starts with "-" is typed, not parsed.
    static func textArguments(udid: String, text: String) -> [String] {
        ["ui", "text", "--udid", udid, "--", text]
    }

    static func center(of ref: RoutedRef) -> (x: Double, y: Double)? {
        guard case .ios(_, _, _, _, let x, let y, let w, let h) = ref else { return nil }
        return (x + w / 2, y + h / 2)
    }

    func snapshot(udid: String) async throws -> [RoutedRef] {
        let data = try await idb(Self.describeArguments(udid: udid), timeout: 20)
        return try Self.parseDescribeAll(udid: udid, data: data)
    }

    func tap(ref: RoutedRef) async throws {
        guard case .ios(let udid, _, _, _, _, _, _, _) = ref, let point = Self.center(of: ref) else {
            throw ToolError.actionFailed("Not an iOS element")
        }
        _ = try await idb(Self.tapArguments(udid: udid, x: point.x, y: point.y))
    }

    /// idb types into whatever has keyboard focus, so a typed-into element is tapped first —
    /// otherwise the text goes to the previously focused field or nowhere.
    func typeText(ref: RoutedRef, text: String) async throws {
        guard case .ios(let udid, _, _, _, _, _, _, _) = ref else {
            throw ToolError.actionFailed("Not an iOS element")
        }
        try await tap(ref: ref)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await idb(Self.textArguments(udid: udid, text: text))
    }

    @discardableResult
    private func idb(_ arguments: [String], timeout: TimeInterval = 15) async throws -> Data {
        guard let binary = await idbBinary() else {
            throw ToolError.actionFailed("idb is not installed. Run the AgentController iOS setup (`agentcontroller-ios --setup`) so simulator UI can be driven from this MCP.")
        }
        do {
            let out = try await ProcessRunner.run(executable: binary, arguments: arguments, timeout: timeout)
            guard out.status == 0 else {
                let detail = out.stderrString.isEmpty ? out.stdoutString : out.stderrString
                throw ToolError.actionFailed("idb \(arguments.prefix(2).joined(separator: " ")) failed: \(String(detail.suffix(400)))")
            }
            return out.stdout
        } catch {
            invalidate()
            throw error
        }
    }

    // MARK: - Parsing

    /// `idb ui describe-all --json` is a flat array of
    /// {type, role, AXLabel, AXUniqueId, AXValue, enabled, frame:{x,y,width,height}}.
    /// `--nested` output (children arrays) is walked too.
    static func parseDescribeAll(udid: String, data: Data) throws -> [RoutedRef] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ToolError.actionFailed("idb returned output that is not JSON: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return flatten(udid: udid, value: json)
    }

    private static let interactiveTypes: Set<String> = [
        "Button", "TextField", "SecureTextField", "TextView", "SearchField", "Switch", "Toggle",
        "Slider", "Link", "Cell", "Tab", "Stepper", "Picker", "PickerWheel", "MenuItem", "Key",
        "CheckBox", "RadioButton",
    ]

    private static func flatten(udid: String, value: JSONValue) -> [RoutedRef] {
        var out: [RoutedRef] = []
        func walk(_ node: JSONValue) {
            if let obj = node.objectValue {
                let identifier = obj["AXUniqueId"]?.stringValue ?? obj["identifier"]?.stringValue ?? ""
                let label = [obj["AXLabel"], obj["label"], obj["title"], obj["AXValue"]]
                    .compactMap { $0?.stringValue }
                    .first { !$0.isEmpty } ?? ""
                let rawType = obj["type"]?.stringValue ?? obj["role"]?.stringValue ?? "element"
                let type = rawType.hasPrefix("AX") ? String(rawType.dropFirst(2)) : rawType
                let frame = obj["frame"]
                let x = frame?["x"]?.doubleValue ?? obj["x"]?.doubleValue ?? 0
                let y = frame?["y"]?.doubleValue ?? obj["y"]?.doubleValue ?? 0
                let w = frame?["width"]?.doubleValue ?? obj["width"]?.doubleValue ?? 0
                let h = frame?["height"]?.doubleValue ?? obj["height"]?.doubleValue ?? 0
                // Structural wrappers (no label, no id, not a control) are the bulk of a
                // screen's nodes and carry nothing an agent can act on or assert.
                if interactiveTypes.contains(type) || !label.isEmpty || !identifier.isEmpty {
                    out.append(.ios(udid: udid, identifier: identifier, role: type, label: label, x: x, y: y, width: w, height: h))
                }
                if let children = obj["children"]?.arrayValue {
                    children.forEach(walk)
                }
            } else if let array = node.arrayValue {
                array.forEach(walk)
            }
        }
        walk(value)
        return out
    }
}
