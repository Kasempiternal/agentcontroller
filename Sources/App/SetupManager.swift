import Foundation

struct SetupManager {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deskestro")
    static let portFile = baseDir.appendingPathComponent("mcp-port")
    static let tokenFile = baseDir.appendingPathComponent("mcp-token")
    static let bridgeScript = baseDir.appendingPathComponent("deskestro-mcp-bridge.sh")

    static func setup() {
        createDirectories()
        installBridgeScript()
    }

    static func writePort(_ port: UInt16) {
        try? String(port).write(to: portFile, atomically: true, encoding: .utf8)
        chmod(portFile, 0o600)
    }

    static func removePort() {
        try? FileManager.default.removeItem(at: portFile)
    }

    static func writeToken(_ token: String) {
        try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
        chmod(tokenFile, 0o600)
    }

    static func removeToken() {
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
        // (Contents/Resources/deskestro-mcp-bridge.sh). Install it when missing and
        // refresh it when the content differs — this is how DMG installs (which
        // never run build.sh) get the bridge at all, and how app updates ship
        // bridge fixes without a manual deploy step.
        if let bundled = Bundle.main.url(forResource: "deskestro-mcp-bridge", withExtension: "sh"),
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
        PORT_FILE="$HOME/.deskestro/mcp-port"
        TOKEN_FILE="$HOME/.deskestro/mcp-token"
        while [ ! -f "$PORT_FILE" ] || [ ! -f "$TOKEN_FILE" ]; do sleep 1; done
        PORT=$(cat "$PORT_FILE")
        TOKEN=$(cat "$TOKEN_FILE")
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            resp=$(printf '%s' "$line" | curl -s -o - -w '\\n%{http_code}' --max-time 180 \
                -X POST "http://127.0.0.1:${PORT}/mcp" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${TOKEN}" --data-binary @- 2>/dev/null)
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
