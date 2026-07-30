#!/bin/bash
# Verifies the cross-platform MCP tool contract.
#
# AgentController's portability promise is the tool names: the macOS and Windows
# backends share no code, so nothing but convention keeps their registries in
# step. This script turns that convention into an enforced invariant, and checks
# the counts asserted in prose against the registries themselves — so a stale
# "49 tools" claim in the README fails CI instead of misleading a reader.
#
# Runs anywhere with bash + grep: no Swift, no .NET, no running server needed.
#
# Deliberately NOT `set -e`: a checker should report every problem in one pass
# rather than abort on the first. Greps that may legitimately match nothing are
# `|| true`-guarded, because under `pipefail` a no-match grep fails the pipeline.
#
# Usage: ./Scripts/check-tool-contract.sh

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; FAILED=1; }
ok()   { printf '\033[1;32mok:\033[0m   %s\n' "$*"; }
note() { printf '       %s\n' "$*" >&2; }

# --- Extract the three sources of truth -------------------------------------
# macOS: each tool is a `registry.register(.init(name: "…"))` literal. Within
# Sources/MCPTools the `name:` label is used for nothing else; the count
# assertions below catch it if that ever stops being true.
{ grep -rhoE 'name:[[:space:]]*"[a-z_]+"' Sources/MCPTools/ || true; } \
    | grep -oE '[a-z_]+' | grep -v '^name$' | sort -u > "$WORK/macos"

# Windows: each tool is a `registry.Register("…", …)` call.
{ grep -rhoE 'Register\([[:space:]]*"[a-z_]+"' Windows/ || true; } \
    | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u > "$WORK/windows"

# Docs: docs/TOOLS.md gives each tool its own heading.
{ grep -oE '^###?[[:space:]]+`?[a-z_]+' docs/TOOLS.md || true; } \
    | grep -oE '[a-z_]+$' | sort -u > "$WORK/docs"

# iOS: each tool is a `server.registerTool(` call with the name on the next
# line. The iOS surface is deliberately its own contract (phones are not
# desktops), so it is checked against its own docs, not the desktop set.
{ grep -A1 -E 'registerTool\($' iOS/src/mcp-server.ts 2>/dev/null || true; } \
    | grep -oE "'[a-z_]+'" | tr -d "'" | sort -u > "$WORK/ios"

# iOS docs: the tool table in iOS/README.md, one `| `tool` |` row each.
{ grep -oE '^\| `[a-z_]+`' iOS/README.md 2>/dev/null || true; } \
    | grep -oE '[a-z_]+' | sort -u > "$WORK/ios_docs"

MACOS_N=$(wc -l < "$WORK/macos" | tr -d ' ')
WINDOWS_N=$(wc -l < "$WORK/windows" | tr -d ' ')
DOCS_N=$(wc -l < "$WORK/docs" | tr -d ' ')
IOS_N=$(wc -l < "$WORK/ios" | tr -d ' ')
IOS_DOCS_N=$(wc -l < "$WORK/ios_docs" | tr -d ' ')

# An empty extraction means a declaration shape changed and the patterns above
# need updating. Never let that pass as "the sets match".
[ "$MACOS_N" -gt 0 ]    || fail "extracted 0 tools from Sources/MCPTools — did the declaration shape change?"
[ "$WINDOWS_N" -gt 0 ]  || fail "extracted 0 tools from Windows/ — did the declaration shape change?"
[ "$DOCS_N" -gt 0 ]     || fail "extracted 0 tools from docs/TOOLS.md — did the heading shape change?"
[ "$IOS_N" -gt 0 ]      || fail "extracted 0 tools from iOS/src/mcp-server.ts — did the declaration shape change?"
[ "$IOS_DOCS_N" -gt 0 ] || fail "extracted 0 tools from the iOS/README.md table — did the table shape change?"

if [ "$FAILED" != 0 ]; then
    printf '\n\033[1;31mTool contract check could not run.\033[0m\n' >&2
    exit 1
fi

# --- Registries must agree exactly ------------------------------------------
if diff -q "$WORK/macos" "$WORK/windows" >/dev/null 2>&1; then
    ok "both backends register the same $MACOS_N tools"
else
    fail "backend tool registries diverge"
    comm -23 "$WORK/macos" "$WORK/windows" | while read -r t; do note "only on macOS:   $t"; done
    comm -13 "$WORK/macos" "$WORK/windows" | while read -r t; do note "only on Windows: $t"; done
fi

# --- Docs must cover exactly the registered set -----------------------------
if diff -q "$WORK/macos" "$WORK/docs" >/dev/null 2>&1; then
    ok "docs/TOOLS.md documents all $DOCS_N tools and no others"
else
    fail "docs/TOOLS.md is out of sync with the registry"
    comm -23 "$WORK/macos" "$WORK/docs" | while read -r t; do note "registered but undocumented: $t"; done
    comm -13 "$WORK/macos" "$WORK/docs" | while read -r t; do note "documented but unregistered: $t"; done
fi

# --- iOS registry must match its own docs -----------------------------------
if diff -q "$WORK/ios" "$WORK/ios_docs" >/dev/null 2>&1; then
    ok "iOS/README.md documents all $IOS_N iOS tools and no others"
else
    fail "iOS/README.md tool table is out of sync with the iOS registry"
    comm -23 "$WORK/ios" "$WORK/ios_docs" | while read -r t; do note "registered but undocumented: $t"; done
    comm -13 "$WORK/ios" "$WORK/ios_docs" | while read -r t; do note "documented but unregistered: $t"; done
fi

# --- Prose tool counts must match reality -----------------------------------
# Any "<N> tools" / "<N>-tool" / "<N> MCP tools" claim must equal one of the
# real counts (desktop or iOS), so a number in the README can never quietly rot.
COUNT_DRIFT=0
for doc in README.md Windows/README.md iOS/README.md CHANGELOG.md docs/TOOLS.md; do
    [ -f "$doc" ] || continue
    claims=$({ grep -ohE '[0-9]+\*?\*?[[:space:]-]+(MCP[[:space:]]+)?tools?\b' "$doc" || true; } \
                | grep -oE '^[0-9]+' | sort -u)
    for claimed in $claims; do
        if [ "$claimed" != "$MACOS_N" ] && [ "$claimed" != "$IOS_N" ]; then
            fail "$doc claims $claimed tools, registries have $MACOS_N (desktop) and $IOS_N (iOS)"
            COUNT_DRIFT=1
        fi
    done
done
[ "$COUNT_DRIFT" = 0 ] && ok "every tool-count claim in the docs matches a registry ($MACOS_N desktop, $IOS_N iOS)"

# --- Windows native-vs-unsupported split ------------------------------------
# Windows deliberately returns explicit errors rather than faking these three.
# An unsupported tool is a Register(...) whose handler is an unconditional
# ToolResult.Error. Keep both the count and the named set honest in the docs.
UNSUPPORTED_N=$({ grep -rhoF '_ => ToolResult.Error(' Windows/ || true; } | wc -l | tr -d ' ')
if [ "$UNSUPPORTED_N" -gt 0 ]; then
    NATIVE_N=$((WINDOWS_N - UNSUPPORTED_N))
    if grep -qE "\b$NATIVE_N\b[^.]*nativ" README.md Windows/README.md CHANGELOG.md 2>/dev/null; then
        ok "Windows native count ($NATIVE_N native, $UNSUPPORTED_N unsupported) matches the docs"
    else
        fail "Windows has $NATIVE_N native tools and $UNSUPPORTED_N unsupported — no doc states $NATIVE_N"
    fi

    # Every unsupported tool must be named in the README so users aren't surprised.
    awk '/registry\.Register\("/ { n=$0; sub(/.*Register\("/,"",n); sub(/".*/,"",n); name=n }
         /_ => ToolResult\.Error\(/ { if (name != "") { print name; name="" } }' \
        Windows/AgentController.Windows/Tools/*.cs 2>/dev/null | sort -u > "$WORK/unsupported"
    while read -r t; do
        [ -z "$t" ] && continue
        if grep -qF "$t" README.md 2>/dev/null; then
            ok "README names unsupported tool '$t'"
        else
            fail "'$t' is unsupported on Windows but the README never says so"
        fi
    done < "$WORK/unsupported"
fi

# --- Tool descriptions in docs must match the source strings ----------------
# docs/TOOLS.md claims to reproduce `tools/list` verbatim. Agents act on those
# descriptions, so a stale one is a correctness bug, not a typo: before this
# check existed, activate_app's entry predated Focus Guard and told agents the
# call would work when the default configuration refuses it.
DESC_DRIFT=0
DESC_CHECKED=0
while IFS=$'\t' read -r tool snippet; do
    [ -z "${snippet:-}" ] && continue
    DESC_CHECKED=$((DESC_CHECKED + 1))
    if ! grep -qF "$snippet" docs/TOOLS.md; then
        fail "docs/TOOLS.md description for '$tool' does not match the source string"
        DESC_DRIFT=$((DESC_DRIFT + 1))
    fi
done < <(awk '
    /name:[[:space:]]*"[a-z_]+"/ {
        n=$0; sub(/.*name:[[:space:]]*"/,"",n); sub(/".*/,"",n); name=n; next
    }
    /description:[[:space:]]*"/ && name != "" {
        d=$0; sub(/.*description:[[:space:]]*"/,"",d); sub(/".*$/,"",d)
        if (length(d) >= 40) print name "\t" substr(d,1,60)
        name=""
    }' Sources/MCPTools/Tools/*.swift)

if [ "$DESC_CHECKED" -eq 0 ]; then
    fail "extracted 0 descriptions from Sources/MCPTools — did the declaration shape change?"
elif [ "$DESC_DRIFT" -eq 0 ]; then
    ok "all $DESC_CHECKED tool descriptions in docs/TOOLS.md match the source"
fi

if [ "$FAILED" != 0 ]; then
    printf '\n\033[1;31mTool contract check failed.\033[0m\n' >&2
    exit 1
fi
printf '\n\033[1;32mTool contract intact: %s desktop tools on both backends, %s iOS tools, docs in sync.\033[0m\n' "$MACOS_N" "$IOS_N"
