# Tool Reference

AgentController exposes **49 MCP tools**. This file is generated from the live server's `tools/list` response (v1.3.0), so descriptions match exactly what an agent sees.

## Index

- [App control](#app-control): [`list_apps`](#list_apps), [`launch_app`](#launch_app), [`quit_app`](#quit_app), [`activate_app`](#activate_app), [`hide_app`](#hide_app), [`unhide_app`](#unhide_app), [`get_frontmost_app`](#get_frontmost_app), [`open_url`](#open_url), [`reset_app_state`](#reset_app_state)
- [Snapshot & handles](#snapshot--handles): [`snapshot`](#snapshot), [`describe_screen`](#describe_screen)
- [Inspection](#inspection): [`get_element_tree`](#get_element_tree), [`find_elements`](#find_elements), [`get_element_attributes`](#get_element_attributes), [`get_focused_element`](#get_focused_element), [`wait_for_element`](#wait_for_element)
- [Assertions](#assertions): [`assert_visible`](#assert_visible), [`assert_not_visible`](#assert_not_visible), [`assert_value`](#assert_value)
- [Text extraction](#text-extraction): [`read_text`](#read_text), [`read_all_text`](#read_all_text)
- [Input](#input): [`click`](#click), [`double_click`](#double_click), [`right_click`](#right_click), [`type_text`](#type_text), [`send_shortcut`](#send_shortcut), [`scroll`](#scroll), [`scroll_until_visible`](#scroll_until_visible), [`swipe`](#swipe), [`drag_drop`](#drag_drop)
- [Windows](#windows): [`list_windows`](#list_windows), [`get_window_bounds`](#get_window_bounds), [`set_window_bounds`](#set_window_bounds), [`minimize_window`](#minimize_window), [`restore_window`](#restore_window)
- [Screenshots & video](#screenshots--video): [`screenshot_window`](#screenshot_window), [`screenshot_element`](#screenshot_element), [`screenshot_screen`](#screenshot_screen), [`start_recording`](#start_recording), [`stop_recording`](#stop_recording)
- [Menus](#menus): [`navigate_menu`](#navigate_menu), [`get_menu_structure`](#get_menu_structure)
- [Clipboard](#clipboard): [`get_clipboard`](#get_clipboard), [`set_clipboard`](#set_clipboard)
- [Flows](#flows): [`run_steps`](#run_steps), [`save_flow`](#save_flow), [`list_flows`](#list_flows), [`run_saved_flow`](#run_saved_flow)
- [System](#system): [`check_permissions`](#check_permissions)

## App control

### `list_apps`

List running macOS applications with their name, bundle ID, and PID

_No parameters._

### `launch_app`

Launch a macOS application by bundle identifier (e.g. 'com.apple.TextEdit'). BACKGROUND-SAFE BY DEFAULT: the app starts WITHOUT being activated — its window appears but the user's current app keeps keyboard focus (open -g semantics). Set foreground:true only when the app genuinely must start frontmost.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bundleId` | string | yes | Bundle identifier (e.g. 'com.apple.TextEdit') |
| `foreground` | boolean | no | Default false (launch without stealing focus). When true, activates the app on launch. |

### `quit_app`

Quit a running macOS application

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |

### `activate_app`

Bring a running macOS application to the foreground. This is the ONE tool that intentionally changes focus and is the explicit, user-requested way to do so — every other interaction tool (click/type_text/send_shortcut/scroll/etc.) runs in the background by default and does NOT bring the app forward. Use this only when you genuinely need the target app frontmost (e.g. before a foreground:true escape-hatch action).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |

### `hide_app`

Hide all windows of a running app (Cmd+H equivalent) so it is completely invisible to the user while the QA run continues. VERIFIED to keep working while hidden: focused-window interactions (click/type_text by selector, snapshot, get_focused_element) AND screenshot_window — ScreenCaptureKit renders hidden windows fresh, so captures show current content, not a stale frame. CAVEATS: (1) the AX windows LIST is empty while hidden, so list_windows and scope:'app' searches see no windows — stick to the default scope:'window'; (2) clipboard/responder-chain commands (Copy/Paste menu items or Cmd+C/V) no-op without an active app.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |

### `unhide_app`

Unhide a hidden app's windows WITHOUT activating it — the user's frontmost app keeps keyboard focus. NOTE: until the app is activated once, its AX windows LIST may stay empty (focused-window tools and screenshots work regardless); use activate_app only if you explicitly need list_windows/scope:'app' enumeration back.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |

### `get_frontmost_app`

Get information about the currently frontmost (active) macOS application

_No parameters._

### `open_url`

Open a URL with the default handler (web link, deep link, or custom scheme like 'myapp://path'). BACKGROUND-SAFE BY DEFAULT: the handler app receives the URL WITHOUT being brought to the front — the user's focus is untouched. Set foreground:true to activate the handler app.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `url` | string | yes | URL to open (e.g. 'https://example.com' or 'myapp://route') |
| `foreground` | boolean | no | Default false (handler app stays in the background). When true, activates the handler app. |

### `reset_app_state`

Quit an app to reset its in-memory state. When wipeData:true AND the app is sandboxed (a Container exists for its bundle ID), ALSO delete ~/Library/Containers/<bundleId>/Data — this is DESTRUCTIVE and only happens behind the explicit wipeData:true flag. Without the flag, only quits.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `wipeData` | boolean | no | DESTRUCTIVE: when true, delete the app's sandbox Data container after quitting. Default false (quit only). |

## Snapshot & handles

### `snapshot`

Snapshot the focused window into a COMPACT list of elements with stable ids (also available as 'describe_screen'). Returns [{id, role, label, enabled, frame}] — far cheaper than get_element_tree. mode 'interactive' (default) keeps only controls; 'all' keeps every element. The ids feed interaction tools via elementId.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `maxDepth` | integer | no | Maximum tree depth to walk (default 12) |
| `mode` | string | no | 'interactive' (default, controls only) or 'all' (every element) |

### `describe_screen`

Alias of 'snapshot': compact, stable-id description of the focused window's elements [{id, role, label, enabled, frame}]. mode 'interactive' (default) or 'all'.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `maxDepth` | integer | no | Maximum tree depth to walk (default 12) |
| `mode` | string | no | 'interactive' (default, controls only) or 'all' (every element) |

## Inspection

### `get_element_tree`

Get the accessibility UI element tree for an application. Returns a hierarchical JSON tree of UI elements with roles, titles, and properties.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `detail` | string | no | 'lean' (default) returns role/title/identifier/value/enabled/focused/children. 'full' also includes description/roleDescription/position/size/actions. |
| `maxDepth` | integer | no | Maximum tree depth (default 5) |

### `find_elements`

Search for UI elements by role, title, identifier, description, or visible label text. Returns matches with their paths for use with interaction tools. Use labelContains when you can see the text on screen but don't know which AX attribute carries it (SwiftUI varies).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `labelContains` | string | no | Substring match across title/description/help/value — use when you see the text but don't know where SwiftUI put it |
| `maxResults` | integer | no | Maximum results to return (default 20) |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default 'app'. |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

### `get_element_attributes`

Get all accessibility attributes of a specific UI element found by role and title/identifier

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `identifier` | string | no | Accessibility identifier |
| `role` | string | no | AX role of the element |
| `title` | string | no | Title of the element |

### `get_focused_element`

Report the element that holds the app's INTERNAL keyboard focus (kAXFocusedUIElement) — role, label, value, frame, and enclosing window. Works while the app is in the background (every app keeps its own focus chain even when not frontmost). Use before/after type_text to verify where keystrokes will land.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |

### `wait_for_element`

Wait for a UI element to appear matching the given criteria (all the standard selectors: role/title/titleContains/identifier/value/description/descriptionContains/labelContains/index). Polls until found or timeout. Searches the whole app by default; pass scope:'window' for just the focused window.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `pollInterval` | number | no | Poll interval in seconds (default 0.5) |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default 'app'. |
| `timeout` | number | no | Timeout in seconds (default 10) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

## Assertions

### `assert_visible`

Assert that an element matching the selector is present. Polls until it appears or the timeout elapses. PASS → {passed:true}; FAIL → isError result naming the selector. Use for QA checkpoints (e.g. confirm a dialog/label showed up). Searches the whole app by default; pass scope:'window' to check only the focused window (faster).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default 'app'. |
| `timeout` | number | no | Seconds to poll before failing (default 7) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

### `assert_not_visible`

Assert that NO element matches the selector. Polls for the whole window: passes as soon as the element is absent; fails only if it stays present the entire time. Use to confirm something dismissed (spinner gone, dialog closed). Searches the whole app by default; pass scope:'window' to check only the focused window.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default 'app'. |
| `timeout` | number | no | Seconds to poll waiting for absence before failing (default 7) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

### `assert_value`

Find an element by selector and assert its value/state. Provide one or more of: equals, contains (vs the element's value/title), enabled, focused, checked (toggle/checkbox/radio state). Polls until all provided checks pass or timeout. PASS → {passed:true}; FAIL → isError with expected vs actual.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `checked` | boolean | no | Expected checkbox/radio/toggle state (AX value 1/true) |
| `contains` | string | no | Substring the value/title must contain (case-insensitive) |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `enabled` | boolean | no | Expected enabled state |
| `equals` | string | no | Exact expected value (matched against valueJSON / stringValue / title) |
| `focused` | boolean | no | Expected focused state |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default 'app'. |
| `timeout` | number | no | Seconds to poll before failing (default 7) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

## Text extraction

### `read_text`

Read the text of a single element matched by selector — returns its value/title/label as {text:...}. Errors if no element matches. Use to grab a label, field contents, or status line without a screenshot. Searches the whole app by default; pass scope:'window' for just the focused window.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default 'app'. |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

### `read_all_text`

Read all visible text strings from elements of a given role (default AXStaticText), in tree order, dropping empties. Returns {count, texts:[...]}. Use to verify on-screen content cheaply (e.g. confirm a paragraph or list rendered) instead of a screenshot. Searches the whole app by default; pass scope:'window' for just the focused window.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `maxResults` | integer | no | Max strings to return (default 200) |
| `role` | string | no | AX role to collect (default 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window only — faster) or 'app' (all windows + menu bar). Default 'app'. |

## Input

### `click`

Click a UI element (AX press action) or at screen coordinates. BACKGROUND-SAFE BY DEFAULT: the element path uses AXPress and the coordinate path posts to the target PID — neither moves the user's mouse cursor, brings the app forward, nor steals keyboard focus. For element matching, use role+title/identifier when known; use labelContains when you see the text on-screen but don't know which AX attribute carries it (common with SwiftUI buttons that stash labels in AXDescription). Pass an `elementId` from a prior snapshot/describe_screen to act on that exact element and skip the search. Element searches default to the focused window (scope:'window'); pass scope:'app' to search all windows + menu bar. Set foreground:true ONLY for apps that ignore targeted events (Electron/games) — that activates the app and injects a global click (moves the real cursor).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `elementId` | string | no | Handle id (e.g. 'e7') from a prior snapshot/describe_screen — acts on that element directly, skipping the search |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and injects a global click (moves the real cursor) — use only for apps that ignore PID-targeted events. |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (focused window, default) or 'app' (all windows + menu bar) |
| `timeout` | number | no | Seconds to keep retrying the element find before reporting a miss (default 4) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |
| `x` | number | no | X coordinate (screen points) for coordinate click |
| `y` | number | no | Y coordinate (screen points) for coordinate click |

### `double_click`

Double-click a UI element or at coordinates. BACKGROUND-SAFE BY DEFAULT: prefers two AX press actions; the coordinate fallback posts to the target PID (no cursor move, no activation, no focus steal). Accepts the same matchers as click (role/title/identifier/description/labelContains) plus `elementId` and `scope`. Set foreground:true only for apps that ignore PID-targeted events (activates + global double-click, moves the real cursor).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `elementId` | string | no | Handle id from a prior snapshot/describe_screen — acts on that element directly |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and injects a global double-click (moves the real cursor). |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (default) or 'app' |
| `timeout` | number | no | Seconds to keep retrying the element find (default 4) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |
| `x` | number | no | X coordinate |
| `y` | number | no | Y coordinate |

### `right_click`

Right-click a UI element (AX showMenu) or at coordinates to open a context menu. BACKGROUND-SAFE BY DEFAULT: the element path uses AXShowMenu and the coordinate path posts to the target PID — no cursor move, no activation, no focus steal. Accepts the same matchers as click plus `elementId` and `scope`. Set foreground:true only for apps that ignore PID-targeted events (activates + global right-click, moves the real cursor).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `elementId` | string | no | Handle id from a prior snapshot/describe_screen — acts on that element directly |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and injects a global right-click (moves the real cursor). |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (default) or 'app' |
| `timeout` | number | no | Seconds to keep retrying the element find (default 4) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |
| `x` | number | no | X coordinate |
| `y` | number | no | Y coordinate |

### `type_text`

Type text into the focused element, or into a specific element matched by selector/elementId. BACKGROUND-SAFE BY DEFAULT: for AXTextField/AXTextArea the value is set directly via AX (replaces the field, no keystrokes, no focus steal). When AX-set is rejected (e.g. some SwiftUI fields) the keyboard fallback focuses the control via AX (kAXFocusedAttribute, no app activation) and delivers keystrokes to the target PID — the user's keyboard focus and cursor are never disturbed. By default the fallback CLEARS the field first (Cmd+A then forward-delete) so re-running does not double the text — pass append:true to keep existing content and append instead. Set foreground:true only for apps that ignore PID-targeted keys (activates the app and types via the global HID stream).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `text` | string | yes | Text to type |
| `append` | boolean | no | Keyboard fallback only: when true, keep existing field content and append; when false (default), clear the field first so re-running does not double the text |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `elementId` | string | no | Handle id from a prior snapshot/describe_screen — focuses/sets that element directly |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and types via the global HID stream — use only for apps that ignore PID-targeted keys. |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (default) or 'app' |
| `timeout` | number | no | Seconds to keep retrying the element find (default 4) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

### `send_shortcut`

Send a keyboard shortcut (e.g. Cmd+S, Cmd+Shift+Z) to the app. BACKGROUND-SAFE BY DEFAULT: the chord is delivered to the target PID via postToPid, so it lands in that app's queue WITHOUT bringing it forward, moving the cursor, or stealing the user's keyboard focus. CAVEAT: clipboard/responder-chain chords (Cmd+C/V/X, Select All) need an ACTIVE app and silently no-op in background apps — verify content with read_text/assert_value instead, or activate_app first for paste flows. Set foreground:true only for system-wide hotkeys or apps that ignore PID-targeted chords — that activates the app and posts to the global HID stream.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `key` | string | yes | Key name (e.g. 's', 'z', 'return', 'tab', 'f5') |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and posts the chord to the global HID stream — use for system-wide hotkeys or apps that ignore PID-targeted chords. |
| `modifiers` | array | no | Modifier keys: 'cmd', 'shift', 'opt'/'alt', 'ctrl' |

### `scroll`

Scroll at a specific position within an app window. Use negative deltaY to scroll down, positive to scroll up. BACKGROUND-SAFE BY DEFAULT: the scroll-wheel event is delivered to the target PID with no cursor warp and no app activation — the user's mouse and focus are untouched. Set foreground:true only for apps that ignore PID-targeted scrolls (activates the app, warps the real cursor to the point, and scrolls via the global HID stream).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `deltaY` | number | yes | Vertical scroll amount (negative = down) |
| `x` | number | yes | X coordinate |
| `y` | number | yes | Y coordinate |
| `deltaX` | number | no | Horizontal scroll amount (default 0) |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and scrolls via the global HID stream (moves the real cursor). |

### `scroll_until_visible`

Scroll until an element matching the selector is on-screen. BACKGROUND-SAFE: prefers the native one-call AXScrollToVisible (pure AX, no input events); the wheel-scroll fallback is delivered to the target PID without warping the cursor or activating the app. Re-checks the element's frame against the focused window bounds, up to maxScrolls/timeout. Returns offscreen:true if the element exists but stays outside the window; errors if never found. Set foreground:true only for apps that ignore PID-targeted scrolls (activates + global HID, moves the real cursor).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `description` | string | no | Exact AXDescription match (SwiftUI Button labels often land here) |
| `descriptionContains` | string | no | Partial AXDescription match (case-insensitive) |
| `direction` | string (`down` \| `up`) | no | Scroll direction (default 'down') |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and uses global-HID wheel scrolls for the fallback (moves the real cursor). |
| `identifier` | string | no | Accessibility identifier (.accessibilityIdentifier in SwiftUI) |
| `index` | integer | no | 0-based index to pick the Nth of several identical matches (default first) |
| `labelContains` | string | no | Substring across title/description/help/value — use when you see the text but don't know which AX attribute carries it |
| `maxScrolls` | integer | no | Maximum scroll steps (default 20) |
| `role` | string | no | AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText') |
| `scope` | string (`window` \| `app`) | no | Search scope: 'window' (default) or 'app' |
| `timeout` | number | no | Overall timeout in seconds (default 20) |
| `title` | string | no | Exact AXTitle match |
| `titleContains` | string | no | Partial AXTitle match (case-insensitive) |
| `value` | string | no | Element AXValue |

### `swipe`

Swipe gesture from one point to another (implemented as a mouse drag). BACKGROUND-SAFE BY DEFAULT: the drag events are delivered to the target PID without warping the real cursor or activating the app. NOTE: drags are the least reliable synthetic gesture — many apps poll the real OS pointer mid-drag, so a PID-targeted drag with a stationary cursor can desync; if the gesture doesn't take, set foreground:true to activate the app and drag via the global HID stream (which moves the real cursor).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `endX` | number | yes | End X coordinate |
| `endY` | number | yes | End Y coordinate |
| `startX` | number | yes | Start X coordinate |
| `startY` | number | yes | Start Y coordinate |
| `duration` | number | no | Duration in seconds (default 0.3) |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and drags via the global HID stream (moves the real cursor). |

### `drag_drop`

Drag from one position and drop at another. BACKGROUND-SAFE BY DEFAULT: the drag events are delivered to the target PID without warping the real cursor or activating the app. NOTE: drags are the least reliable synthetic gesture — many apps poll the real OS pointer mid-drag, so a PID-targeted drag with a stationary cursor can desync; if the drop doesn't take, set foreground:true to activate the app and drag via the global HID stream (which moves the real cursor).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `fromX` | number | yes | Source X |
| `fromY` | number | yes | Source Y |
| `toX` | number | yes | Target X |
| `toY` | number | yes | Target Y |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app and drags via the global HID stream (moves the real cursor). |

## Windows

### `list_windows`

List all visible windows, optionally filtered by app

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | no | Bundle ID, app name, or PID (optional, lists all if omitted) |

### `get_window_bounds`

Get the position and size of an app window

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `windowIndex` | integer | no | Window index (default 0) |

### `set_window_bounds`

Set the position and/or size of an app window

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `height` | number | no | Height |
| `width` | number | no | Width |
| `windowIndex` | integer | no | Window index (default 0) |
| `x` | number | no | X position |
| `y` | number | no | Y position |

### `minimize_window`

Minimize an app window to the Dock

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `windowIndex` | integer | no | Window index (default 0) |

### `restore_window`

Restore a minimized window from the Dock

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `windowIndex` | integer | no | Window index (default 0) |

## Screenshots & video

### `screenshot_window`

Capture a screenshot of a specific app window. Works in the background — the window does NOT need to be frontmost and can be fully covered by other windows (capture reads the window's own backing store). Minimized windows cannot be captured (call restore_window first). Disambiguate multi-window apps with windowTitle or windowIndex (index into list_windows order). Returns a JPEG by default (downscaled to keep payloads small); pass format/maxLongestSide/quality to override.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `format` | string (`png` \| `jpeg`) | no | Image format. Default 'jpeg' (typically 20-50x smaller than PNG). |
| `maxLongestSide` | integer | no | Cap the longest image side in pixels, preserving aspect ratio. Default ~1400 to keep payloads small. |
| `maxWidth` | integer | no | Alias for maxLongestSide. |
| `quality` | number | no | JPEG quality 0-1. Default 0.7. Ignored for PNG. |
| `windowIndex` | integer | no | Window index in the app's AX window order (same as list_windows), for windows with duplicate/empty titles |
| `windowTitle` | string | no | Specific window title (optional; default = most plausible main window) |

### `screenshot_element`

Capture a screenshot of a specific UI element by cropping its enclosing window to the element's bounds. Returns a JPEG by default.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `format` | string (`png` \| `jpeg`) | no | Image format. Default 'jpeg' (typically 20-50x smaller than PNG). |
| `identifier` | string | no | Accessibility identifier |
| `maxLongestSide` | integer | no | Cap the longest image side in pixels, preserving aspect ratio. Default ~1400 to keep payloads small. |
| `maxWidth` | integer | no | Alias for maxLongestSide. |
| `quality` | number | no | JPEG quality 0-1. Default 0.7. Ignored for PNG. |
| `role` | string | no | AX role of the element |
| `title` | string | no | Title of the element |

### `screenshot_screen`

Capture a screenshot of the entire screen. Returns a JPEG by default (downscaled to keep payloads small).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `format` | string (`png` \| `jpeg`) | no | Image format. Default 'jpeg' (typically 20-50x smaller than PNG). |
| `maxLongestSide` | integer | no | Cap the longest image side in pixels, preserving aspect ratio. Default ~1400 to keep payloads small. |
| `maxWidth` | integer | no | Alias for maxLongestSide. |
| `quality` | number | no | JPEG quality 0-1. Default 0.7. Ignored for PNG. |
| `screenIndex` | integer | no | Screen index (default 0 = main display) |

### `start_recording`

Start recording a window to a .mov video (H.264, 30fps max) — visual evidence for a QA flow. Works in the background like screenshots (window can be covered; minimized windows won't record). One recording at a time; finish with stop_recording, which returns the file path. Requires macOS 15+.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `windowTitle` | string | no | Specific window title (optional; default = most plausible main window) |

### `stop_recording`

Stop the window recording started with start_recording and finalize the .mov file. Returns {path, seconds}.

_No parameters._

## Menus

### `navigate_menu`

Navigate and click a menu item by path (e.g. ['File', 'Save As...']). BACKGROUND-SAFE BY DEFAULT: the menu hierarchy is resolved by READING the AX tree (no menu ever opens on screen) and only the leaf item is pressed — no cursor move, no app activation, nothing visible. Apps that populate submenus lazily fall back to an AX press-descend walk automatically. CAVEAT: clipboard/responder-chain items (Copy/Paste/Cut/Select All) need an ACTIVE app and can no-op in background apps even when the press reports success — verify the effect (read_text/get_clipboard) or activate_app first. Set foreground:true only for apps that expose their menu bar in the AX tree solely while frontmost.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `menuPath` | array | yes | Array of menu item names (e.g. ['File', 'Save As...']) |
| `foreground` | boolean | no | Default false (background-safe). When true, activates the app first — only needed for apps that populate their menu bar in the AX tree lazily when frontmost. |

### `get_menu_structure`

Get the menu bar structure for an app

| Parameter | Type | Required | Description |
|---|---|---|---|
| `app` | string | yes | Bundle ID, app name, or PID |
| `maxDepth` | integer | no | Maximum depth (default 3) |

## Clipboard

### `get_clipboard`

Read the system clipboard's plain-text contents — verify that a copy/export action in the tested app actually produced the right text. NOTE: the clipboard is SYSTEM-WIDE shared state (the one thing background QA can't isolate); the user may have their own content there.

_No parameters._

### `set_clipboard`

Replace the system clipboard with the given plain text — stage content for a paste step (e.g. set_clipboard then send_shortcut Cmd+V into the tested app). NOTE: this OVERWRITES the user's clipboard (system-wide shared state); use get_clipboard first if their content needs restoring afterwards.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | Text to place on the clipboard |

## Flows

### `run_steps`

Run an ordered list of tool steps inline. Each step is {tool, args}. Returns {ran, failedAt?, results}. With stopOnError (default true) it aborts at the first step whose result isError; otherwise it runs them all. Use to compose multi-step QA flows (click → type → assert).

| Parameter | Type | Required | Description |
|---|---|---|---|
| `steps` | array | yes | Ordered steps. Each: {"tool": "<tool name>", "args": { ... }} |
| `stopOnError` | boolean | no | Abort at the first failing step (default true) |

### `save_flow`

Persist a named flow (ordered list of {tool, args} steps) to disk for later replay with run_saved_flow. Overwrites an existing flow of the same name.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Flow name (used as the filename) |
| `steps` | array | yes | Ordered steps, same shape as run_steps |

### `list_flows`

List the names of saved flows that can be replayed with run_saved_flow.

_No parameters._

### `run_saved_flow`

Load a saved flow by name and run it through the same engine as run_steps. Returns {ran, failedAt?, results}.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Saved flow name |
| `stopOnError` | boolean | no | Abort at the first failing step (default true) |

## System

### `check_permissions`

Check if AgentController has the required macOS permissions (Accessibility and Screen Recording)

_No parameters._

