# Security Policy

## Reporting a vulnerability

Please report security issues privately, not as a public issue.

- Preferred: open a private advisory via **Security → Report a vulnerability** on the GitHub repository.
- Alternative: email the address in [LICENSE](LICENSE).

Please include the affected platform (macOS or Windows), the version from the
menu-bar status view or `initialize` response, and the smallest reproduction you
have. Expect an initial response within 7 days.

## What this software can do

AgentController is a desktop automation tool, so a compromise of it is a
compromise of the user's session. It is worth being explicit about that:

- On macOS it holds **Accessibility** and **Screen Recording** grants, which
  together allow reading and driving any application's UI and capturing the
  screen.
- On Windows it drives UI Automation and synthesizes input with `SendInput`.
- The iOS backend drives simulators via `idb`/`simctl` and physical iPhones
  via WebDriverAgent, including tapping, typing, reading the UI tree, the
  clipboard, and capturing the screen.
- Screenshots and accessibility trees routinely contain whatever is on screen,
  including secrets. Treat tool output as sensitive.

Anyone who can execute code as the signed-in user, or reach the local MCP
endpoint with a valid token, can drive the desktop.

## Design boundaries

These are deliberate properties of the current design, not accidents:

| Boundary | Implementation |
|---|---|
| Network reachability | The macOS HTTP server binds **IPv4 loopback only**, never `0.0.0.0`. |
| Authentication | A fresh 256-bit bearer token per launch, written to `~/.agentcontroller/mcp-token` at mode `0600`. Comparison is constant-time. |
| Browser-origin attacks | Requests carrying an `Origin` header, or a non-loopback `Host`, are rejected with `403` to defeat DNS rebinding. |
| Resource exhaustion | Request bodies are capped at 16 MiB and reads are deadline-bounded (slowloris protection). |
| Focus theft | Focus Guard is on by default and refuses `activate_app` and every `foreground:true` request at dispatch. |
| Destructive actions | `reset_app_state` deletes an app container only behind an explicit `wipeData: true` flag. Clipboard tools document that they touch system-wide state. |
| Windows privilege | UIPI prevents automating higher-integrity processes. Run the target and AgentController at the same integrity level; do not elevate either without cause. |

The Windows backend speaks MCP over stdio and opens **no listening socket**, so
the loopback and token considerations above are macOS-specific.

The iOS backend speaks MCP over stdio. Its live-screen viewer binds
**127.0.0.1 only**, because the stream is unauthenticated. Child processes are
invoked with argument arrays (never shell strings) so caller-supplied device
and bundle identifiers cannot inject commands. Note one boundary this backend
cannot enforce: **WebDriverAgent listens unauthenticated on the phone (port
8100) while running** — anyone who can reach that port can drive the device.
Prefer USB connections and stop WDA when not testing; this is an upstream
property of WebDriverAgent.

## Out of scope

The following are known and accepted, and are not treated as vulnerabilities:

- Any local user who can read `~/.agentcontroller/mcp-token` (i.e. the same user
  account) can drive the server. The token protects against other *origins*, not
  against the account owner.
- Automating an application implies reading its contents. That is the purpose.
- Bypassing macOS TCC or Windows UIPI is out of scope; AgentController relies on
  those grants rather than circumventing them.

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
|---|---|
| 2.2.x | yes |
| < 2.2 | no |
