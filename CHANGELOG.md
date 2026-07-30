# Changelog

All notable changes to AgentController are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [2.0.0] - 2026-07-30

AgentController becomes a cross-platform desktop automation project with one MCP
contract across native macOS and Windows backends.

### Added
- Native Windows 10/11 server built with .NET 9, Windows UI Automation, and
  Win32 APIs, including stable element handles, assertions, screenshots,
  flows, window control, menus, clipboard, and background UIA interactions.
- Foreground-gated Windows implementations for `double_click`, `right_click`,
  `send_shortcut`, `swipe`, and `drag_drop`. Each requires `foreground:true`,
  verifies foreground acquisition, and restores the previous focus and cursor.
- Self-contained Windows publishing, protocol smoke coverage, a disposable UI
  fixture, and end-to-end integration checks for all five raw-input tools.
- A new cross-platform application icon for the macOS bundle, Windows
  executable, and repository identity.

### Changed
- Renamed the application, packages, namespaces, binaries, bundle identifier,
  MCP server names, scripts, runtime directories, documentation, and CI paths
  to the AgentController identity.
- Versioned both native backends together at 2.0.0.
- The repository documentation now leads with the shared platform contract and
  calls out capability and security differences explicitly.

### Compatibility
- Both backends register all 49 tool names. Windows implements 46 natively and
  returns truthful unsupported errors for app-state reset and video recording.
- Existing installations and runtime data are not deleted during migration;
  v2 uses new application IDs and directories and must be registered once.

## [1.5.0] - 2026-07-17

The reliability release, from a three-agent deep review of the whole stack.
Closes the full hang chain (hung target app → hung server → wedged bridge →
dead session) and a process-killing crash, and modernizes the MCP surface.

### Fixed
- **Server crash on spec-legal input**: `tools/call` without the optional
  `arguments` key hit handler force-unwraps and killed the process. Absent
  arguments now normalize to `{}` at both dispatch choke points.
- **Hang chain**: a process-wide AX messaging-timeout floor (system-wide
  element) bounds every AX call — previously only app roots were bounded and
  each child ref ran at the ~6s system default; the bridge adds
  `--max-time 180` with a distinct deadline-vs-refused message.
- **Bridge correctness**: error replies now echo the request's own id
  (id:null errors were uncorrelatable, so clients waited out their own
  timeout instead of seeing the message), notifications never get replies,
  bodies stream via `--data-binary @-` (ARG_MAX-proof), and non-200 responses
  are wrapped as proper JSON-RPC errors.
- **DMG-install first run**: the app now bundles the canonical bridge script
  (Contents/Resources) and installs/refreshes `~/.agentcontroller/` from it. The
  old embedded bootstrap sent no bearer token — DMG installs (which never run
  build.sh) got a 401 on every request.
- **run_steps**: a step whose handler throws is recorded as a failed step;
  previously it aborted the loop and discarded every accumulated result.
- **Stale element handles**: cached `elementId` refs are liveness-probed; a
  dead handle with no fallback selectors fails fast with a re-snapshot hint
  instead of polling a search that can never match for the full timeout.
- **double_click false success**: a refused press on an element with no
  geometry was reported as success; it now returns a recovery-path error.
- **type_text**: `value`/`index`/`nth` now count as targeting selectors
  (previously text went to whatever held focus).
- **Selector depth parity**: searches default to depth 12 matching
  `snapshot`, so snapshot-visible elements are reachable by selector tools.
- `--skip-notarize` DMGs are now actually codesigned (the summary already
  said "signed").

### Added
- **MCP tool annotations**: `readOnlyHint` on the 23 pure-read tools,
  `destructiveHint` on `reset_app_state`/`quit_app`/`set_clipboard`,
  `openWorldHint:false` everywhere — clients can gate approvals sensibly.
- **protocolVersion negotiation**: only supported revisions are echoed
  (2024-11-05 / 2025-03-26 / 2025-06-18).

### Changed
- Tool JSON payloads are compact (no pretty-printing) — removes a 10-30%
  whitespace token tax on every tree/snapshot/list response.

## [1.4.0] - 2026-07-17

The Focus Guard release: "background by default" is now a guarantee, not a
convention. A driving agent was observed calling `activate_app` before a
screenshot that never needed it — yanking the user to the tested app mid-run.
Tool descriptions alone are hints; the dispatcher now enforces them.

### Added
- **Focus Guard** (default ON; toggle in the menu-bar dropdown and the status
  window; persisted across launches): the tool dispatcher refuses
  `activate_app` and any `foreground:true` escalation with an instructive
  error that re-steers the agent onto the background-safe path instead of
  executing the call. The single dispatch-level gate also covers steps
  replayed through `run_steps` / `run_saved_flow`.
- Server `instructions` (MCP `initialize`) now lead with the golden rule:
  never `activate_app`, never `foreground:true` — screenshots capture
  background and hidden windows, so the app never needs to be frontmost.

### Changed
- `activate_app` tool description now leads with the focus-steal warning and
  documents the Focus Guard refusal.

## [1.3.2] - 2026-06-18

Permission-UX fixes uncovered while moving to the notarized Developer ID build:
switching the signing identity reset TCC, and two gaps made re-granting and
re-opening the app more confusing than it should be.

### Fixed
- **Screen Recording "Enable" button** now calls `PermissionChecker.requestScreenRecording()`
  before deep-linking to System Settings. Previously it only opened the Settings
  pane — but macOS doesn't list an app under Screen Recording until it actually
  *requests* capture, so the pane showed a list the app wasn't in yet. (Mirrors
  the Accessibility row, which already did this.)
- **Re-opening a running AgentController** from Spotlight / Finder / Launchpad now
  resurfaces the main window via `applicationShouldHandleReopen`. As an
  `LSUIElement` (no Dock icon), a re-launch previously looked like a no-op.

## [1.3.1] - 2026-06-17

Distribution-signing release: builds are now signed with the personal
**Developer ID Application** identity (Team `U4VYZ8CUN9`) and notarized by
Apple, so the app and its DMG open with no Gatekeeper warning on any Mac —
not just the build machine. The same Team ID is retained, so Accessibility /
Screen-Recording grants persist (a one-time re-grant may be needed the first
launch after switching from the old Apple Development signature).

### Changed
- Signing identity moved from `Apple Development` (development-only; rejected by
  Gatekeeper) to `Developer ID Application` + notarization (the only combination
  Gatekeeper accepts for distribution outside the App Store).

## [1.3.0] - 2026-06-12

The "fully invisible QA" release: a complete test run — launch, interact,
assert, screenshot, record — now happens without the user ever losing focus,
their cursor, or even seeing the app under test.

### Added
- `hide_app` / `unhide_app` — invisible mode. Interactions **and** screenshots
  keep working while the app is hidden (ScreenCaptureKit renders hidden windows
  fresh; verified live). State-verified, since `NSRunningApplication.hide()`
  misreports success right after launch.
- `start_recording` / `stop_recording` — H.264 `.mov` window recording via
  `SCRecordingOutput` (macOS 15+), for visual evidence of a QA flow.
- `get_focused_element` — report the app's internal keyboard focus; works on
  background and hidden apps.
- `get_clipboard` / `set_clipboard` — verify copy/export flows (descriptions
  warn that the clipboard is system-wide shared state).
- `windowIndex` parameter and precise minimized-window errors on
  `screenshot_window`.
- Off-target warnings on coordinate input: PID-targeted events outside every
  window of the target app are silently dropped by macOS — the tools now say so
  instead of reporting a clean success.
- `scope` parameter on `assert_*`, `read_text`, `read_all_text`,
  `find_elements`, and `wait_for_element` for parity with interaction tools.

### Changed
- `launch_app` and `open_url` no longer activate their target (the last two
  focus-stealing tools); `foreground: true` restores the old behavior.
- All interaction tools run background-first: AX actions / `CGEvent.postToPid`
  per-process delivery, never the global HID stream, never a cursor warp
  (groundwork landed 2026-06-02, completed in this release).
- `navigate_menu` resolves the menu hierarchy by *reading* the AX tree and
  presses only the leaf — no menu ever opens on screen; press-descend remains
  as an automatic fallback for lazily-populated menus.
- `screenshot_window` picks the most plausible main window (layer 0, on-screen,
  largest) instead of enumeration-order-first, which could be a tooltip or
  status-item panel.
- Element handles are now tracked per app, so interleaved two-app testing no
  longer invalidates the other app's `e1, e2, …` ids.
- `type_text` retries the AX value readback once before falling back to
  keystrokes (SwiftUI applies AX sets asynchronously).

### Fixed
- CI workflow targeted a nonexistent `main` branch and an SDK too old to
  compile the recorder; now runs on `master` with the macOS 15 toolchain.

## [1.2.0] - 2026-06-01

Turned AgentController from an automation toy into a QA harness, and hardened the
transport. Includes everything shipped since 1.0.0 (April performance and
TCC-persistence work).

### Added
- Assertions: `assert_visible`, `assert_not_visible`, `assert_value` — poll
  until satisfied; failures return MCP `isError` so pass/fail is unambiguous.
- `snapshot` / `describe_screen` — compact element lists with stable handles
  (`e1, e2, …`) the interaction tools accept via `elementId`.
- Text extraction (`read_text`, `read_all_text`) and replayable flows
  (`run_steps`, `save_flow`, `list_flows`, `run_saved_flow`).
- `description` / `descriptionContains` / `labelContains` matchers; consistent
  selector vocabulary across all tools.
- Signed + notarized DMG packaging in `build.sh`.

### Changed
- 5× faster tree walks via batched AX attribute reads; AX messaging timeouts;
  `SCShareableContent` caching; serialized input through a dedicated executor.

### Security
- Per-launch 256-bit bearer token (constant-time compare), IPv4-loopback-pinned
  listener, Origin/Host rejection against DNS rebinding, body size caps, and
  read deadlines on the bespoke HTTP server.

## [1.0.0] - 2026-03-27

### Added
- Initial release: native macOS app automation over MCP — menu-bar app, bespoke
  HTTP + JSON-RPC server, stdio bridge for Claude Code, Accessibility-API
  inspection and interaction, screenshots, window and menu tools.
- Developer ID signing + hardened runtime so TCC grants persist across
  rebuilds.
