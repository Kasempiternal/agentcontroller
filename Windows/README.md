# AgentController for Windows

This directory contains the native Windows backend for AgentController. It exposes the
same MCP-first QA workflow as the macOS app, using Windows UI Automation and
Win32 APIs instead of AXUIElement, CGEvent, and ScreenCaptureKit.

## Current milestone

The Windows server supports the core end-to-end loop:

- app discovery, launch, activation, close, hide/show, and URL opening
- compact snapshots with stable `e1`, `e2`, ... element handles
- selectors compatible with AgentController (`role`, `title`, `identifier`,
  `labelContains`, `index`, and the other existing selector fields)
- element search, attributes, focused element, waits, assertions, and text reads
- background-safe UIA actions for click, toggle, selection, text value, and scroll
- window listing, bounds, move/resize, minimize, and restore
- screen, window, and visible element screenshots
- clipboard access and MCP behavior annotations

The server also advertises explicit error stubs for video recording and generic
app-state reset so agents get a truthful capability result instead of silently
doing the wrong thing.

The current registry contains all 49 AgentController-compatible tools: 46 native
implementations and three explicit unsupported responses.

## Build

Requirements: Windows 10/11 and the .NET 9 SDK or newer.

```powershell
dotnet build .\Windows\AgentController.Windows\AgentController.Windows.csproj -c Release
```

For a distributable executable:

```powershell
.\Windows\build.ps1
```

The default publish output is `Windows\publish\win-x64\agentcontroller-windows.exe`.

Protocol-only smoke and interactive UI Automation integration checks:

```powershell
.\Windows\smoke.ps1
.\Windows\integration.ps1
```

The integration check launches only the disposable `AgentController.Windows.TestApp`
fixture and verifies snapshot, background typing/clicking, all five raw-input
tools, explicit foreground authorization, assertions, and a window screenshot
before closing the fixture.

## Register with an MCP client

The Windows backend uses MCP stdio directly; no HTTP bridge or tray process is
required. Example `.mcp.json`:

```json
{
  "mcpServers": {
    "agentcontroller-windows": {
      "command": "C:\\path\\to\\agentcontroller\\Windows\\publish\\win-x64\\agentcontroller-windows.exe"
    }
  }
}
```

During development, the framework-dependent build can be registered instead:

```json
{
  "mcpServers": {
    "agentcontroller-windows": {
      "command": "dotnet",
      "args": [
        "C:\\path\\to\\agentcontroller\\Windows\\AgentController.Windows\\bin\\Release\\net9.0-windows\\agentcontroller-windows.dll"
      ]
    }
  }
}
```

## Important Windows differences

Windows cannot reproduce every macOS background-input guarantee:

- UI Automation control patterns (`Invoke`, `Value`, `Toggle`, `Selection`,
  `Scroll`) are used first and do not move the pointer.
- If a control exposes no suitable pattern, `click` and `type_text` refuse the
  fallback unless the caller explicitly passes `foreground: true`.
- Foreground input can briefly change focus. The implementation restores the
  previous foreground window and pointer position afterward.
- UIPI blocks lower-integrity processes from automating elevated applications.
  Run the target and AgentController at the same integrity level; do not elevate either
  without a specific reason.
- The desktop must be unlocked. Automation cannot drive the secure UAC desktop.
- `screenshot_window` uses `PrintWindow`; GPU/DirectComposition surfaces may be
  blank in some applications. `screenshot_screen` always reflects visible pixels.

## Platform layout

The repository is now a platform family rather than one binary:

- `Sources/` remains the native Swift/macOS implementation.
- `Windows/AgentController.Windows/` is the native C#/.NET Windows implementation.
- MCP tool names and selector semantics are the portability contract.

The next compatibility tranche is recording, a tray host, and shared contract
tests against both platform backends.
