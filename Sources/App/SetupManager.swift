import Foundation

struct SetupManager {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentcontroller")
    static let portFile = baseDir.appendingPathComponent("mcp-port")
    static let tokenFile = baseDir.appendingPathComponent("mcp-token")
    static let bridgeScript = baseDir.appendingPathComponent("agentcontroller-mcp-bridge.sh")
    /// Where build.sh installs the compiled CLI, which also carries the `mcp` stdio bridge.
    static let cliBinary = baseDir.appendingPathComponent("bin/agentcontroller")
    /// The Claude Code kit (installer, rule block, focus-guard hook, skill) and the iOS MCP
    /// server, both installed from the app bundle so a DMG install has everything.
    static let kitDir = baseDir.appendingPathComponent("claude")
    static let iosServerDir = baseDir.appendingPathComponent("ios-server")
    /// What the Connect card copies: one command that wires Claude Code up completely.
    static var claudeSetupCommand: String { "\(cliBinary.path) install-claude" }

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
        // Before mcpLaunch is resolved: it probes this binary.
        installBundledCLI()
        // Resolve which bridge to advertise now, off the main thread, so the first look at the
        // status window does not pay for launching the CLI probe. The kit and the iOS server
        // (35 MB, thousands of files) are copied there too, only when the bundle's differ.
        DispatchQueue.global(qos: .utility).async {
            _ = mcpLaunch
            installBundledKit()
            installBundledIOSServer()
        }
    }

    private static var bundleContents: URL { Bundle.main.bundleURL.appendingPathComponent("Contents") }

    /// The CLI is also the live stdio bridge of every open Claude session, so it is replaced by
    /// rename, never rewritten in place: a running Mach-O overwritten in place loses its code
    /// signature and the kernel kills it on the next page-in.
    private static func installBundledCLI() {
        let bundled = bundleContents.appendingPathComponent("Helpers/agentcontroller")
        guard let data = try? Data(contentsOf: bundled) else { return }
        if (try? Data(contentsOf: cliBinary)) == data { return }
        let staged = cliBinary.deletingLastPathComponent().appendingPathComponent(".agentcontroller.new")
        try? FileManager.default.createDirectory(at: cliBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: staged)
        guard (try? FileManager.default.copyItem(at: bundled, to: staged)) != nil else { return }
        chmod(staged, 0o755)
        _ = Darwin.rename(staged.path, cliBinary.path)
    }

    /// Small text files; refreshed whenever any of them differs from the bundle's.
    private static func installBundledKit() {
        let bundled = bundleContents.appendingPathComponent("Resources/claude")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return }
        replaceDirectory(kitDir, with: bundled, unlessSame: "install.sh", "CLAUDE-block.md", "focus-guard.py", "skills/agentcontroller/SKILL.md")
    }

    /// Copied only when the build stamp differs: open sessions keep running the old copy's
    /// files until they restart, and the swap by rename never leaves a half-written tree.
    private static func installBundledIOSServer() {
        let bundled = bundleContents.appendingPathComponent("Resources/ios-server")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return }
        replaceDirectory(iosServerDir, with: bundled, unlessSame: ".bundle-stamp")
    }

    private static func replaceDirectory(_ target: URL, with source: URL, unlessSame markers: String...) {
        let fm = FileManager.default
        let same = markers.allSatisfy { marker in
            let a = try? Data(contentsOf: source.appendingPathComponent(marker))
            let b = try? Data(contentsOf: target.appendingPathComponent(marker))
            return a != nil && a == b
        }
        guard !same else { return }
        let staged = baseDir.appendingPathComponent(".\(target.lastPathComponent).new")
        let old = baseDir.appendingPathComponent(".\(target.lastPathComponent).old")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        guard (try? fm.copyItem(at: source, to: staged)) != nil else { return }
        if fm.fileExists(atPath: target.path) { _ = Darwin.rename(target.path, old.path) }
        _ = Darwin.rename(staged.path, target.path)
        try? fm.removeItem(at: old)
        chmod(target, 0o700)
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
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Re-read per request (builtins, no fork): the token rotates whenever the
            # server's listener is rebuilt, and a value read once would 401 forever after.
            read -r PORT < "$PORT_FILE"; read -r TOKEN < "$TOKEN_FILE"
            # Digits only: "80@attacker.example" would make attacker.example the host.
            case "$PORT" in ''|*[!0-9]*) continue ;; esac
            # Token via a piped curl config, never argv, where `ps` shows it to every user.
            resp=$(printf '%s' "$line" | curl -s -o - -w '\\n%{http_code}' --max-time 180 \
                -K <(printf 'header = "Authorization: Bearer %s"\\n' "$TOKEN") \
                -X POST "http://127.0.0.1:${PORT}/mcp" \
                -H "Content-Type: application/json" \
                -H "X-AC-Client: bash-$$" -H 'Expect:' --data-binary @- 2>/dev/null)
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
