#!/usr/bin/env python3
"""Claude Code PreToolUse hook (Bash): refuse shell commands that take the user's focus.

AgentController's Focus Guard re-activates the user's app AFTER something steals focus. This
hook stops the steal before it happens, for the channels agents actually used: `open` without
`-g` (83 calls in one week of sessions), `osascript` activate / System Events keystrokes, and
`open -a Simulator`. Each refusal names the background-safe tool to use instead.

A command the user explicitly asked to bring to the front passes with the marker
`# agentcontroller:allow-focus`.

`focus-guard.py --self-test` runs the cases at the bottom.
"""
import json
import re
import shlex
import sys

ALLOW_MARKER = "agentcontroller:allow-focus"

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
WRAPPERS = {"sudo", "command", "exec", "nohup", "time", "env", "caffeinate"}

OSASCRIPT_STEAL = re.compile(
    r"\bactivate\b|set\s+frontmost|\bkeystroke\b|\bkey\s+code\b|click\s+(at|button|menu)|\.activate\(\)",
    re.IGNORECASE,
)

ADVICE = (
    "Use AgentController instead, in the background: mcp__agentcontroller__open_url (pages, with the "
    "user's logins; pass `browser`), mcp__agentcontroller__launch_app (apps, `paths` for files), "
    "snapshot + run_steps to click/type, screenshot_window to look. For a file the user should get, "
    "`open -g <file>`. Simulators: `xcrun simctl` / agentcontroller-ios, never Simulator.app. If the user "
    f"explicitly asked to bring it to the front, append `# {ALLOW_MARKER}` to the command."
)


def strip_heredocs(command: str) -> str:
    """Drop heredoc bodies: their text is data (a script, a commit message), not commands."""
    lines = command.split("\n")
    out, terminator = [], None
    for line in lines:
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
            continue
        out.append(line)
        match = HEREDOC.search(line)
        if match:
            terminator = match.group(2)
    return "\n".join(out)


def segments(text: str):
    """Split a shell command on its UNQUOTED separators (; && || | & newline ( ) $( `).

    Text inside quotes is data — a commit message, a `python3 -c` program — so a line in it
    that happens to start with "open" is not a command.
    """
    out, cur, quote, i = [], [], None, 0
    while i < len(text):
        ch = text[i]
        if quote:
            cur.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < len(text):
                cur.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            cur.append(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < len(text):
            cur.extend(text[i:i + 2])
            i += 2
            continue
        if ch == "#" and (not cur or cur[-1] in " \t"):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
            continue
        if text[i:i + 2] in ("&&", "||", "$("):
            out.append("".join(cur))
            cur = []
            i += 2
            continue
        if ch in ";|&\n`()":
            out.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(ch)
        i += 1
    out.append("".join(cur))
    return out


def words(segment: str):
    try:
        return shlex.split(segment, comments=True)
    except ValueError:
        return segment.split()


def command_words(segment: str):
    tokens = words(segment)
    while tokens and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]) or tokens[0] in WRAPPERS):
        tokens = tokens[1:]
    return tokens


def path_like(token: str) -> bool:
    return (
        token.startswith(("/", "~", ".", "$"))
        or "://" in token
        or "/" in token
        or token.endswith(".app")
        or bool(re.search(r"\.[A-Za-z0-9]{1,8}$", token))
    )


def open_problem(tokens):
    """Why this `open` invocation takes focus, or None when it is background-safe."""
    args = tokens[1:]
    if not args:
        return None
    short_flags, saw_target, simulator = set(), False, False
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("--background",):
            short_flags.add("g")
        elif arg in ("-h", "--help"):
            return None
        elif arg in ("-a", "-b") and i + 1 < len(args):
            target = args[i + 1]
            if re.search(r"(^|/)Simulator(\.app)?$|com\.apple\.iphonesimulator", target):
                simulator = True
            saw_target = True
            i += 1
        elif arg.startswith("--"):
            pass
        elif arg.startswith("-") and len(arg) > 1:
            short_flags.update(arg[1:])
        elif path_like(arg):
            saw_target = True
        else:
            # `open the file` in prose that slipped past the heredoc filter: not a command.
            if not saw_target and i == 0:
                return None
        i += 1
    if simulator:
        return "`open -a Simulator` puts Simulator.app on screen"
    if not saw_target:
        return None
    # Launching an app bundle by path is the "rebuild, install, open it" step the user's own
    # rules ask for; everything else (pages, files, Finder reveals, apps by name) needs -g.
    targets = [a for a in args if not a.startswith("-")]
    if "a" not in short_flags and "R" not in short_flags and targets and all(t.rstrip("/").endswith(".app") for t in targets):
        return None
    if "g" not in short_flags:
        return "`open` without `-g` brings the app to the front"
    return None


def problem(command: str):
    if ALLOW_MARKER in command:
        return None
    body = strip_heredocs(command)
    for segment in segments(body):
        tokens = command_words(segment.strip())
        if not tokens:
            continue
        head = tokens[0].rsplit("/", 1)[-1]
        if head == "open":
            why = open_problem(tokens)
            if why:
                return why
        elif head == "osascript":
            script = " ".join(tokens[1:])
            if OSASCRIPT_STEAL.search(script):
                return "`osascript` that activates an app or sends System Events keystrokes/clicks takes focus"
    return None


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0
    if event.get("tool_name") != "Bash":
        return 0
    command = (event.get("tool_input") or {}).get("command") or ""
    why = problem(command)
    if not why:
        return 0
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"AgentController focus guard: {why}, and the user is working on this Mac. {ADVICE}",
        }
    }))
    return 0


CASES = [
    ("open https://example.com", True),
    ("open -a Safari https://example.com", True),
    ('open -a "Google Chrome" "https://appstoreconnect.apple.com/business"', True),
    ('open -g -a "Google Chrome" "https://x.dev"', False),
    ("open -gj /Applications/AgentController.app", False),
    ("open -g -j /Applications/AgentController.app", False),
    ("open -a Simulator", True),
    ("open -g -a Simulator", True),
    ("open .", True),
    ("open build/report.pdf", True),
    ("open -g build/report.pdf", False),
    ("open -R ~/Desktop/x.png", True),
    ("cd /tmp && open http://localhost:3000", True),
    ("echo hi; /usr/bin/open https://a.b", True),
    ("open --help", False),
    ("git log --oneline | head", False),
    ("python3 -c \"f=open('x.txt'); print(f.read())\"", False),
    ("cat <<'EOF' > notes.md\nopen https://example.com in your browser\nEOF\necho done", False),
    ("git commit -m \"docs: open the settings page\"", False),
    ("osascript -e 'tell application \"Safari\" to activate'", True),
    ("osascript -e 'tell application \"System Events\" to keystroke \"v\" using command down'", True),
    ("osascript -e 'display notification \"done\"'", False),
    ("osascript -e 'tell application \"Music\" to pause'", False),
    ("open https://example.com  # agentcontroller:allow-focus", False),
    ("FOO=1 open https://example.com", True),
    ("xcrun simctl boot 1234", False),
    ('git commit -m "fix: thing\n\nopen /tmp/x was wrong"', False),
    ("(cd /tmp && open report.html)", True),
    ("echo \"$(open https://a.b)\"", False),
    ("open -a \"Microsoft Excel\" ~/Downloads/x.xlsx", True),
    ("open -e .env", True),
    ("open /Applications/GPUMax.app", False),
    ("open ~/Applications/MyApp.app/", False),
    ("open -R /Applications/GPUMax.app", True),
    ("open -a Docker", True),
    ("open -g -a Docker", False),
]


def self_test() -> int:
    failures = 0
    for command, should_block in CASES:
        blocked = problem(command) is not None
        if blocked != should_block:
            failures += 1
            print(f"FAIL ({'blocked' if blocked else 'allowed'}): {command!r}")
    print(f"{len(CASES) - failures}/{len(CASES)} cases pass")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    sys.exit(main())
