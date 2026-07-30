# AgentController iOS backend

MCP server that drives **iOS simulators and physical iPhones** — the third
AgentController backend alongside macOS and Windows. It speaks MCP over stdio
and runs on a Mac (Xcode tooling is the transport to the phone).

Derived from [blitzdotdev/iPhone-mcp](https://github.com/blitzdotdev/iPhone-mcp)
(MIT — notice retained in [LICENSE](LICENSE)), then hardened and extended: the
viewer binds loopback only, child processes take argument arrays instead of
shell strings, tool output is compact JSON, discovery runs in parallel, WDA
requests carry deadlines, and the tool surface grew from 10 to 21 with MCP
annotations on every tool.

## How it reaches the device

| Target | UI reading | Input | Screenshots |
|---|---|---|---|
| Simulator | `ax-scan` daemon (native AX API), `idb` fallback | `idb` | `simctl io screenshot` |
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

21 tools. "yes" means natively implemented for that target; "—" means the tool
returns an honest unsupported error explaining the limitation.

| Tool | Simulator | Physical iPhone |
|---|---|---|
| `get_execution_context` | yes | yes |
| `list_devices` | yes | yes |
| `setup_device` | n/a | yes |
| `describe_screen` | yes | yes |
| `scan_ui` | yes | yes |
| `wait_for_element` | yes | yes |
| `get_screenshot` | yes | yes |
| `device_action` | yes | yes |
| `device_actions` | yes | yes |
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

\* iOS pasteboard rules require WebDriverAgent to be the foreground app on a
physical device.

`device_action`/`device_actions` gestures: `tap`, `double-tap`, `swipe`,
`button` (HOME, LOCK, SIDE_BUTTON, APPLE_PAY, SIRI), `input-text`, `key`,
`key-sequence`.

Every tool carries MCP annotations (`readOnlyHint`, `destructiveHint`,
`openWorldHint`) so clients can gate confirmation on the destructive ones
(`terminate_app`, `uninstall_app`, `set_clipboard`).

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
