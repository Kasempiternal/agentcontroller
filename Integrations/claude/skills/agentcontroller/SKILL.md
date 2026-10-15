---
name: agentcontroller
description: Do it yourself with the AgentController MCP instead of handing the user a step. Use BEFORE asking the user to open a page, log in, paste or fetch a key/token/id, click or approve something in a browser, finish a CLI/OAuth login, check a dashboard or console, reply in a desktop app, or look at an iPhone/simulator — and whenever a task needs Safari, Chrome, a native macOS app or a device. Works in the background with the user's saved logins; never takes focus.
---

# AgentController — operate this Mac yourself

When `mcp__agentcontroller__*` is connected you can drive Safari, Chrome, any native app and
(through `mcp__agentcontroller-ios__*`) simulators and connected iPhones, **in the background**:
the user's frontmost app, cursor and Space never change. Asking the user to do a step this
can do is a failure, not caution.

## 1. Load the tools in one call

```
ToolSearch select:mcp__agentcontroller__open_url,mcp__agentcontroller__snapshot,mcp__agentcontroller__run_steps,mcp__agentcontroller__read_all_text,mcp__agentcontroller__click,mcp__agentcontroller__type_text,mcp__agentcontroller__screenshot_window,mcp__agentcontroller__list_apps,mcp__agentcontroller__wait_for_element,mcp__agentcontroller__launch_app
```

Devices: add `mcp__agentcontroller-ios__get_execution_context,scan_ui,tap_element,device_actions,get_screenshot,wait_for_element,setup_device`.

## 2. The loop

1. `open_url {url, browser:"Safari"|"chrome"}` — or `snapshot {app:"Safari", url}`. Opens in the
   background, waits for the load, uses the user's logins. No browser named → their default (Safari).
   Where it lands: a Chrome started with a debug port takes it as a hidden tab (`"tab":"background"`),
   so nothing the user sees changes — prefer it for pages you open for yourself when it has the
   login. Safari shows it as a new tab of the user's front window (one already in front is reused);
   a "was frontmost" notice means they are looking at it.
2. ONE `snapshot` → element ids. ONE `run_steps` with the whole sequence (`click`, `type_text`,
   `wait_for_element`, `read_all_text`, `screenshot_window`) against those ids.
3. Re-snapshot only when the screen changes shape. A stale id → re-snapshot. `screenshot_window`
   works on background windows; off-Space Safari → read it with `read_all_text`/`snapshot`.
4. After `open_url`, a call that names only the browser (`{app:"Google Chrome"}`) acts on the page
   you just opened.

## 3. Playbooks

| Task | Do this |
|---|---|
| A key/token/id from a dashboard (RevenueCat, App Store Connect, Supabase, Vercel, Stripe test keys…) | Open the page, read it, create the key if the task needs one, store it where the project keeps secrets (Keychain, git-ignored env). Never ask the user to paste it. |
| A CLI login that opens a browser (`wrangler login`, `codex login`, `gh auth login --web`, `vercel login`, `supabase login`, MCP OAuth) | Run the CLI in the background, `open_url` the URL it prints (or let it open, then find the tab), click *Allow/Authorize* with the saved session, read the redirect URL from the page if the CLI wants it pasted. |
| "Paste the address-bar URL here" | Never. Read it: `snapshot` returns the page `url` on Chrome; on Safari read the address field. |
| A form, a console setting, a dashboard check | `snapshot` + one `run_steps`; verify with `read_all_text` or `screenshot_window`. |
| A desktop app (Slack, Telegram/BotFather, Mail, System Settings, Finder, AirDrop) | `launch_app` (background) or target the running app; snapshot; run_steps. |
| Something on the iPhone or a simulator | `get_execution_context` → `setup_device` once per phone → `scan_ui` / `tap_element` / `get_screenshot`. Never ask the user to look at the phone or tap for you. |
| Pixels of a public or local page for QA | `screenshot_window {url, headless:true}` (private headless browser, no logins needed). |

## 4. When the user is genuinely needed

Ask **only** for: a login with no saved session (password not in the browser), 2FA codes, a
captcha, a secret that exists nowhere you can read, a payment or legal acceptance (agreements,
banking, tax), an irreversible action nobody authorised, or anything that needs their ear/hands
(audio, plugging in a device, Face ID). Then ask **once**, with the page already open in the
background, naming the single thing to do — and continue the moment they answer.

Standing user rules still win (which accounts/credentials may be used, never touching prices,
not starting new Apple ID web sessions without saying why).

## 5. Never take focus

Banned: `activate_app`, `foreground:true`, shell `open` without `-g` (URLs go through `open_url`),
`osascript` activate / set frontmost / System Events keystroke or click, `open -a Simulator`,
`bringToFront()` in CDP scripts. The installed PreToolUse hook blocks the shell variants.

## 6. If AgentController looks down

- Tools missing or the server shows *failed*: run `open -g -j /Applications/AgentController.app`,
  then `~/.agentcontroller/bin/agentcontroller status`. A session that started while it was down
  needs a restart to reattach — say so in one line and keep working with what you have.
- `agentcontroller-ios` missing: `~/.agentcontroller/bin/agentcontroller install-claude --check`.
- Never fall back to asking the user to do the step by hand.
