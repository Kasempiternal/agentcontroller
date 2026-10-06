import XCTest
@testable import MCPServer

/// The stdio bridge keeps one background worker per in-flight request. On SIGTERM it must
/// kill the workers that are running NOW — not a remembered list of pids, which still holds
/// the numbers of workers that finished long ago and that the OS has since given to
/// unrelated processes.
final class BridgeScriptTests: XCTestCase {

    private var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/agentcontroller-mcp-bridge.sh")
    }

    private func pids(matching pattern: String) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]
        let out = Pipe()
        pgrep.standardOutput = out
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    func testTerminateKillsTheRunningWorkersAndExits() throws {
        let server = try SilentTCPServer()
        try server.start()
        defer { server.stop() }

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ac-bridge-\(UUID().uuidString)")
        let state = home.appendingPathComponent(".agentcontroller")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "\(server.port)".write(to: state.appendingPathComponent("mcp-port"), atomically: true, encoding: .utf8)
        try "test-token".write(to: state.appendingPathComponent("mcp-token"), atomically: true, encoding: .utf8)

        let bridge = Process()
        bridge.executableURL = URL(fileURLWithPath: "/bin/bash")
        bridge.arguments = [script.path]
        bridge.environment = ["HOME": home.path, "TMPDIR": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        bridge.standardInput = stdin
        bridge.standardOutput = FileHandle.nullDevice
        bridge.standardError = FileHandle.nullDevice
        try bridge.run()
        defer { if bridge.isRunning { kill(bridge.processIdentifier, SIGKILL) } }

        // Two requests the silent server will never answer: two workers, two curls in flight.
        for id in 1...2 {
            stdin.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"x"}}"#.utf8 + [0x0A]))
        }
        let curlPattern = "127.0.0.1:\(server.port)/mcp"
        var running: [Int32] = []
        for _ in 0..<100 where running.count < 2 {
            Thread.sleep(forTimeInterval: 0.05)
            running = pids(matching: curlPattern)
        }
        XCTAssertEqual(running.count, 2, "both requests should be in flight before the bridge is terminated")

        kill(bridge.processIdentifier, SIGTERM)
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { bridge.waitUntilExit(); exited.signal() }
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success, "the bridge did not exit on SIGTERM")
        XCTAssertEqual(bridge.terminationStatus, 143)

        var left = pids(matching: curlPattern)
        for _ in 0..<40 where !left.isEmpty {
            Thread.sleep(forTimeInterval: 0.05)
            left = pids(matching: curlPattern)
        }
        XCTAssertTrue(left.isEmpty, "in-flight curl processes outlived the bridge: \(left)")
    }
}
