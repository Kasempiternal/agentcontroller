# Macoestro

Native macOS app automation exposed over MCP (Model Context Protocol). A menu-bar app that lets Claude Code drive any running macOS application via the Accessibility API — click, type, screenshot, navigate menus, inspect the AX tree.

Personal tool. Signed with a stable Developer ID so TCC permission grants persist across rebuilds.

## What it does

Exposes 28 MCP tools for macOS automation:

- **App control**: `list_apps`, `launch_app`, `quit_app`, `activate_app`, `get_frontmost_app`
- **Accessibility**: `get_element_tree`, `find_elements`, `get_element_attributes`, `wait_for_element`
- **Input**: `click`, `double_click`, `right_click`, `type_text`, `send_shortcut`, `scroll`, `swipe`, `drag_drop`
- **Windows**: `list_windows`, `get_window_bounds`, `set_window_bounds`, `minimize_window`, `restore_window`
- **Screenshots**: `screenshot_window`, `screenshot_element`, `screenshot_screen`
- **Menus**: `navigate_menu`, `get_menu_structure`
- **Setup**: `check_permissions`

Architecture:

```
Claude Code  ──stdin/stdout──▶  macoestro-mcp-bridge.sh  ──HTTP POST──▶  Macoestro.app
                                                                         (localhost:random-port)
```

The bridge is resilient — it doesn't die when Macoestro restarts, so rebuilds during an active Claude Code session recover automatically.

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
