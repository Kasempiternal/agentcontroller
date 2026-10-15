#!/bin/bash
# AgentController × Claude Code: registers both MCP servers and installs the autonomy rule,
# the focus-guard hook and the `agentcontroller` skill. Idempotent; every file it changes is
# backed up first (~/.agentcontroller/backups/).
#
#   install.sh             install or refresh everything
#   install.sh --check     report what is installed and working; changes nothing (exit 1 on a gap)
#   install.sh --uninstall remove the rule block, the hook and the skill (MCP registrations stay)
#
# Run by `agentcontroller install-claude`, by build.sh, or directly from a checkout.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
AC="$HOME/.agentcontroller"
KIT="$AC/claude"
BACKUPS="$AC/backups"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SETTINGS="$CLAUDE_DIR/settings.json"
SKILL_DIR="$CLAUDE_DIR/skills/agentcontroller"
CLI="$AC/bin/agentcontroller"
IOS_CLI="$AC/ios-server/dist/cli.js"
# Fails OPEN: a PreToolUse hook that exits 2 blocks the call, and `python3 <missing file>` exits 2,
# so a deleted or mid-swap kit would block every Bash call in every session. The hook says
# "deny" through JSON on stdout, which exit 0 keeps.
HOOK_CMD='/bin/sh -c '"'"'f="$HOME/.agentcontroller/claude/focus-guard.py"; [ -f "$f" ] && python3 "$f"; exit 0'"'"''
MODE="${1:-install}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; GAPS=$((GAPS + 1)); }
info() { printf '  · %s\n' "$*"; }
GAPS=0

backup() { # $1 = file
    [ -f "$1" ] || return 0
    mkdir -p "$BACKUPS"
    cp -p "$1" "$BACKUPS/$(basename "$1").$(date +%Y%m%d-%H%M%S).bak"
}

# --- the managed CLAUDE.md block ------------------------------------------------------------
block_tool() { # $1 = install|remove|check
    python3 -I - "$1" "$CLAUDE_MD" "$SRC/CLAUDE-block.md" <<'PY'
import sys, re, os
mode, target, source = sys.argv[1], sys.argv[2], sys.argv[3]
begin, end = "<!-- agentcontroller:autonomy:begin", "<!-- agentcontroller:autonomy:end -->"
text = open(target).read() if os.path.exists(target) else ""
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.S)
block = open(source).read().strip() + "\n"
if mode == "check":
    found = pattern.search(text)
    sys.exit(0 if found and found.group(0).strip() == block.strip() else 1)
if mode == "remove":
    new = pattern.sub("", text)
else:
    # A function, not a string: the block text must never be read as a regex replacement.
    new = pattern.sub(lambda _: block, text) if pattern.search(text) else (text.rstrip("\n") + "\n\n" + block if text else block)
if new != text:
    os.makedirs(os.path.dirname(target), exist_ok=True)
    open(target, "w").write(new)
PY
}

# --- the PreToolUse hook in settings.json ----------------------------------------------------
hook_tool() { # $1 = install|remove|check
    python3 -I - "$1" "$SETTINGS" "$HOOK_CMD" <<'PY'
import sys, json, os
mode, target, command = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(target)) if os.path.exists(target) else {}
pre = data.setdefault("hooks", {}).setdefault("PreToolUse", [])
def ours(entry):
    return any("focus-guard.py" in (h.get("command") or "") for h in entry.get("hooks", []))
present = [e for e in pre if ours(e)]
if mode == "check":
    current = [h.get("command") for e in present for h in e.get("hooks", [])]
    sys.exit(0 if current == [command] else 1)
kept = [e for e in pre if not ours(e)]
if mode == "install":
    kept.append({"matcher": "Bash", "hooks": [{"type": "command", "command": command, "timeout": 10}]})
if kept != pre:
    data["hooks"]["PreToolUse"] = kept
    with open(target + ".tmp", "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(target + ".tmp", target)
PY
}

# --- MCP registrations ------------------------------------------------------------------------
mcp_current() { # $1 = server name → prints "command arg arg" from ~/.claude.json (user scope)
    python3 -I - "$1" <<'PY'
import sys, json, os
p = os.path.expanduser("~/.claude.json")
try:
    s = json.load(open(p)).get("mcpServers", {}).get(sys.argv[1])
except Exception:
    s = None
if s:
    print(" ".join([s.get("command", "")] + list(s.get("args", []))))
PY
}

register() { # $1 = name, rest = command + args
    local name="$1"; shift
    local want="$*"
    local have
    have="$(mcp_current "$name")"
    if [ "$have" = "$want" ]; then ok "MCP $name → $want"; return; fi
    if ! command -v claude >/dev/null 2>&1; then
        bad "MCP $name: the claude CLI is not on PATH; register it with: claude mcp add -s user $name -- $want"
        return
    fi
    backup "$HOME/.claude.json"
    [ -n "$have" ] && claude mcp remove "$name" -s user >/dev/null 2>&1
    if claude mcp add -s user "$name" -- "$@" >/dev/null 2>&1; then
        ok "MCP $name → $want${have:+ (was: $have)}"
    else
        bad "MCP $name: claude mcp add failed"
    fi
}

check_mcp() { # $1 = name, rest = expected command line
    local name="$1"; shift
    local have; have="$(mcp_current "$name")"
    if [ "$have" = "$*" ]; then ok "MCP $name → $have"; else bad "MCP $name is '${have:-not registered}', expected '$*'"; fi
}

# --- runtime pieces the app installs from its bundle ------------------------------------------
sync_kit() {
    mkdir -p "$KIT"
    if [ "$SRC" != "$KIT" ]; then
        cp "$SRC/install.sh" "$SRC/CLAUDE-block.md" "$KIT/"
        cp "$SRC/hooks/focus-guard.py" "$KIT/focus-guard.py"
        mkdir -p "$KIT/skills/agentcontroller"
        cp "$SRC/skills/agentcontroller/SKILL.md" "$KIT/skills/agentcontroller/SKILL.md"
    fi
    chmod 700 "$KIT"
}

hook_source() { [ -f "$SRC/hooks/focus-guard.py" ] && echo "$SRC/hooks/focus-guard.py" || echo "$SRC/focus-guard.py"; }

# What the agentcontroller server should run: the compiled bridge when the installed CLI has it,
# else the bash bridge. Never a path that does not exist.
BRIDGE="$AC/agentcontroller-mcp-bridge.sh"
desktop_command() {
    if [ -x "$CLI" ] && "$CLI" mcp --check >/dev/null 2>&1; then echo "$CLI mcp"
    elif [ -x "$BRIDGE" ]; then echo "$BRIDGE"
    fi
}

# Starts the iOS server with initialize on a real pipe (a background job in a non-interactive
# shell reads /dev/null) and succeeds when it answers. No simulator prewarm.
ios_probe() {
    AGENTCONTROLLER_IOS_NO_PREWARM=1 python3 -I - "$1" <<'PY'
import json, os, select, subprocess, sys, time
proc = subprocess.Popen(["node", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, env=os.environ)
request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "check", "version": "1"}}}
proc.stdin.write((json.dumps(request) + "\n").encode())
proc.stdin.flush()
seen, deadline = b"", time.time() + 20
try:
    while time.time() < deadline and b'"agentcontroller-ios"' not in seen:
        ready, _, _ = select.select([proc.stdout], [], [], 0.5)
        if ready:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            seen += chunk
finally:
    proc.kill()
sys.exit(0 if b'"agentcontroller-ios"' in seen else 1)
PY
}

case "$MODE" in
--check)
    echo "AgentController × Claude Code"
    if pgrep -f '/AgentController.app/Contents/MacOS/AgentController' >/dev/null; then ok "menu-bar app running"; else bad "menu-bar app not running (open -g -j /Applications/AgentController.app)"; fi
    if [ -x "$CLI" ] && "$CLI" mcp --check >/dev/null 2>&1; then ok "CLI + compiled bridge ($CLI)"; else bad "CLI missing or too old at $CLI"; fi
    if [ -x "$CLI" ] && "$CLI" status >/dev/null 2>&1; then ok "server answers on loopback"; else bad "server does not answer (agentcontroller status)"; fi
    if ! command -v node >/dev/null 2>&1; then
        bad "node is not on PATH: the iOS server needs Node 18+ (brew install node)"
    elif [ -f "$IOS_CLI" ]; then
        if ios_probe "$IOS_CLI"; then ok "iOS server answers initialize ($IOS_CLI)"; else bad "iOS server does not answer initialize ($IOS_CLI)"; fi
    else
        bad "iOS server not installed at $IOS_CLI (launch the app once, or run build.sh)"
    fi
    if [ -n "$(desktop_command)" ]; then check_mcp agentcontroller $(desktop_command); else bad "no bridge installed (launch the app once)"; fi
    check_mcp agentcontroller-ios node "$IOS_CLI"
    if block_tool check; then ok "autonomy rule in $CLAUDE_MD"; else bad "autonomy rule missing or outdated in $CLAUDE_MD"; fi
    if hook_tool check; then ok "focus-guard hook in $SETTINGS"; else bad "focus-guard hook missing or outdated in $SETTINGS"; fi
    if python3 -I "$(hook_source)" --self-test >/dev/null 2>&1; then ok "focus-guard self-test"; else bad "focus-guard self-test fails"; fi
    if [ -f "$SKILL_DIR/SKILL.md" ] && cmp -s "$SKILL_DIR/SKILL.md" "$SRC/skills/agentcontroller/SKILL.md"; then ok "skill $SKILL_DIR"; else bad "skill missing or outdated at $SKILL_DIR"; fi
    [ "$GAPS" -eq 0 ] && echo "All good." || echo "$GAPS gap(s). Fix with: $CLI install-claude"
    exit $([ "$GAPS" -eq 0 ] && echo 0 || echo 1)
    ;;
--uninstall)
    echo "Removing the AgentController rule, hook and skill"
    backup "$CLAUDE_MD"; block_tool remove && ok "rule block removed from $CLAUDE_MD"
    backup "$SETTINGS"; hook_tool remove && ok "hook removed from $SETTINGS"
    rm -rf "$SKILL_DIR" && ok "skill removed"
    info "MCP registrations left in place (claude mcp remove agentcontroller -s user to drop them)"
    exit 0
    ;;
install|--install)
    echo "Installing AgentController for Claude Code"
    sync_kit; ok "kit in $KIT"
    if [ ! -f "$IOS_CLI" ]; then
        info "iOS server not installed yet: the app installs it at launch (or run build.sh)"
    fi
    desktop="$(desktop_command)"
    if [ -z "$desktop" ]; then
        bad "no AgentController bridge at $CLI or $BRIDGE: launch the app once (it installs both), then rerun"
    else
        [ "$desktop" = "$BRIDGE" ] && info "the installed CLI has no compiled bridge; registering the bash bridge"
        # shellcheck disable=SC2086
        register agentcontroller $desktop
    fi
    if ! command -v node >/dev/null 2>&1; then
        bad "node is not on PATH: install Node 18+ (brew install node), then rerun to register the iOS server"
    elif [ ! -f "$IOS_CLI" ]; then
        bad "iOS server missing at $IOS_CLI: launch the app once (it installs it), then rerun"
    else
        register agentcontroller-ios node "$IOS_CLI"
    fi
    backup "$CLAUDE_MD"; block_tool install && ok "autonomy rule in $CLAUDE_MD"
    backup "$SETTINGS"; hook_tool install && ok "focus-guard hook (PreToolUse Bash) in $SETTINGS"
    mkdir -p "$SKILL_DIR" && cp "$SRC/skills/agentcontroller/SKILL.md" "$SKILL_DIR/SKILL.md" && ok "skill $SKILL_DIR"
    echo "Done. Open Claude Code sessions pick up the new rule, hook and servers after a restart."
    [ "$GAPS" -eq 0 ] || exit 1
    ;;
*)
    echo "usage: install.sh [--check | --uninstall]" >&2
    exit 2
    ;;
esac
