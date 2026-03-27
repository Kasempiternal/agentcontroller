#!/bin/bash
PORT_FILE="$HOME/.macoestro/mcp-port"
WAITED=0
while [ ! -f "$PORT_FILE" ] && [ "$WAITED" -lt 10 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done
if [ ! -f "$PORT_FILE" ]; then
    echo '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"Macoestro is not running."}}' >&2
    exit 1
fi
PORT=$(cat "$PORT_FILE")
WAITED=0
while ! curl -s -o /dev/null -w '' "http://127.0.0.1:${PORT}/mcp" 2>/dev/null && [ "$WAITED" -lt 5 ]; do
    sleep 1
    WAITED=$((WAITED + 1))
done
while IFS= read -r line; do
    [ -z "$line" ] && continue
    response=$(curl -s -X POST "http://127.0.0.1:${PORT}/mcp" \
        -H "Content-Type: application/json" -d "$line" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo '{"jsonrpc":"2.0","id":null,"error":{"code":-1,"message":"Cannot connect to Macoestro."}}' >&2
        exit 1
    fi
    echo "$response"
done
