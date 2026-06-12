# Macoestro

**v1.3.0**

Native macOS app QA automation exposed over MCP (Model Context Protocol). A menu-bar app that lets Claude Code drive and *test* any running macOS application via the Accessibility API — click, type, screenshot, record video, navigate menus, inspect the AX tree, **assert** UI state, snapshot interactable elements as stable handles, extract text, and record replayable flows. The macOS-native counterpart to Maestro (mobile) and Blitz (Mac).

Personal tool. Signed with a stable Developer ID so TCC permission grants persist across rebuilds.

## What it does

Exposes 49 MCP tools for macOS automation + QA:

- **App control**: `list_apps`, `launch_app`, `quit_app`, `activate_app`, `hide_app`, `unhide_app`, `get_frontmost_app`, `open_url`, `reset_app_state`
- **Accessibility / inspection**: `get_element_tree`, `find_elements`, `get_element_attributes`, `get_focused_element`, `wait_for_element`
- **Snapshot & handles**: `snapshot` / `describe_screen` — a compact, token-lean list of interactable elements, each with a stable `id` (`e1`, `e2`, …) that the interaction tools accept via `elementId` (no re-search per action)
- **Assertions** (the QA core): `assert_visible`, `assert_not_visible`, `assert_value` — poll until satisfied or timeout; a failed assertion returns an MCP `isError` result so pass/fail is unambiguous
- **Text**: `read_text`, `read_all_text` — verify content without screenshots
- **Input**: `click`, `double_click`, `right_click`, `type_text`, `send_shortcut`, `scroll`, `scroll_until_visible`, `swipe`, `drag_drop`
- **Windows**: `list_windows`, `get_window_bounds`, `set_window_bounds`, `minimize_window`, `restore_window`
- **Screenshots & video**: `screenshot_window` (by title or `windowIndex`), `screenshot_element`, `screenshot_screen` (JPEG + longest-side cap by default to stay context-cheap), `start_recording` / `stop_recording` (H.264 `.mov` of a window, macOS 15+)
- **Menus**: `navigate_menu`, `get_menu_structure`
- **Clipboard**: `get_clipboard`, `set_clipboard` — verify copy/export flows (system-wide shared state; warned in the tool descriptions)
- **Flows**: `run_steps`, `save_flow`, `list_flows`, `run_saved_flow` — record and replay a QA run deterministically
- **Setup**: `check_permissions`

All element matchers (`role`, `title`, `titleContains`, `identifier`, `value`, `description`, `descriptionContains`, `labelContains`, `index`) are accepted consistently across the interaction, assertion, and inspection tools. Interaction tools default their search to the **focused window** (`scope: "app"` to widen) and retry briefly so first-frame races self-heal; assertion/inspection tools default to the whole app (`scope: "window"` to narrow).

## Fully-background QA

Every tool is background-safe by default — a full test run (launch → interact → assert → screenshot → record) happens while the user keeps working in another app, with their focus, cursor, and key window untouched:

- `launch_app` / `open_url` start apps **without activating** them (`foreground: true` to opt out)
- Input goes through `CGEvent.postToPid` (per-process queue) or pure AX actions — never the global HID stream, never a cursor warp
- `navigate_menu` resolves the menu tree by **reading** it; no menu ever opens on screen
- Screenshots/video read the window's own backing store: the tested window can be **fully covered** by the user's windows — capture stays correct
- `hide_app` makes the tested app completely invisible; interactions and even screenshots keep working (ScreenCaptureKit renders hidden windows fresh — verified)

Verified limitations of background/hidden operation (also stated in the tool descriptions): the AX windows *list* is empty while an app is hidden (use the default `scope:'window'`), minimized windows can't be captured, and clipboard/responder-chain commands (Cmd+C/V, Copy/Paste menu items) need an active app.

Architecture:

```
Claude Code  ──stdin/stdout──▶  macoestro-mcp-bridge.sh  ──HTTP POST──▶  Macoestro.app
                                                                         (localhost:random-port)
```

The bridge is resilient — it doesn't die when Macoestro restarts, so rebuilds during an active Claude Code session recover automatically.

### Security

The HTTP server is pinned to **IPv4 loopback** (never `0.0.0.0`), so it is unreachable from the LAN. Every request must carry `Authorization: Bearer <token>`; the server generates a fresh 256-bit token per launch, writes it to `~/.macoestro/mcp-token` (mode `0600`, alongside `mcp-port`), and the bridge replays it on each call. Requests with an `Origin` header or a non-loopback `Host` are rejected (`403`) to defeat DNS-rebinding from a browser the user happens to have open. Bodies are size-capped and reads are deadline-bounded.

## Install

Requires macOS 14+ on Apple Silicon. First-time setup:

```bash
git clone git@github.com:Kasempiternal/macoestro.git ~/Code/macoestro
cd ~/Code/macoestro

# One-shot: store notarization credentials in Keychain (needed for ./build.sh release).
# Create an app-specific password at https://appleid.apple.com first, then:
xcrun notarytool store-credentials macoestro-notary \
  --apple-id <your-apple-id> \
  --team-id <your-team-id> \
  --password <app-specific-password>

# Full release build: signs with Developer ID + notarizes + installs
./build.sh

# Fast iteration (signed but not notarized, Gatekeeper will warn once):
./build.sh --skip-notarize

# Ad-hoc dev mode (fastest, but TCC grants won't persist across rebuilds):
./build.sh --dev
```

On first launch, grant Accessibility and Screen Recording in System Settings. Grants persist forever thanks to the stable Team ID.

## Use from Claude Code

Add to a project's `.mcp.json`:

```json
{
  "mcpServers": {
    "macoestro": {
      "command": "/Users/<you>/.macoestro/macoestro-mcp-bridge.sh"
    }
  }
}
```

Restart Claude Code. Tools appear as `mcp__macoestro__*`.

## Development

- Source: Swift Package Manager, Swift 5.10+, macOS 14+
- Entry point: `Sources/App/AppDelegate.swift`
- MCP server: `Sources/MCPServer/` (bespoke HTTP + JSON-RPC 2.0)
- Tool implementations: `Sources/MCPTools/`, `Sources/AccessibilityEngine/`, `Sources/ScreenCapture/`
- Info.plist is injected at link time via `-sectcreate __TEXT,__info_plist` (see `Package.swift`)

Rebuild loop: edit code → `./build.sh --skip-notarize` → new binary in `/Applications/` → tools work in any running Claude Code session.

## Why Developer ID + notarization

Ad-hoc signing keys TCC grants to `cdhash`, which Swift rebuilds invalidate on every compile. Developer ID signing gives a stable Team ID that TCC attests against, so grants survive rebuilds. Hardened runtime + notarization also clears Gatekeeper on first launch.

## License

Personal use. No license granted for redistribution.
