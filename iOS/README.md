# AgentController iOS backend

MCP server that drives **iOS simulators and physical iPhones** — the third
AgentController backend alongside macOS and Windows. It speaks MCP over stdio
and runs on a Mac (Xcode tooling is the transport to the phone).

Derived from [blitzdotdev/iPhone-mcp](https://github.com/blitzdotdev/iPhone-mcp)
(MIT — notice retained in [LICENSE](LICENSE)), then hardened and extended: the
viewer binds loopback only, child processes take argument arrays instead of
shell strings, tool output is compact JSON, discovery runs in parallel, WDA
requests carry deadlines, every simctl call has a timeout, screenshots ship as
downscaled JPEG previews (~4x smaller payloads), and the tool surface grew
from 10 to 36 with MCP annotations on every tool.

Built for agent speed: simulator input and describes speak gRPC directly to
`idb_companion` — no Python interpreter in any hot path, and the backend runs
on a machine with no working Python at all (the venv-based `idb` CLI survives
only as an automatic fallback). Every tap/swipe/keystroke is acknowledged by
the simulator (~2ms) instead of fired blind; `describe_screen` answers in
~50-90ms; `tap_element` and `wait_for_element` take a describe-all fast path
(~40-90ms on a hit) and fall back to the exhaustive grid scan only when it
finds nothing; transports prewarm in the background at server start so the
first tool call skips the cold starts; and element payloads are a compact
normalized shape (~60% smaller) so every scan costs the calling agent fewer
tokens.

## How it reaches the device

| Target | UI reading | Input | Screenshots |
|---|---|---|---|
| Simulator | `idb_companion` gRPC (direct), `ax-scan` daemon for grid scans, Python `idb` fallback | `idb_companion` gRPC (acked HID), Python `idb` fallback | `simctl io screenshot` |
| Physical iPhone | WebDriverAgent HTTP (`/source`) | WebDriverAgent (W3C actions) | WebDriverAgent |

Physical devices need [WebDriverAgent](https://github.com/appium/WebDriverAgent)
built and launched once per boot — `setup_device` walks through it, and the
`--setup` CLI flag installs all helper dependencies (idb, WDA clone, ax-scan).

## Setup

```bash
cd iOS
npm install && npm run build
node dist/cli.js --setup        # installs helpers, registers with Claude Code
```

Or register manually with any MCP client as a stdio server running
`node <repo>/iOS/dist/cli.js`. Existing installs from upstream iPhone-mcp are
reused automatically: helpers are looked up in `~/.agentcontroller/ios`, then
`~/.blitz-iphone-mcp`, then `~/.blitz`.

## Tools

36 tools. "yes" means natively implemented for that target; "—" means the tool
returns an honest unsupported error explaining the limitation.

| Tool | Simulator | Physical iPhone |
|---|---|---|
| `get_execution_context` | yes | yes |
| `list_devices` | yes | yes |
| `boot_simulator` | yes | — |
| `shutdown_simulator` | yes | — |
| `setup_device` | n/a | yes |
| `get_device_info` | yes | yes |
| `describe_screen` | yes | yes |
| `scan_ui` | yes | yes |
| `wait_for_element` | yes | yes |
| `get_screenshot` | yes | yes |
| `device_action` | yes | yes |
| `device_actions` | yes | yes |
| `tap_element` | yes | yes |
| `read_alert` | — | yes |
| `handle_alert` | — | yes |
| `dismiss_keyboard` | — | yes |
| `lock_screen` | — | yes |
| `unlock_screen` | — | yes |
| `launch_app` | yes | yes |
| `terminate_app` | yes | yes |
| `list_apps` | yes | — |
| `open_url` | yes | yes |
| `install_app` | yes | — |
| `uninstall_app` | yes | — |
| `get_clipboard` | yes | yes* |
| `set_clipboard` | yes | yes* |
| `get_orientation` | — | yes |
| `set_orientation` | — | yes |
| `start_recording` | yes | — |
| `stop_recording` | yes | — |
| `send_push` | yes | — |
| `set_location` | yes | — |
| `set_permission` | yes | — |
| `set_appearance` | yes | — |
| `set_status_bar` | yes | — |
| `set_content_size` | yes | — |

\* iOS pasteboard rules require WebDriverAgent to be the foreground app on a
physical device.

`device_action`/`device_actions` gestures: `tap`, `double-tap`, `swipe`,
`button` (HOME, LOCK, SIDE_BUTTON, APPLE_PAY, SIRI, and VOLUME_UP/VOLUME_DOWN
on physical devices), `input-text`, `key`, `key-sequence`.

Every tool carries MCP annotations (`readOnlyHint`, `destructiveHint`,
`openWorldHint`) so clients can gate confirmation on the destructive ones
(`terminate_app`, `uninstall_app`, `set_clipboard`, `set_permission`,
`shutdown_simulator`).

## Viewer

With a physical device connected, the server hosts a live screen viewer at
`http://localhost:5150` (auto-increments if busy). It binds **127.0.0.1 only**
— the stream is unauthenticated, so it must never be reachable from the
network.

## Security

- The MCP transport is stdio; the only listening socket is the loopback-pinned
  viewer.
- **WebDriverAgent itself listens unauthenticated on the phone (port 8100)**
  while running. Anyone who can reach that port — same Wi-Fi network for
  wireless setups, or the USB tunnel — can drive the device. Prefer USB, and
  stop WDA when not testing. This is an upstream property of WebDriverAgent,
  not something this backend can fix.
- See the repository [SECURITY.md](../SECURITY.md) for the full threat model.

## Development

```bash
npm run typecheck   # tsc --noEmit — what CI runs
npm run build       # emit dist/
```

Plain TypeScript, four runtime dependencies (`@modelcontextprotocol/sdk`,
`express`, `ws`, `zod`) plus optional `unix-dgram` for gesture overlay events
(its absence disables the overlay, never the server).
