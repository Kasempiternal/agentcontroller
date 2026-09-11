import Foundation
import MCPServer

enum IOSSimBackend {
    static func listBooted() -> [JSONValue] {
        guard let data = try? run(launchPath: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "booted", "-j"]) else {
            return []
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        var devices: [JSONValue] = []
        if let runtimes = json["devices"]?.objectValue {
            for (runtime, list) in runtimes {
                guard let items = list.arrayValue else { continue }
                for item in items {
                    var fields = item.objectValue ?? [:]
                    fields["runtime"] = .string(runtime)
                    devices.append(.object(fields))
                }
            }
        }
        return devices
    }

    static func resolveUDID(_ requested: String) -> (udid: String, ask: CapabilityRecord.Ask?, detail: String?) {
        let booted = listBooted()
        let ids = booted.compactMap { $0["udid"]?.stringValue }
        if requested.lowercased() == "booted" {
            if ids.count == 1 { return (ids[0], nil, nil) }
            if ids.isEmpty {
                return ("booted", .missingAddon, "No booted iOS simulator. Boot one with xcrun simctl boot, or run the iOS MCP setup.")
            }
            return ("booted", .multiInstance, "Multiple booted simulators; pass a UDID.")
        }
        if ids.contains(requested) { return (requested, nil, nil) }
        if booted.isEmpty {
            return (requested, .missingAddon, "Simulator \(requested) is not booted (or xcrun simctl is unavailable).")
        }
        return (requested, nil, nil)
    }

    static func idbBinary() -> String? {
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
        return which("idb")
    }

    static func snapshot(udid: String) throws -> [RoutedRef] {
        guard let idb = idbBinary() else {
            throw ToolError.actionFailed("idb is not installed. Run the AgentController iOS setup (`agentcontroller-ios --setup`) so simulator UI can be driven from this MCP.")
        }
        let data = try run(launchPath: idb, arguments: ["--udid", udid, "ui", "describe-all"])
        return parseDescribeAll(udid: udid, data: data)
    }

    static func tap(ref: RoutedRef) throws {
        guard case .ios(let udid, _, let x, let y, let w, let h) = ref else {
            throw ToolError.actionFailed("Not an iOS element")
        }
        guard let idb = idbBinary() else {
            throw ToolError.actionFailed("idb is not installed")
        }
        let cx = x + w / 2
        let cy = y + h / 2
        _ = try run(launchPath: idb, arguments: ["--udid", udid, "ui", "tap", String(cx), String(cy)])
    }

    static func typeText(udid: String, text: String) throws {
        guard let idb = idbBinary() else {
            throw ToolError.actionFailed("idb is not installed")
        }
        _ = try run(launchPath: idb, arguments: ["--udid", udid, "ui", "text", text])
    }

    static func parseDescribeAll(udid: String, data: Data) -> [RoutedRef] {
        let text = String(data: data, encoding: .utf8) ?? ""
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return flattenJSON(udid: udid, value: json)
        }
        var refs: [RoutedRef] = []
        let pattern = #"\{[^}]*AXUniqueId['\"]?\s*[:=]\s*['\"]([^'\"]+)['\"][^}]*\}"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if match.numberOfRanges > 1 {
                    let uid = ns.substring(with: match.range(at: 1))
                    refs.append(.ios(udid: udid, uid: uid, x: 0, y: 0, width: 0, height: 0))
                }
            }
        }
        return refs
    }

    private static func flattenJSON(udid: String, value: JSONValue) -> [RoutedRef] {
        var out: [RoutedRef] = []
        func walk(_ node: JSONValue) {
            if let obj = node.objectValue {
                let uid = obj["AXUniqueId"]?.stringValue
                    ?? obj["uid"]?.stringValue
                    ?? obj["identifier"]?.stringValue
                    ?? UUID().uuidString
                let frame = obj["frame"] ?? obj["AXFrame"]
                let x = frame?["x"]?.doubleValue ?? obj["x"]?.doubleValue ?? 0
                let y = frame?["y"]?.doubleValue ?? obj["y"]?.doubleValue ?? 0
                let w = frame?["width"]?.doubleValue ?? frame?["w"]?.doubleValue ?? 0
                let h = frame?["height"]?.doubleValue ?? frame?["h"]?.doubleValue ?? 0
                let role = obj["type"]?.stringValue ?? obj["role"]?.stringValue ?? ""
                let interactive = ["Button", "TextField", "Cell", "Switch", "Link", "AXButton", "AXTextField"].contains(role)
                    || obj["enabled"]?.boolValue == true
                if interactive || obj["label"] != nil {
                    out.append(.ios(udid: udid, uid: uid, x: x, y: y, width: w, height: h))
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

    @discardableResult
    static func run(launchPath: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw ToolError.timedOut("idb/simctl \(arguments.first ?? "")")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 && data.isEmpty {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError.actionFailed(stderr.isEmpty ? "idb failed" : stderr)
        }
        return data
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }
}
