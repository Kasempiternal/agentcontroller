# Changelog

All notable changes to Macoestro are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

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
- **Re-opening a running Macoestro** from Spotlight / Finder / Launchpad now
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

Turned Macoestro from an automation toy into a QA harness, and hardened the
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
