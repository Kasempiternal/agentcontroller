# AgentController for Linux

This directory contains the native Linux backend for AgentController. It exposes the
same MCP-first QA workflow as the macOS app, using AT-SPI, ImageMagick `import` or
grim, and optional xdotool/ydotool input instead of AXUIElement, CGEvent, and
ScreenCaptureKit.

## Current milestone

The Linux server supports the core end-to-end loop:

- app discovery, launch, activation, close, hide/show, and URL opening
- compact snapshots with stable `e1`, `e2`, ... element handles
- selectors compatible with AgentController (`role`, `title`, `identifier`,
  `labelContains`, `index`, and the other existing selector fields)
- AT-SPI role names mapped to AX aliases (`AXButton`, `AXTextField`, `AXStaticText`, ...)
- element search, attributes, focused element, waits, assertions, and text reads
- background-safe AT-SPI actions for click, toggle, editable text, and scroll
- window listing, bounds, move/resize, minimize, and restore on X11
- screen, window, and visible element screenshots
- clipboard access and MCP behavior annotations

The server also advertises explicit error stubs for video recording and generic
app-state reset so agents get a truthful capability result instead of silently
doing the wrong thing.

The current registry contains all 49 AgentController-compatible tools: 46 native
implementations and three explicit unsupported responses.

## Capture backends

Which helper takes the screenshot depends on the display server:

| Display | Tool | Notes |
|---|---|---|
| X11 (`DISPLAY`) | ImageMagick `import` | `import -window root` for the desktop, `import -window 0xWID` for a window |
| Wayland (`WAYLAND_DISPLAY`) | `grim` | Full output or a region (`grim -g "x,y wxh"`). There is no honest window-id capture |

JPEG is the default when ImageMagick `convert` (or `magick`) is on PATH, quality 0.7,
longest side capped around 1400 pixels. Otherwise the PNG from `import`/`grim` is
returned as-is.

## Build

Requirements: Python 3.11 or newer. Runtime is the standard library only. AT-SPI
support is an optional system package, lazy-imported so headless CI can still
`import agentcontroller_linux`.

```bash
# system AT-SPI (Debian/Ubuntu)
sudo apt install python3-gi gir1.2-atspi-2.0 at-spi2-core

# X11 screenshots / window helpers
sudo apt install imagemagick xdotool xclip x11-utils

# Wayland screenshots / clipboard
sudo apt install grim wl-clipboard
```

Editable install from this directory:

```bash
pip install -e Linux/
```

Without pip, the module runs from a source checkout:

```bash
PYTHONPATH=Linux/src python3 -m agentcontroller_linux
```

Protocol-only smoke (no desktop required):

```bash
./Linux/smoke.sh
```

GUI integration against a real app is still a local step. `xvfb-run` can host
an X11 session for AT-SPI and `import` when you do not have a seat.

```bash
python3 -m compileall Linux/src
PYTHONPATH=Linux/src python3 -m unittest discover -s Linux/tests -v
```

## Register with an MCP client

The Linux backend uses MCP stdio directly. It never opens a listening socket
and never binds all interfaces.

After `pip install -e Linux/`, Cursor-style `.mcp.json`:

```json
{
  "mcpServers": {
    "agentcontroller-linux": {
      "command": "python3",
      "args": ["-m", "agentcontroller_linux"]
    }
  }
}
```

The console script works the same way once the package is installed:

```json
{
  "mcpServers": {
    "agentcontroller-linux": {
      "command": "agentcontroller-linux"
    }
  }
}
```

From a checkout without installing, keep `PYTHONPATH` pointing at `Linux/src`
or wrap the command in an env that sets it.

## Important Linux differences

Linux cannot reproduce every macOS background-input guarantee:

- AT-SPI actions and editable text are used first and do not move the pointer.
- If a control exposes no suitable action, `click` and `type_text` refuse the
  fallback unless the caller explicitly passes `foreground: true`.
- Foreground input can briefly change focus. The implementation restores the
  previous focused window and pointer position afterward.
- Identify apps by PID, process name, `WM_CLASS`, window title, or desktop id.
  `launch_app` takes `path`; `bundleId` is accepted as an alias.
- Saved flows live under `$XDG_DATA_HOME/agentcontroller/flows` (default
  `~/.local/share/agentcontroller/flows`).
- `check_permissions` reports `atspiAvailable`, `displayServer` (`x11` /
  `wayland` / `none`), `screenshotBackend`, and `clipboardBackend`. Missing
  AT-SPI or a display produces explicit tool errors, not fake success.

## Platform layout

The repository is a platform family rather than one binary:

- `Sources/` remains the native Swift/macOS implementation.
- `Windows/AgentController.Windows/` is the native C#/.NET Windows implementation.
- `Linux/` is the native Python/AT-SPI Linux implementation.
- MCP tool names and selector semantics are the portability contract.

Recording, compositor-specific window protocols, and shared live-desktop
contract tests against all three backends are still ahead.
