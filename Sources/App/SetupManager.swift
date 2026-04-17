import Foundation

struct SetupManager {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macoestro")
    static let portFile = baseDir.appendingPathComponent("mcp-port")
    static let bridgeScript = baseDir.appendingPathComponent("macoestro-mcp-bridge.sh")

    static func setup() {
        createDirectories()
        installBridgeScript()
    }

    static func writePort(_ port: UInt16) {
        try? String(port).write(to: portFile, atomically: true, encoding: .utf8)
    }

    static func removePort() {
        try? FileManager.default.removeItem(at: portFile)
    }

    private static func createDirectories() {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    private static func installBridgeScript() {
        // Only install on first run — the deploy script (Scripts/macoestro-mcp-bridge.sh)
        // is the canonical source and is copied to ~/.macoestro/ during build-deploy.
        // Don't overwrite it on every launch or we'll destroy the deployed version.
        guard !FileManager.default.fileExists(atPath: bridgeScript.path) else { return }

        // Minimal bootstrap for first-run (before the user has deployed via the build script)
        let script = """
        #!/bin/bash
        PORT_FILE="$HOME/.macoestro/mcp-port"
        while [ ! -f "$PORT_FILE" ]; do sleep 1; done
        PORT=$(cat "$PORT_FILE")
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            resp=$(curl -s -o - -w '\\n%{http_code}' -X POST "http://127.0.0.1:${PORT}/mcp" \
                -H "Content-Type: application/json" -d "$line" 2>/dev/null)
            code=$(echo "$resp" | tail -1); body=$(echo "$resp" | sed '$d')
            [ "$code" = "204" ] && continue
            [ -n "$body" ] && echo "$body"
        done
        """

        try? script.write(to: bridgeScript, atomically: true, encoding: .utf8)
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: bridgeScript.path)
    }
}
