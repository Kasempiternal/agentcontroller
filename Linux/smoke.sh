#!/usr/bin/env bash
# Protocol-only smoke: initialize, tools/list, check_permissions over stdio.
# Does not require a desktop session. GUI integration still needs a local
# display (optional xvfb) and is not part of this check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="${ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"

output="$(python3 -m agentcontroller_linux <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"check_permissions","arguments":{}}}
EOF
)"

AGENTCONTROLLER_SMOKE_OUTPUT="$output" python3 -c '
import json
import os
import sys

raw = os.environ["AGENTCONTROLLER_SMOKE_OUTPUT"]
lines = [line for line in raw.splitlines() if line.strip()]
if len(lines) != 3:
    raise SystemExit(f"Expected 3 MCP responses, got {len(lines)}.")
messages = [json.loads(line) for line in lines]
info = messages[0].get("result", {}).get("serverInfo", {})
if info.get("name") != "agentcontroller-linux":
    raise SystemExit("Initialize response has the wrong server name.")
tools = messages[1].get("result", {}).get("tools", [])
if len(tools) != 49:
    raise SystemExit(f"Tool registry is unexpectedly incomplete: {len(tools)}")
if messages[2].get("result", {}).get("isError"):
    raise SystemExit("check_permissions returned an MCP error.")
print(f"MCP smoke passed with {len(tools)} tools.")
'
