#!/bin/bash
# AgentController MCP stdio-to-HTTP bridge
# Reads JSON-RPC from stdin, POSTs to AgentController's local HTTP server, echoes response.
# Authenticates with a per-launch bearer token written by AgentController at 0600.
# Keeps the process alive even if AgentController isn't running yet — retries on each request.
# Every request is deadline-bounded (--max-time) so a hung server can never wedge the
# loop, and error replies echo the request's own id so the client can correlate them
# (an id-less error is uncorrelatable and leaves the client waiting until timeout).

PORT_FILE="$HOME/.agentcontroller/mcp-port"
TOKEN_FILE="$HOME/.agentcontroller/mcp-token"
# Generous ceiling: the longest legitimate tool calls (wait_for_element, recordings)
# finish well inside this. Without it, one hung request wedges the serial loop forever.
MAX_TIME=180

resolve_port() {
    [ -f "$PORT_FILE" ] && cat "$PORT_FILE" || echo ""
}

resolve_token() {
    [ -f "$TOKEN_FILE" ] && cat "$TOKEN_FILE" || echo ""
}

# First "id" member of the request line — string, number, or null. Empty result
# means the request is a notification and must never receive a reply at all.
extract_id() {
    printf '%s' "$1" \
        | grep -oE '"id"[[:space:]]*:[[:space:]]*("(\\.|[^"\\])*"|-?[0-9]+|null)' \
        | head -n 1 \
        | sed -E 's/^"id"[[:space:]]*:[[:space:]]*//'
}

emit_error() { # $1 = request id ("" = notification → suppressed), $2 = message
    [ -z "$1" ] && return
    echo "{\"jsonrpc\":\"2.0\",\"id\":$1,\"error\":{\"code\":-32000,\"message\":\"$2\"}}"
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
    REQ_ID=$(extract_id "$line")

    # Re-resolve port if empty (previous failure or AgentController not yet running).
    if [ -z "$PORT" ]; then
        PORT=$(resolve_port)
        [ -z "$PORT" ] && sleep 2 && PORT=$(resolve_port)
    fi
    # Re-resolve token if empty (AgentController restarted with a fresh token).
    [ -z "$TOKEN" ] && TOKEN=$(resolve_token)

    if [ -z "$PORT" ] || [ -z "$TOKEN" ]; then
        emit_error "$REQ_ID" "AgentController is not running. Launch the AgentController menu bar app first."
        continue
    fi

    do_request() {
        # Body via stdin (--data-binary @-): immune to ARG_MAX however large a
        # run_steps flow gets. curl's exit status survives as the pipeline status.
        printf '%s' "$line" | curl -s -o - -w '\n%{http_code}' --max-time "$MAX_TIME" \
            -X POST "http://127.0.0.1:${PORT}/mcp" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${TOKEN}" \
            --data-binary @- 2>/dev/null
    }

    response=$(do_request)
    curl_rc=$?

    # Split http_code (last line) from body (everything before) without subshells.
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    # curl 28 = deadline hit: the server accepted the connection but never
    # finished answering. Retrying immediately would just burn another deadline.
    if [ "$curl_rc" = "28" ]; then
        emit_error "$REQ_ID" "AgentController did not respond within ${MAX_TIME}s (server busy or hung on the target app)."
        continue
    fi

    if [ "$http_code" = "000" ]; then
        # Connection failed — AgentController restarted on a new port. Re-resolve both and retry once.
        PORT=$(resolve_port)
        TOKEN=$(resolve_token)
        if [ -n "$PORT" ] && [ -n "$TOKEN" ]; then
            response=$(do_request)
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"
        fi
        if [ "$http_code" = "000" ]; then
            PORT=""
            emit_error "$REQ_ID" "Cannot connect to AgentController. Retrying on next request."
            continue
        fi
    fi

    # 401 = stale token (AgentController restarted with a fresh token). Re-read and retry once.
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

    # Non-200 bodies (401/403/413) are plain {"error": ...} JSON, not JSON-RPC —
    # wrap them so the client can parse and correlate the failure.
    if [ "$http_code" != "200" ]; then
        emit_error "$REQ_ID" "AgentController rejected the request (HTTP ${http_code})."
        continue
    fi

    [ -n "$body" ] && echo "$body"
done
