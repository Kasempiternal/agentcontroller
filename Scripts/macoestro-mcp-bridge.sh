#!/bin/bash
# Macoestro MCP stdio-to-HTTP bridge
# Reads JSON-RPC from stdin, POSTs to Macoestro's local HTTP server, echoes response.
# Keeps the process alive even if Macoestro isn't running yet — retries on each request.

PORT_FILE="$HOME/.macoestro/mcp-port"

resolve_port() {
    [ -f "$PORT_FILE" ] && cat "$PORT_FILE" || echo ""
}

# Wait up to 30s on startup for port file to appear
waited=0
while [ ! -f "$PORT_FILE" ] && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
done
PORT=$(resolve_port)

while IFS= read -r line; do
    [ -z "$line" ] && continue

    # Re-resolve port if empty (previous failure or Macoestro not yet running)
    if [ -z "$PORT" ]; then
        PORT=$(resolve_port)
        [ -z "$PORT" ] && sleep 2 && PORT=$(resolve_port)
    fi

    if [ -z "$PORT" ]; then
        echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Macoestro is not running. Launch the Macoestro menu bar app first."}}'
        continue
    fi

    response=$(curl -s -o - -w '\n%{http_code}' -X POST "http://127.0.0.1:${PORT}/mcp" \
        -H "Content-Type: application/json" -d "$line" 2>/dev/null)

    # Split http_code (last line) from body (everything before) without subshells
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$http_code" = "000" ]; then
        PORT=""
        echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Cannot connect to Macoestro. Retrying on next request."}}'
        continue
    fi

    # HTTP 204 = notification acknowledged, no body to echo
    [ "$http_code" = "204" ] && continue

    [ -n "$body" ] && echo "$body"
done
