#!/bin/bash
# AgentController MCP stdio-to-HTTP bridge
# Reads JSON-RPC from stdin, POSTs to AgentController's local HTTP server, echoes response.
# Authenticates with a per-launch bearer token written by AgentController at 0600.
# Keeps the process alive even if AgentController isn't running yet — retries on each request.
# Every request is deadline-bounded (--max-time) so a hung server can never wedge the
# loop, and error replies echo the request's own id so the client can correlate them
# (an id-less error is uncorrelatable and leaves the client waiting until timeout).
#
# CONCURRENT: requests are dispatched as they arrive rather than one-at-a-time. The
# previous `read line; curl; echo` loop held exactly one request in flight, which threw
# away the server's per-connection concurrency (HTTPServer spawns a Task per connection)
# and made driving N apps cost N x the wall clock — measured 19.7s for six requests that
# take 4.4s dispatched together. Out-of-order replies are safe: every JSON-RPC response
# carries the id of its request, so MCP over stdio has never required ordered responses.
# The ordering the old loop provided was an artifact of blocking curl, not a guarantee
# anything depended on.
#
# Targets bash 3.2 (the /bin/bash macOS ships): no `wait -n`, no associative arrays.

PORT_FILE="$HOME/.agentcontroller/mcp-port"
TOKEN_FILE="$HOME/.agentcontroller/mcp-token"
# Generous ceiling: the longest legitimate tool calls (wait_for_element, recordings)
# finish well inside this. Without it, one hung request wedges its slot forever.
MAX_TIME=180

# Cap on in-flight requests. Not a throughput knob — a safety rail. An unbounded fan-out
# lets a model queue hundreds of AX operations that the server then drains for minutes
# with no way to cancel, and each one holds a file descriptor and a curl process.
MAX_INFLIGHT="${AGENTCONTROLLER_MAX_INFLIGHT:-8}"

# Private lock directory for serializing stdout writes. PIPE_BUF is 512 bytes on macOS,
# and a screenshot response is hundreds of KB, so concurrent writers WILL interleave
# mid-line without this. mkdir is the portable atomic test-and-set.
LOCK_BASE="${TMPDIR:-/tmp}/agentcontroller-bridge.$$"
mkdir -p "$LOCK_BASE" 2>/dev/null
LOCK="$LOCK_BASE/out.lock"
cleanup() {
    rm -rf "$LOCK_BASE" 2>/dev/null
}
trap cleanup EXIT INT TERM

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

# Write one complete line to stdout under the mutex. A writer that dies holding the
# lock would wedge every other response, so the wait is bounded: after 30s we assume
# the holder is gone, break the lock, and write anyway. A garbled line beats a hang.
emit_line() {
    # Re-create the base if the parent's INT/TERM cleanup already removed it —
    # otherwise every in-flight writer would spin its full 30s bound against a
    # mkdir that can never succeed under a deleted parent.
    [ -d "$LOCK_BASE" ] || mkdir -p "$LOCK_BASE" 2>/dev/null
    waited=0
    until mkdir "$LOCK" 2>/dev/null; do
        sleep 0.01
        waited=$((waited + 1))
        if [ "$waited" -ge 3000 ]; then
            rmdir "$LOCK" 2>/dev/null
            mkdir "$LOCK" 2>/dev/null
            break
        fi
    done
    printf '%s\n' "$1"
    rmdir "$LOCK" 2>/dev/null
}

emit_error() { # $1 = request id ("" = notification → suppressed), $2 = message
    [ -z "$1" ] && return
    emit_line "{\"jsonrpc\":\"2.0\",\"id\":$1,\"error\":{\"code\":-32000,\"message\":\"$2\"}}"
}

# One request, start to finish. Runs in a background subshell, so it owns its own
# port/token copies and re-resolves them itself on failure — there is no parent state
# to write back to, which also removes the stale-cache class of bug the serial loop had.
handle_request() {
    local line="$1"
    local port="$2"
    local token="$3"
    local req_id
    req_id=$(extract_id "$line")

    do_request() {
        # Body via stdin (--data-binary @-): immune to ARG_MAX however large a
        # run_steps flow gets. curl's exit status survives as the pipeline status.
        printf '%s' "$line" | curl -s -o - -w '\n%{http_code}' --max-time "$MAX_TIME" \
            -X POST "http://127.0.0.1:${port}/mcp" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${token}" \
            --data-binary @- 2>/dev/null
    }

    local response curl_rc http_code body
    response=$(do_request)
    curl_rc=$?

    # Split http_code (last line) from body (everything before) without subshells.
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    # curl 28 = deadline hit: the server accepted the connection but never
    # finished answering. Retrying immediately would just burn another deadline.
    if [ "$curl_rc" = "28" ]; then
        emit_error "$req_id" "AgentController did not respond within ${MAX_TIME}s (server busy or hung on the target app)."
        return
    fi

    if [ "$http_code" = "000" ]; then
        # Connection failed — AgentController restarted on a new port. Re-resolve both and retry once.
        port=$(resolve_port)
        token=$(resolve_token)
        if [ -n "$port" ] && [ -n "$token" ]; then
            response=$(do_request)
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"
        fi
        if [ "$http_code" = "000" ]; then
            emit_error "$req_id" "Cannot connect to AgentController. Retrying on next request."
            return
        fi
    fi

    # 401 = stale token (AgentController restarted with a fresh token). Re-read and retry once.
    if [ "$http_code" = "401" ]; then
        token=$(resolve_token)
        if [ -n "$token" ]; then
            response=$(do_request)
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"
        fi
    fi

    # HTTP 204 = notification acknowledged, no body to echo.
    [ "$http_code" = "204" ] && return

    # Non-200 bodies (401/403/413) are plain {"error": ...} JSON, not JSON-RPC —
    # wrap them so the client can parse and correlate the failure.
    if [ "$http_code" != "200" ]; then
        emit_error "$req_id" "AgentController rejected the request (HTTP ${http_code})."
        return
    fi

    [ -n "$body" ] && emit_line "$body"
}

# Wait up to 30s on startup for BOTH the port and token files to appear.
waited=0
while { [ ! -f "$PORT_FILE" ] || [ ! -f "$TOKEN_FILE" ]; } && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
done

# In-flight PIDs, oldest first. bash 3.2 has no `wait -n`, so at the cap we block on the
# OLDEST worker rather than the first to finish. That costs a little head-of-line delay
# only once MAX_INFLIGHT requests are already running — the rail, not the hot path.
INFLIGHT_PIDS=""

reap_at_cap() {
    set -- $INFLIGHT_PIDS
    if [ "$#" -ge "$MAX_INFLIGHT" ]; then
        wait "$1" 2>/dev/null
        shift
        INFLIGHT_PIDS="$*"
    fi
}

while IFS= read -r line; do
    [ -z "$line" ] && continue

    # Resolved fresh per request: these are two tiny page-cached files, and reading them
    # here means a server restart self-heals on the very next request instead of after
    # one failed round-trip.
    PORT=$(resolve_port)
    TOKEN=$(resolve_token)

    if [ -z "$PORT" ] || [ -z "$TOKEN" ]; then
        emit_error "$(extract_id "$line")" "AgentController is not running. Launch the AgentController menu bar app first."
        continue
    fi

    reap_at_cap
    handle_request "$line" "$PORT" "$TOKEN" &
    INFLIGHT_PIDS="$INFLIGHT_PIDS $!"
done

# stdin closed: let every in-flight request finish before the process exits, or the
# client loses replies it is still waiting on.
wait
