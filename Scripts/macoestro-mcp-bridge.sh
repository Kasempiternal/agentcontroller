#!/bin/bash
# Macoestro MCP stdio-to-HTTP bridge
# Reads JSON-RPC from stdin, POSTs to Macoestro's local HTTP server, echoes response.
# Authenticates with a per-launch bearer token written by Macoestro at 0600.
# Keeps the process alive even if Macoestro isn't running yet — retries on each request.

PORT_FILE="$HOME/.macoestro/mcp-port"
TOKEN_FILE="$HOME/.macoestro/mcp-token"

resolve_port() {
    [ -f "$PORT_FILE" ] && cat "$PORT_FILE" || echo ""
}

resolve_token() {
    [ -f "$TOKEN_FILE" ] && cat "$TOKEN_FILE" || echo ""
}

# Wait up to 30s on startup for BOTH the port and token files to appear.
waited=0
while { [ ! -f "$PORT_FILE" ] || [ ! -f "$TOKEN_FILE" ]; } && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
done
PORT=$(resolve_port)
TOKEN=$(resolve_token)

while IFS= read -r line; do
    [ -z "$line" ] && continue

    # Re-resolve port if empty (previous failure or Macoestro not yet running).
    if [ -z "$PORT" ]; then
        PORT=$(resolve_port)
        [ -z "$PORT" ] && sleep 2 && PORT=$(resolve_port)
    fi
    # Re-resolve token if empty (Macoestro restarted with a fresh token).
    [ -z "$TOKEN" ] && TOKEN=$(resolve_token)

    if [ -z "$PORT" ] || [ -z "$TOKEN" ]; then
        echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Macoestro is not running. Launch the Macoestro menu bar app first."}}'
        continue
    fi

    do_request() {
        curl -s -o - -w '\n%{http_code}' -X POST "http://127.0.0.1:${PORT}/mcp" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${TOKEN}" \
            -d "$line" 2>/dev/null
    }

    response=$(do_request)

    # Split http_code (last line) from body (everything before) without subshells.
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$http_code" = "000" ]; then
        # Connection failed — Macoestro restarted on a new port. Re-resolve both and retry once.
        PORT=$(resolve_port)
        TOKEN=$(resolve_token)
        if [ -n "$PORT" ] && [ -n "$TOKEN" ]; then
            response=$(do_request)
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"
        fi
        if [ "$http_code" = "000" ]; then
            PORT=""
            echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Cannot connect to Macoestro. Retrying on next request."}}'
            continue
        fi
    fi

    # 401 = stale token (Macoestro restarted with a fresh token). Re-read and retry once.
    if [ "$http_code" = "401" ]; then
        TOKEN=$(resolve_token)
        if [ -n "$TOKEN" ]; then
            response=$(do_request)
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"
        fi
    fi

    # HTTP 204 = notification acknowledged, no body to echo.
    [ "$http_code" = "204" ] && continue

    [ -n "$body" ] && echo "$body"
done
