# Contributing to AgentController

Thanks for taking a look. This project automates other people's applications on
three operating systems, so a bug here doesn't just fail a test — it can move a
real user's cursor or steal their focus mid-sentence. The conventions below
exist mostly to prevent that.

## The one rule that matters: background by default

AgentController's defining promise is that a QA run does not disturb the person
using the machine. Their focus, cursor, clipboard selection, and frontmost
window survive the entire run.

Concretely, that means:

- On **macOS**, input is delivered per-process (`CGEvent.postToPid`) or through
  pure accessibility actions. Screenshots read a window's own backing store, so
  a window can be covered or hidden and still be captured.
- On **Windows**, UI Automation patterns run without moving the pointer. The
  five raw-input gestures are the exception: they require explicit
  `foreground:true` authorization and must restore the prior focus and cursor
  afterwards.
- `activate_app` and `foreground:true` are last resorts, not conveniences.

**A change that makes a tool steal focus where it previously did not is a
breaking change**, even if every test still passes. If you genuinely need
foreground access, gate it behind explicit authorization and restore what you
took.

## Repository layout

| Path | What it is |
|---|---|
| `Sources/` | macOS backend — Swift, AXUIElement, CGEvent, ScreenCaptureKit |
| `Windows/` | Windows backend — C#/.NET, UI Automation, Win32 `SendInput` |
| `iOS/` | iOS backend — TypeScript/Node, `idb`, WebDriverAgent |
| `Scripts/` | Contract and release checks |
| `docs/TOOLS.md` | Generated-by-hand tool reference, kept honest by CI |

The desktop backends **share no code**. They are independent implementations of
one tool contract, which is exactly why that contract is machine-checked.

## The tool contract

`Scripts/check-tool-contract.sh` is the load-bearing check in CI, and the first
thing to run locally:

```bash
./Scripts/check-tool-contract.sh
```

It enforces that:

- both desktop backends register **the same** set of tool names;
- `docs/TOOLS.md` documents every registered tool and no others;
- the `iOS/README.md` tool table matches the iOS registry;
- every tool description in the docs matches the string in the source;
- every `N tools` claim written in prose equals a real registry count.

That last one is stricter than it sounds and it is deliberate: a stale number in
a README is a small lie that survives for years. If you are describing a
*historical* count that is intentionally not the current one — "the surface grew
from ten to 36" — spell the old number as a word so it reads as prose rather
than as a claim about today.

**Adding a tool** means touching all of: the Swift registry, the C# registry,
`docs/TOOLS.md`, and — if it applies to phones — the iOS registry and its README
table. If a platform genuinely cannot support it, register it there anyway and
return an explicit unsupported error explaining the limitation. Silently missing
tools break the portability promise; honest errors do not.

## Running the checks

```bash
# Contract + docs (fast, no toolchain needed)
./Scripts/check-tool-contract.sh
shellcheck --severity=warning build.sh Scripts/*.sh

# macOS backend — CI builds release with warnings as errors
swift build -c release -Xswiftc -warnings-as-errors
swift test

# iOS backend
cd iOS && npm ci && npm run typecheck && npm run build

# Windows backend (on Windows)
dotnet build Windows\AgentController.Windows\AgentController.Windows.csproj -c Release
.\Windows\smoke.ps1
```

CI runs all of the above. `Windows/integration.ps1` drives real UI Automation
against the test fixture and needs an interactive desktop, so it stays a local
pre-release step rather than a CI job.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
`<type>[optional scope][!]: <description>`, imperative mood, lowercase, no
trailing period.

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `revert`. Breaking changes get a `!` and a `BREAKING CHANGE:`
footer. If a change spans multiple types, split it into separate commits.

Explain **why** in the body, not what — the diff already says what.

## Security

Please do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

Be especially careful with anything that touches the transport (loopback
binding, the per-launch bearer token, DNS-rebinding defenses) or that spawns a
child process. Child processes take **argument arrays**, never interpolated
shell strings.

## Licensing and provenance

Contributions are accepted under the [Apache License 2.0](LICENSE). The `iOS/`
subtree additionally carries its upstream MIT license, which is retained as
required.

If you bring in third-party code, say so in the pull request and add it to
[NOTICE](NOTICE) — that file propagates to redistributors under Apache-2.0
section 4(d), so it is where attribution has to live to be durable. Read NOTICE
before assuming something here is original; it records what came from
[Maestro](https://github.com/mobile-dev-inc/maestro) (design) and from
[blitzdotdev/iPhone-mcp](https://github.com/blitzdotdev/iPhone-mcp) (code).
