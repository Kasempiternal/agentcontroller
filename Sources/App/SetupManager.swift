import Foundation

struct SetupManager {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentcontroller")
    static let portFile = baseDir.appendingPathComponent("mcp-port")
    static let tokenFile = baseDir.appendingPathComponent("mcp-token")
    static let bridgeScript = baseDir.appendingPathComponent("agentcontroller-mcp-bridge.sh")
    /// Where build.sh installs the compiled CLI, which also carries the `mcp` stdio bridge.
    static let cliBinary = baseDir.appendingPathComponent("bin/agentcontroller")

    /// What an MCP client runs to reach this app.
    struct MCPLaunch: Equatable {
        let command: String
        let args: [String]
    }

    /// The compiled bridge (`agentcontroller mcp`) when the installed CLI has it, else the bash
    /// script — which stays installed either way as the fallback. The compiled one answers in
    /// ~1ms where the bash one forks ~15 processes per request (~40ms).
    ///
    /// Probed rather than assumed: a CLI left over from an older build.sh has no `mcp`
    /// subcommand, and a client pointed at it would fail to connect with no hint why. Resolved
    /// once, on first use.
    static let mcpLaunch: MCPLaunch = {
        if supportsMCPSubcommand(cliBinary) {
            return MCPLaunch(command: cliBinary.path, args: ["mcp"])
        }
        return MCPLaunch(command: bridgeScript.path, args: [])
    }()

    /// `mcp --check` exits 0 immediately on a CLI that has the subcommand. The deadline is not
    /// decoration: a binary that turns out to be the menu-bar app (see the product-name note in
    /// Package.swift) starts a run loop and never exits.
    private static func supportsMCPSubcommand(_ binary: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return false }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp", "--check"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        if finished.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    static func setup() {
        createDirectories()
        installBridgeScript()
        // Resolve which bridge to advertise now, off the main thread, so the first look at the
        // status window does not pay for launching the CLI probe.
        DispatchQueue.global(qos: .utility).async { _ = mcpLaunch }
    }

    static func writePort(_ port: UInt16) {
        try? String(port).write(to: portFile, atomically: true, encoding: .utf8)
        chmod(portFile, 0o600)
    }

    static func writeToken(_ token: String) {
        try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
        chmod(tokenFile, 0o600)
    }

    /// Removes the port and token files, but only while the token file still holds `token`.
    /// A second instance overwrites both; the first one quitting must not delete the files the
    /// second one's bridges are reading. Nil (this instance never published) removes nothing.
    static func removeEndpointFiles(ifOwnedBy token: String?) {
        guard let token,
              let current = try? String(contentsOf: tokenFile, encoding: .utf8),
              current.trimmingCharacters(in: .whitespacesAndNewlines) == token else { return }
        try? FileManager.default.removeItem(at: portFile)
        try? FileManager.default.removeItem(at: tokenFile)
    }

    private static func createDirectories() {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        // Least privilege: the directory holds the auth token + port; owner-only.
        chmod(baseDir, 0o700)
    }

    /// Best-effort POSIX permission set; failures are non-fatal.
    private static func chmod(_ url: URL, _ perms: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
    }

    private static func installBridgeScript() {
        // Preferred source: the canonical script bundled into the .app by build.sh
        // (Contents/Resources/agentcontroller-mcp-bridge.sh). Install it when missing and
        // refresh it when the content differs — this is how DMG installs (which
        // never run build.sh) get the bridge at all, and how app updates ship
        // bridge fixes without a manual deploy step.
        if let bundled = Bundle.main.url(forResource: "agentcontroller-mcp-bridge", withExtension: "sh"),
           let bundledData = try? Data(contentsOf: bundled) {
            let deployed = try? Data(contentsOf: bridgeScript)
            if deployed != bundledData {
                try? bundledData.write(to: bridgeScript)
            }
            chmod(bridgeScript, 0o700)
            return
        }

        // Unbundled fallback (bare `swift run` dev builds): install a minimal
        // bootstrap on first run only. It MUST send the bearer token — the server
        // rejects unauthenticated requests, so a token-less bootstrap would 401
        // on every call.
        guard !FileManager.default.fileExists(atPath: bridgeScript.path) else { return }

        let script = """
        #!/bin/bash
        PORT_FILE="$HOME/.agentcontroller/mcp-port"
        TOKEN_FILE="$HOME/.agentcontroller/mcp-token"
        while [ ! -f "$PORT_FILE" ] || [ ! -f "$TOKEN_FILE" ]; do sleep 1; done
        read -r PORT < "$PORT_FILE"
        read -r TOKEN < "$TOKEN_FILE"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            resp=$(printf '%s' "$line" | curl -s -o - -w '\\n%{http_code}' --max-time 180 \
                -X POST "http://127.0.0.1:${PORT}/mcp" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${TOKEN}" -H "X-AC-Client: bash-$$" -H 'Expect:' --data-binary @- 2>/dev/null)
            code=$(echo "$resp" | tail -1); body=$(echo "$resp" | sed '$d')
            [ "$code" = "204" ] && continue
            [ -n "$body" ] && echo "$body"
        done
        """

        try? script.write(to: bridgeScript, atomically: true, encoding: .utf8)
        // Owner-only executable: least privilege for the bridge.
        chmod(bridgeScript, 0o700)
    }
}
