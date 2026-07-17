# Macoestro

[![CI](https://github.com/Kasempiternal/macoestro/actions/workflows/ci.yml/badge.svg)](https://github.com/Kasempiternal/macoestro/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-1.4.0-blue)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20(Apple%20Silicon)-lightgrey)
![Swift](https://img.shields.io/badge/swift-5.10-orange)
![License](https://img.shields.io/badge/license-personal%20use-red)

**Native macOS app QA automation for AI agents, exposed over MCP (Model Context Protocol).**

Macoestro is a menu-bar app that lets Claude Code (or any MCP client) drive and *test* any macOS application through the Accessibility API — click, type, screenshot, record video, navigate menus, inspect the AX tree, **assert** UI state, and replay recorded flows. It is the macOS-native counterpart to [Maestro](https://maestro.dev) (mobile) and Blitz (iOS).

Its defining feature: **every tool is background-safe by default**. A full QA run happens while you keep working in another app — your keyboard focus, your cursor, and your frontmost window are never touched. The app under test can even be completely hidden and the run keeps working, screenshots included.

---

## Table of contents

- [Highlights](#highlights)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Setup](#setup)
- [Quick start](#quick-start)
- [Fully-background QA](#fully-background-qa)
- [Tool catalog](#tool-catalog)
- [Security](#security)
- [Development](#development)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Highlights

- **49 MCP tools** covering app control, AX inspection, input, assertions, screenshots, video recording, menus, clipboard, windows, and replayable flows — see the full [Tool Reference](docs/TOOLS.md).
- **Background by default** — apps launch without activating, input is delivered per-process (`CGEvent.postToPid`) or via pure AX actions, menus are resolved by *reading* the AX tree, and screenshots read the window's own backing store (works even fully covered or hidden).
- **Real assertions** — `assert_visible` / `assert_not_visible` / `assert_value` poll until satisfied and return MCP `isError` on failure, so an agent's control loop gets an unambiguous PASS/FAIL instead of parsing prose.
- **Stable element handles** — `snapshot` returns a compact `[{id, role, label, enabled, frame}]` list; interaction tools accept `elementId` for O(1) reuse without re-searching.
- **Token-lean by design** — JPEG screenshots with a size cap by default, compact snapshots instead of full trees, text extraction instead of OCR.
- **Replayable flows** — record a sequence once (`save_flow`), re-run it as a regression test (`run_saved_flow`).
- **Hardened transport** — loopback-only listener, per-launch 256-bit bearer token, DNS-rebinding defenses. See [Security](#security).

## How it works

```
Claude Code ──stdio──▶ macoestro-mcp-bridge.sh ──HTTP POST──▶ Macoestro.app
 (MCP client)           (~/.macoestro/)           localhost     (menu-bar app)
                                                                 │
                                                  Accessibility API + CGEvent
                                                  ScreenCaptureKit
                                                                 │
                                                                 ▼
                                                          App under test
```

Macoestro runs as a menu-bar app (`LSUIElement`, no Dock icon) hosting a bespoke HTTP + JSON-RPC 2.0 server on a random loopback port. A resilient stdio bridge script translates MCP's stdio transport to HTTP, re-resolving the port and auth token automatically — so rebuilding or restarting Macoestro never kills an active Claude Code session.

| Module | Responsibility |
|---|---|
| `Sources/App` | Menu-bar app, permissions UX, server lifecycle |
| `Sources/MCPServer` | HTTP listener, JSON-RPC 2.0, auth |
| `Sources/MCPTools` | The 49 tool definitions and handlers |
| `Sources/AccessibilityEngine` | AX tree walking/search, input synthesis, window/app management |
| `Sources/ScreenCapture` | ScreenCaptureKit screenshots, video recording, content caching |

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- Xcode 16 / Swift 5.10+ toolchain (to build from source; the recording tools need the macOS 15 SDK to compile and are runtime-gated to macOS 15+)
- A code-signing identity (any Apple Development certificate works for personal use — see [Why signing matters](#why-signing-matters))

## Installation

```bash
git clone git@github.com:Kasempiternal/macoestro.git
cd macoestro

# Full release: Developer ID sign + notarize + staple + DMG + install
./build.sh

# Signed but not notarized (day-to-day iteration; Gatekeeper warns once)
./build.sh --skip-notarize

# Ad-hoc dev mode (fastest, but TCC grants do NOT persist across rebuilds)
./build.sh --dev
```

`build.sh` kills any running instance, builds, signs, installs to `/Applications/Macoestro.app`, deploys the bridge script to `~/.macoestro/`, and relaunches the app.

The default signing identity is set at the top of `build.sh`; override per-invocation with:

```bash
SIGN_ID='Apple Development: Your Name (TEAMID1234)' ./build.sh --skip-notarize
```

For notarized release builds, store notarization credentials once (create an app-specific password at [appleid.apple.com](https://appleid.apple.com) first):

```bash
xcrun notarytool store-credentials macoestro-notary \
  --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>
```

### Why signing matters

macOS TCC keys Accessibility and Screen Recording grants to the signing identity's **Team ID**. Signing with any stable certificate (Developer ID *or* Apple Development, same team) means you grant the permissions **once** and they survive every rebuild. Ad-hoc signing (`--dev`) keys grants to the binary hash, which changes on every compile.

## Setup

**1. Grant permissions (one time).** On first launch Macoestro prompts for the two permissions it needs — grant them to **Macoestro.app** (not your terminal):

- *System Settings → Privacy & Security → Accessibility → Macoestro*
- *System Settings → Privacy & Security → Screen Recording → Macoestro*

**2. Register the MCP server with Claude Code.** Either user-scoped (available in all projects):

```bash
claude mcp add --scope user macoestro -- ~/.macoestro/macoestro-mcp-bridge.sh
```

…or per-project, by adding to the project's `.mcp.json`:

```json
{
  "mcpServers": {
    "macoestro": {
      "command": "/Users/<you>/.macoestro/macoestro-mcp-bridge.sh"
    }
  }
}
```

**3. Verify.** Restart Claude Code; the tools appear as `mcp__macoestro__*`. Ask Claude to run `check_permissions` — it should report `"allGranted": true`. (Auto-start on login: *System Settings → General → Login Items → add Macoestro*.)

## Quick start

A typical QA exchange with Claude Code:

> *"Launch MyApp and verify the onboarding flow works, while I keep working."*

Under the hood the agent composes tools like this:

```jsonc
// 1. Start the app WITHOUT stealing focus
{ "tool": "launch_app", "args": { "bundleId": "com.example.MyApp" } }

// 2. (optional) Make it completely invisible for the whole run
{ "tool": "hide_app", "args": { "app": "com.example.MyApp" } }

// 3. See what's on screen — compact list with stable ids e1, e2, …
{ "tool": "snapshot", "args": { "app": "com.example.MyApp" } }

// 4. Interact by handle or selector (AX press / PID-targeted events)
{ "tool": "click",     "args": { "app": "com.example.MyApp", "elementId": "e7" } }
{ "tool": "type_text", "args": { "app": "com.example.MyApp", "role": "AXTextField", "text": "hello" } }

// 5. Assert — isError on failure makes PASS/FAIL unambiguous
{ "tool": "assert_visible", "args": { "app": "com.example.MyApp", "labelContains": "Welcome" } }

// 6. Visual evidence (works while hidden/covered)
{ "tool": "screenshot_window", "args": { "app": "com.example.MyApp" } }

// 7. Save the sequence as a regression test
{ "tool": "save_flow", "args": { "name": "onboarding-smoke", "steps": [ /* … */ ] } }
```

Selector matchers (`role`, `title`, `titleContains`, `identifier`, `value`, `description`, `descriptionContains`, `labelContains`, `index`) are accepted consistently across interaction, assertion, and inspection tools. Tip: use `labelContains` when you can see text on screen but don't know which AX attribute carries it — SwiftUI varies.

## Fully-background QA

Every tool is background-safe by default — a full test run happens while the user keeps working in another app, with their focus, cursor, and key window untouched:

- `launch_app` / `open_url` start apps **without activating** them (`foreground: true` to opt out)
- Input goes through `CGEvent.postToPid` (per-process queue) or pure AX actions — never the global HID stream, never a cursor warp
- `navigate_menu` resolves the menu tree by **reading** it; no menu ever opens on screen
- Screenshots and video read the window's own backing store: the tested window can be **fully covered** by the user's windows — capture stays correct
- `hide_app` makes the tested app completely invisible; interactions and even screenshots keep working (ScreenCaptureKit renders hidden windows fresh — verified)

Verified limitations, also stated in the tool descriptions so agents self-correct:

| Limitation | Workaround |
|---|---|
| The AX windows *list* is empty while an app is hidden | Use the default `scope: "window"`; focused-window tools and screenshots are unaffected |
| Minimized windows cannot be captured | `restore_window` first (makes the window visible again) |
| Clipboard / responder-chain commands (Cmd+C/V, Copy/Paste menu items) no-op without an active app | Verify content with `read_text` / `assert_value` instead, or `activate_app` briefly for paste flows |
| PID-targeted drags can desync (apps that poll the real pointer) | Set `foreground: true` for that gesture |

The single intentionally focus-changing tool is `activate_app`; everything else only escalates behind an explicit `foreground: true`. And since v1.4.0, **Focus Guard** (default on, toggle in the menu bar) turns that convention into a hard guarantee: while enabled, the dispatcher refuses `activate_app` and every `foreground:true` call with an error that points the agent back to the background-safe path — a misbehaving agent *cannot* steal your focus.

## Tool catalog

49 tools — full parameter documentation in **[docs/TOOLS.md](docs/TOOLS.md)** (generated from the live server's `tools/list`).

| Category | Tools |
|---|---|
| App control | `list_apps` · `launch_app` · `quit_app` · `activate_app` · `hide_app` · `unhide_app` · `get_frontmost_app` · `open_url` · `reset_app_state` |
| Snapshot & handles | `snapshot` / `describe_screen` |
| Inspection | `get_element_tree` · `find_elements` · `get_element_attributes` · `get_focused_element` · `wait_for_element` |
| Assertions | `assert_visible` · `assert_not_visible` · `assert_value` |
| Text | `read_text` · `read_all_text` |
| Input | `click` · `double_click` · `right_click` · `type_text` · `send_shortcut` · `scroll` · `scroll_until_visible` · `swipe` · `drag_drop` |
| Windows | `list_windows` · `get_window_bounds` · `set_window_bounds` · `minimize_window` · `restore_window` |
| Screenshots & video | `screenshot_window` · `screenshot_element` · `screenshot_screen` · `start_recording` · `stop_recording` |
| Menus | `navigate_menu` · `get_menu_structure` |
| Clipboard | `get_clipboard` · `set_clipboard` |
| Flows | `run_steps` · `save_flow` · `list_flows` · `run_saved_flow` |
| System | `check_permissions` |

## Security

The HTTP server is pinned to **IPv4 loopback** (never `0.0.0.0`), so it is unreachable from the network. Every request must carry `Authorization: Bearer <token>`; the server generates a fresh 256-bit token per launch, writes it to `~/.macoestro/mcp-token` (mode `0600`, alongside `mcp-port`), and the bridge replays it on each call with automatic re-resolution after restarts. Bearer comparison is constant-time. Requests carrying an `Origin` header or a non-loopback `Host` are rejected (`403`) to defeat DNS rebinding from a browser. Request bodies are size-capped (16 MiB) and reads are deadline-bounded (slowloris protection).

Destructive operations are opt-in: `reset_app_state` only deletes an app's sandbox container behind an explicit `wipeData: true` flag, and the clipboard tools warn that they touch system-wide state.

## Development

- Swift Package Manager, Swift 5.10+, no third-party dependencies
- Entry point: `Sources/App/AppDelegate.swift`; Info.plist is injected at link time via `-sectcreate` (see `Package.swift`)
- Rebuild loop: edit → `./build.sh --skip-notarize` → fresh binary in `/Applications` → the bridge reconnects automatically, tools keep working in any open Claude Code session

```bash
swift build          # debug build
swift test           # unit tests (transport, JSON, selectors, input mapping)
swift build -c release -Xswiftc -warnings-as-errors   # what CI runs
```

CI builds and tests every push on a macOS 15 runner (`.github/workflows/ci.yml`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Tools don't appear in Claude Code | Is Macoestro running (menu-bar icon)? Re-add the MCP server, restart Claude Code |
| `Macoestro is not running` errors from the bridge | Launch `/Applications/Macoestro.app`; the bridge retries automatically on the next request |
| `check_permissions` shows a missing grant | Re-grant in System Settings → Privacy & Security; make sure the grant is for **Macoestro.app**, not your terminal |
| Permissions reset after a rebuild | You built with `--dev` (ad-hoc). Use a real certificate so the Team ID stays stable |
| `Signing identity not found` from `build.sh` | Pass your own: `SIGN_ID='Apple Development: …' ./build.sh --skip-notarize` |
| Screenshot of a minimized window fails | By design — `restore_window` first |
| Clicks "succeed" but nothing happens | Check the result for an off-target `warning`; the coordinates may be outside the app's windows |
| An app ignores PID-targeted input (some Electron apps, games) | Retry the same tool with `foreground: true` |

## License

Personal use only — see [LICENSE](LICENSE). No permission is granted for redistribution or commercial use.
