# Changelog

All notable changes to AgentController are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.6.0] - 2026-08-16

### Added
- **A standalone `agentcontroller` CLI.** The tools were reachable only through an
  MCP client, which put a whole class of user out of reach: a shell script, a
  CI step, a Makefile, or a person poking at an app. The CLI covers the same 50
  tools with no client in the loop — `agentcontroller snapshot
  app=com.apple.TextEdit`, `agentcontroller tools menu`, `agentcontroller
  describe navigate_menu`. `build.sh` installs it to
  `~/.agentcontroller/bin/agentcontroller` (not `/usr/local/bin`, which is
  root-owned and would put a sudo prompt in the middle of every build).

  It is a **client of the running app**, not a second implementation. There is
  one Accessibility grant, one Screen Recording grant and one Focus Guard, and
  they belong to the menu-bar app; a CLI that drove AXUIElement itself would
  need its own TCC grants and would sit outside Focus Guard. Verified: a
  Focus-Guard-refused `activate_app` is refused identically through the CLI.

  Arguments are typed from each tool's own `inputSchema` rather than guessed
  from the text, because guessing gets the one case that matters wrong — every
  tool declares `app` as a string, a PID typed at a shell looks exactly like a
  number, and a numeric `app` resolves to nothing at all. `key:=<json>` passes
  literal JSON for arrays and objects. Exit codes are the contract that makes it
  scriptable: 0 for a tool that did what it was asked, 1 for one that ran and
  reported failure, 2 for a usage or transport problem.
- **`perform_action`, an escape hatch to the platform's own accessibility
  layer** (50 tools, both desktop backends). Controls the dedicated tools cannot
  drive — steppers, sliders, combo box entries, anything needing AXConfirm or
  AXPick — had no route at all. Called without `action` it *lists* what the
  element supports, each name with a plain-language gloss, plus role, subrole
  and current value; called with one of those names it performs it.

  This is the one tool whose vocabulary is deliberately not portable: macOS
  speaks accessibility action names (`AXPress`, `AXIncrement`), Windows speaks
  UI Automation pattern actions (`Invoke`, `Toggle`, `Increment`). Translating
  between them would restore exactly the ceiling the tool exists to remove.
  Discovery mode is what keeps that usable. Two failures are reported rather
  than performed: an action the element does not advertise returns the list of
  ones it does, and an action on a disabled control errors instead of silently
  no-opping.

### Changed
- **`Scripts/check-tool-contract.sh` also guards SwiftPM product names and reads
  only the current section of the CHANGELOG.** Two things the tool-name contract
  did not cover, both found by hitting them. macOS is case-insensitive and
  SwiftPM writes every product into one directory, so a CLI product named
  `agentcontroller` *is* the file `AgentController` — the app product overwrote
  it, and the symptom was the CLI hanging forever because the binary being
  invoked was the menu-bar app starting a SwiftUI run loop. `swift build`
  succeeds either way and CI's Linux runners are case-sensitive, so nothing
  could have caught it; the check compares names, which works everywhere.
  Separately, the count check treated the 2.0.0 entry's "49 tools" as a live
  claim — it is a record of what 2.0.0 shipped, and editing it to match today's
  registry would falsify the history the file exists to keep. The check now
  stops at the second version heading.

Every change here is the same bug wearing a different hat: a tool reported
success while nothing had happened. That is the worst possible answer for an
agent's control loop, because there is no signal to retry differently — the run
continues on a false premise until something much later fails for an unrelated
reason. All five were found by driving real apps, and each fix was verified
against the same repro that exposed it.

### Fixed
- **`navigate_menu` no longer reports success for a disabled menu item.**
  `AXUIElementPerformAction(AXPress)` returns `.success` on a greyed-out item,
  so pressing one looked identical to pressing a live one. Preview with no
  document open: `Tools > Rotate Left` and `File > Print…` both returned
  `{"success": true}`, the window stayed byte-identical, and no print dialog
  ever appeared. The leaf's `AXEnabled` is now checked before the press and a
  disabled item returns `isError` naming the item and the likely precondition.
  Because AppKit only runs `validateMenuItem:` when a menu is about to display,
  a disabled reading on the silent (menu-never-opens) path is treated as a
  suspicion rather than a verdict: the tool pays for the press-descend walk to
  get AppKit's fresh answer instead of refusing on stale state. This also
  subsumes the documented responder-chain caveat — Cut/Copy/Paste/Select All
  read as disabled in a non-key app, so those no-ops are now caught too.
- **`type_text` reads the write back instead of assuming it landed.** The
  keyboard fallback returned `{"success": true, "typed": "…"}` the moment the
  keystrokes were posted, whether or not any control received them. Observed on
  a web text field: success reported, the field's AX value absent afterwards.
  The result is now a three-state answer, because the two-state one had no
  honest place to put "I could not tell": `verified: true` means the text is
  observably in the field, an `isError` means it demonstrably is not (with the
  value the field actually holds), and `verified: false` plus a note means the
  element exposes no readable value so the caller must confirm another way.
  Whether the AX focus request was accepted is reported as `focused`, and a
  refused focus combined with an unreadable element is an error rather than a
  shrug — that pair is precisely "typed somewhere, no idea where".
- **`type_text` fires a search field's action after setting its value.**
  Setting `kAXValue` writes the string straight into the cell without running
  the text-did-change chain the control's target listens on. A plain text field
  does not care; a search field does everything through it. Font Book showed
  "mono" in the field while the list still read 362 typefaces, and a follow-up
  `send_shortcut return` did not help either because AX-set never made the field
  first responder. Search fields are now focused and confirmed after the set.
  Deliberately scoped to `AXSearchField`: `AXConfirm` on an arbitrary text field
  sends its action too, which for a form field can mean submitting the form.
- **`list_windows` no longer reports zero windows for an app that has them.**
  macOS excludes windows on an **inactive Space** from an app element's
  `kAXWindows` *and* from its `kAXChildren`. With one app fullscreen, every
  other app's windows vanish from accessibility at once: Safari, TextEdit,
  Preview, Xcode and QuickTime all reported zero while the window server listed
  their real ones. This is a system behaviour, not an AgentController one — the
  same answer comes back from any process holding the accessibility permission.
  Enumeration now falls through three tiers (`kAXWindows`, then
  `kAXFocusedWindow`, then `CGWindowListCopyWindowInfo`), labels each entry with
  its `source`, and explains the situation in a `note`. Only tier-one entries
  carry an `index`, and that is enforced by the type rather than by convention:
  the index lives inside the `accessibility` case, so a recovered window cannot
  be given one that would address a different window.
- **`snapshot` / `describe_screen` no longer pass a menu bar off as screen
  content.** When an app exposes no window the walk falls back to the
  application element, whose only child is the menu bar. Preview returned 362
  elements this way — every one an `AXMenuItem`, no window content, and nothing
  in the response saying so. The walked `root` is now part of the result, and
  the degraded `application` root carries a warning.
- **`screenshot_window` explains a capture failure instead of forwarding
  ScreenCaptureKit's wording.** Some apps release their window's backing
  surface while it is off-screen; Safari does it reliably. SCKit calls that
  "Failed to start stream due to audio/video capture failure", which reads like
  a permissions problem and is not one — `check_permissions` still reports
  screen recording and `screenshot_screen` still works, which sends anyone
  debugging it in the wrong direction. The error now names the cause and the
  workarounds. **No fallback was added, on purpose:**
  `SCContentFilter(display:including:)` does return an image for such a window,
  and that image is blank — wiring it in would have replaced an honest error
  with a screenshot that passes every automated check and shows nothing.
  `CGWindowListCreateImage` is unavailable from the macOS 15 SDK onward.
- **A `list_windows` call naming an app that is not running no longer lists
  every window on the system.** An unresolvable name fell through to `pid: nil`,
  which is the "list everything" path — so a typo'd bundle ID answered a
  different question than the one asked, plausibly enough to be believed.

## [2.5.0] - 2026-08-16

### Changed
- **The MCP bridge dispatches requests concurrently instead of one at a time.**
  The `while read line; curl; echo` loop held exactly one request in flight,
  which discarded the HTTP server's per-connection concurrency and made driving
  N apps cost N × the wall clock. Six requests across two apps: 19.7s before,
  4.4s after, byte-identical responses. Out-of-order replies are safe — every
  JSON-RPC response carries its request's id, so ordered responses were never
  required; the old ordering was an artifact of blocking curl. Concurrency is
  capped (`AGENTCONTROLLER_MAX_INFLIGHT`, default 8) as a safety rail, and
  stdout writes are serialized through a lock because PIPE_BUF is 512 bytes on
  macOS and a screenshot response is hundreds of KB. Still bash 3.2, still no
  new dependencies.
- **AX work is serialized per app rather than globally.** One process-wide
  `AXExecutor` actor meant every tool call queued behind every other one, even
  for disjoint apps. Two holds made that expensive rather than theoretical:
  `snapshot` holds its lane for an entire tree walk (72s observed on a large
  app) and `InputSimulator.typeText` holds it with a per-character `usleep` —
  either one froze every other app. Each app now gets its own serial lane;
  ordering within an app is unchanged. Operations that drive system-wide HID
  (the `foreground: true` paths that move the real cursor and change the
  frontmost app) still share one global lane, because they contend for one
  cursor. Background PID-targeted work is deliberately *not* excluded from
  foreground work: it touches neither the cursor nor the frontmost app, so
  there is no shared resource between them.
- **Server instructions and the `run_steps` / `click` descriptions now steer
  toward batching and element ids.** The instructions prescribed a
  one-tool-call-per-action loop and never mentioned `run_steps`; a real
  three-day session followed them exactly — 1,892 calls, every one alone
  in its own model turn, `run_steps` used zero times. At ~0.3s of server time
  per call, that run spent nearly all its wall clock waiting on the model. The
  instructions now prescribe snapshot-once-then-`run_steps`, note that steps
  naming different apps batch together, and state why `elementId` beats a
  selector (O(1) resolve vs a tree walk that retries until timeout on a miss;
  measured p90 0.47s at 94% success versus 5.29s at 84%).
- The server instructions and the Focus Guard denial message now state the
  no-focus-steal rule as channel-independent: it protects the outcome, not
  just this server's tools, and explicitly names the shell/AppleScript bypass
  (`osascript` `activate`/`set frontmost`, System Events `keystroke`/`click
  at`, `open` without `-g`) as equally forbidden — with "stop and ask the
  user" as the sanctioned move when no background-safe path exists. A guard
  worded as a tool behavior taught a driving model to switch tools; naming
  the invariant closes the letter-vs-spirit gap.
- **Relicensed from "personal use only, all rights reserved" to Apache-2.0**,
  in preparation for making the repository public. The `iOS/` subtree keeps its
  upstream MIT license, which is retained as required and remains in force for
  that code.

### Added
- **`AXElementSearch.findProbing`** — reports what a walk saw (`nodesVisited`,
  `nearMisses`, `oneAway`, `criteriaCount`) alongside its matches, at no extra
  cost: the counters come from the per-node attribute snapshot the match
  already reads. This exists to tell "the control has not rendered yet" apart
  from "this selector describes nothing in this app". Both produce zero
  results, but the first is worth waiting out and the second is a 4-second
  wait for an answer that cannot change — 111 of 824 clicks in one measured
  session, 14.4 minutes. `InteractionTools.searchIsHopeless` consumes it: when
  the first walk saw a substantial rendered UI (≥50 nodes) and no element was
  one criterion away from matching, the retry deadline collapses to one grace
  retry (0.45s) instead of the full timeout. A control that renders a frame
  late still self-heals inside the grace window; a selector that describes
  nothing stops costing 4 seconds. Elements one-away keep the full timeout —
  a wrong "hopeless" costs the agent a recovery turn, a wrong "keep waiting"
  costs 4 seconds, and the rule is biased accordingly. Unit-tested headless
  (`SearchProbeTests`).
- **FocusWatcher** — Focus Guard now guards the outcome, not just this
  server's tools. While the guard is on, if an app this server has driven
  becomes frontmost within 30 seconds of tool activity (something the
  dispatcher itself refuses to do, so the activation came from outside — a
  shell `osascript` bypass, `open` without `-g`, or the app itself), the
  user's previous app is re-activated and a warning rides the next tool
  result so the driving agent self-corrects in-band. Deliberate user clicks
  are out of scope by construction: only driven apps count, and only during
  active tool traffic. The attribution rule is a pure function with a
  headless truth-table test.
- `launch_app` takes an optional `paths` array: files/folders open in the app
  at launch (`open -g -a App <path>` semantics), background-safe, and it works
  when the app is already running. This removes the one workflow that used to
  force a focus steal — feeding a document to the app's open panel with
  synthesized ⌘⇧G keystrokes, which only land in the frontmost app. Observed
  in the wild: an agent bypassed Focus Guard with shell `osascript` activation
  solely to do exactly that.
- `NOTICE` file recording prior art and attribution: Maestro (mobile.dev,
  Apache-2.0) for the tolerant interaction model and the flow concept — design
  influence only, no Maestro source is included — and blitzdotdev/iPhone-mcp
  (MIT) as the origin of the iOS backend, with the modifications made since.
  Apache-2.0 section 4(d) requires redistributors to carry this forward.
- README "Credits and prior art" section stating what was inherited, what was
  hardened, and what is original (both desktop backends and the unified
  cross-platform tool contract).

### Internal
- Legacy `~/.blitz-iphone-mcp` / `~/.blitz` runtime roots and the external
  gesture-viewer socket name are now isolated behind named `LEGACY_*` constants
  rather than appearing as inline literals. Resolution order and behavior are
  unchanged — these paths are load-bearing for existing installs and are
  deliberately not renamed.

## [2.4.2] - 2026-07-30

### Fixed
- `dismiss_keyboard` failed on keyboards without a toolbar Done button (a
  search keyboard has only its return key): WDA is now given the standard
  return-key labels (done/return/search/go/send/...) it may tap to close
  the keyboard. Verified against the iOS 18 Settings search keyboard on a
  physical iPhone; the corrected keyboard flow passes 11/11.

## [2.4.1] - 2026-07-30

Full-surface verification on a physical iPhone 11 Pro Max (55/57 checks;
the two failures were suite assumptions about the iOS 18 Settings layout,
not tool defects).

### Fixed
- `device_action` with a numeric HID keycode on a physical device claimed
  success while doing nothing (WebDriverAgent has no keycode support). It
  now returns an honest error telling the caller to pass a character
  string; `key-sequence` of only keycodes does the same.

## [2.4.0] - 2026-07-30

The iOS backend drops Python from every hot path: simulator input and
describe operations now speak gRPC directly to `idb_companion`, the native
daemon the Python `idb` CLI itself talks to. The backend runs fully on a
machine with no working Python; the venv-based CLI survives only as an
automatic fallback.

### Added
- Direct gRPC companion transport (`companion-client.ts`), with the
  `idb.proto` service definition vendored unmodified from facebook/idb (MIT).
  Runtime deps: `@grpc/grpc-js` + `@grpc/proto-loader` (both pure JS).
- HID event construction ported from fb-idb to TypeScript: taps, swipes,
  buttons, keycodes, and the full ASCII keymap including shifted symbols.
- `key-sequence` accepts mixed characters and keycodes on the companion path
  (the Python CLI path only took keycodes).

### Changed
- Transport order for simulator input and describes: companion gRPC → warm
  Python shell → one-shot `idb`, falling back per call. A companion that
  fails to start enters a 60s cooldown so every subsequent call degrades to
  the fallback instantly instead of re-paying the startup timeout.
- The companion is spawned with `--only simulator` (it otherwise pair-probes
  every USB-connected iPhone at startup) and `--log-level info`, and its
  stderr is consumed without being mirrored into the server log (the default
  debug level dumps entire accessibility payloads per query).

### Fixed
- The companion's gRPC server binds IPv6 `[::]` and ACCEPTS IPv4-mapped
  connections without ever serving HTTP/2 on them, so connecting to
  `localhost`/127.0.0.1 produced calls that hang until deadline. The client
  now connects to the `[::1]` literal first, with 127.0.0.1 kept only for a
  v4-only companion build (where the v6 attempt fails fast instead).
- The companion's accessibility attach is flaky: an instance that attaches at
  a bad moment serves a single zero-frame stub element forever while a fresh
  attach sees the full tree. Every attach is now validated with a probe and
  respawned once before the transport gives up and falls back.

## [2.3.0] - 2026-07-30

A deep performance pass on the iOS backend: the agent-facing hot paths now
answer in tens of milliseconds instead of seconds, and every input command is
honestly acknowledged instead of fired blind.

### Changed
- The persistent `idb` shell is now a framed request/response channel (every
  command is terminated by idb's `SUCCESS=` sentinel). Taps, swipes, buttons,
  and text input resolve when the simulator actually executed them (~2ms
  acked) instead of returning before the gesture ran.
- `describe-all`/`describe-point` ride the warm shell instead of booting a
  Python interpreter per call: `describe_screen` drops from ~185ms to ~45-70ms.
  The one-shot invocation remains as an automatic fallback.
- `tap_element` and `wait_for_element` try a describe-all fast path before the
  grid scan on simulators: a hit costs ~40-90ms instead of 1.2-2.6s. The grid
  scan still runs whenever the fast path finds nothing (every third poll and
  the final one for `wait_for_element`), so recall is unchanged.
- `wait_for_element` polls adaptively (250ms growing to 1s) instead of a fixed
  500ms when no `intervalMs` is given.
- The server prewarms the simulator transports (idb shell, companion
  connection, ax-scan daemon, screen size) in the background right after the
  MCP transport connects, and again after `boot_simulator` — the first tool
  call no longer pays the ~2-3s of cold starts.
- Element output from `describe_screen`, `scan_ui`, `tap_element`,
  `wait_for_element`, and `describe_after` is a compact normalized shape
  (label/value/title/id deduplicated, integer frames, no always-null or
  duplicate fields): payloads shrink ~60-65%, identical information content.
- Simulator screen size is measured from the AX tree's root element (exact
  for any model and orientation) instead of a hardcoded per-model table that
  mis-sized unknown models like iPhone Air; the table survives only as a
  fallback, extended and no longer queried through a shell.

### Fixed
- The idb shell's stdout was piped but never consumed, so ~650 commands in
  one session would fill the pipe buffer and wedge the shell silently.
- Writing to a dead idb shell's stdin could raise an unhandled EPIPE stream
  error and crash the whole server.
- Concurrent shell starts (a tool call racing the prewarm) could spawn two
  `idb shell` processes; startup is now deduplicated in-flight.
- Parallel WDA calls needing a session (`get_device_info` fans out four)
  raced `POST /session` and leaked sessions; creation is now deduplicated.
- `terminate_app` on an app that is not running now succeeds (the desired
  state already holds) instead of surfacing a raw simctl exit-3 error.
- A timed-out shell command now restarts the shell instead of leaving the
  response framing permanently misaligned.

## [2.2.0] - 2026-07-30

The iOS backend grows from 21 to 36 tools and gets a second performance pass.

### Added
- Fifteen new iOS tools: `tap_element` (find-by-text + tap in one call),
  `read_alert`, `handle_alert`, `dismiss_keyboard`, `lock_screen`,
  `unlock_screen`, `get_device_info` (battery, thermal, lock state, active
  app), `send_push`, `set_location`, `set_permission`, `set_appearance`,
  `set_status_bar`, `set_content_size` (Dynamic Type), `boot_simulator`,
  `shutdown_simulator`. Simulator-only
  and device-only tools return honest unsupported errors on the other target.
- `VOLUME_UP`/`VOLUME_DOWN` buttons in `device_action` (physical devices).
- `list_devices` now lists shutdown simulators too, so an agent can pick one
  and boot it with `boot_simulator`.

### Changed
- Screenshot previews ship as downscaled JPEG instead of PNG, cutting the
  inline payload roughly 4x; the full-resolution PNG path is still returned.
- Physical-device screenshots use WebDriverAgent's session-less root endpoint,
  removing a session round-trip and a stale-session failure mode.
- Every `simctl` invocation now carries a timeout so a wedged CoreSimulator
  surfaces as a tool error instead of a hung call, and booted-udid resolution
  no longer goes through a shell.

### Fixed
- `set_orientation` invalidates the cached screen frame, so coordinate
  filtering is correct after rotating the device.

## [2.1.0] - 2026-07-30

AgentController gains an iOS backend: one MCP family now drives macOS,
Windows, and iOS (simulators and physical iPhones).

### Added
- iOS backend (`iOS/`, TypeScript/Node, MCP stdio) derived from
  blitzdotdev/iPhone-mcp (MIT, notice retained), driving simulators via
  `idb`/`simctl` plus a native accessibility scanner, and physical iPhones via
  WebDriverAgent.
- Eleven new iOS tools beyond the upstream ten: `open_url`, `terminate_app`,
  `install_app`, `uninstall_app`, `get_clipboard`, `set_clipboard`,
  `wait_for_element`, `get_orientation`, `set_orientation`,
  `start_recording`, `stop_recording` — plus a `double-tap` gesture.
  Simulator-only and device-only tools return honest unsupported errors on
  the other target.
- MCP `readOnly`/`destructive`/`openWorld` annotations on all 21 iOS tools,
  and `serverInfo` sourced from package.json instead of a hardcoded string.
- CI job typechecking and building the iOS backend; the tool-contract guard
  now also verifies the iOS registry against its documentation.

### Fixed
- The iOS live-screen viewer listened on all interfaces, exposing an
  unauthenticated device screen stream to the local network; it now binds
  loopback only.
- iOS child processes interpolated caller-supplied identifiers into shell
  strings; they now use argument arrays.

### Changed
- iOS tool output is compact JSON, device discovery and UI reads run
  concurrently, screenshots derive dimensions from the PNG header instead of
  a second `sips` exec, and WebDriverAgent requests carry deadlines (3s for
  reachability probes) so a wedged WDA cannot hang tool calls.

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
