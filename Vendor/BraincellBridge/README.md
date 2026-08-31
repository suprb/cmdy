# cmdy Bridge

Bridge is cmdy's agent-to-app extension. It lets an **MCP-supporting agent**
drive a bound Chromium window, a Mac app built from source, an iOS Simulator,
or an already-running native app. Each cmdy pane owns its session and target;
the agent receives the tools for that binding rather than a global automation
surface.

Stays out of your way the rest of the time.

> **Tested with:** Claude Code (primary). The MCP runtime is protocol-generic.
> Other clients can point at `Sources/BraincellBridge/Resources/mcp/index.js`.

See **[CAPABILITIES.md](CAPABILITIES.md)** for the full tool surface and
concrete examples for each adapter.

## Build & run from source

Bridge is built and distributed with cmdy, not as a second application:

```bash
./package.sh
```

The Swift package keeps the internal `BraincellBridgeKit` module name for
source compatibility. New user-facing text and documentation call the feature
**cmdy Bridge**.

## Local transport security

Bridge listens only on loopback, starting at port 3457 and incrementing if the
port is occupied. Every route that can inspect sessions, inject terminal text,
or drive a target requires a fresh 256-bit bearer token generated for that
Bridge launch. The MCP shim reloads the private `0600` discovery file on every
request so a long-lived client follows token rotation after a restart.
Page-side Inspector code receives a second credential that is valid only for
the explicitly cross-origin composer and thumbnail routes; it cannot call
session, injection, binding, or automation endpoints.

There is no tokenless development mode. Standalone tooling must provide an
explicit 64-hex `BRAINCELL_BRIDGE_TOKEN`, or read the current private token
file via `BRAINCELL_BRIDGE_TOKEN_FILE`. `/health` returns only liveness.

The bearer token prevents drive-by web requests, accidental loopback clients,
and callers running as another account. It is not an isolation boundary from
malicious unsandboxed code already running as the same macOS user: such a
process can inspect that user's files and processes. Treat local code execution
under your account as trusted, and review native Extensions before installing.

## What it does

Two flows.

- **LLM → world.** The LLM runs an MCP tool. The bridge looks up which target the calling terminal is bound to (Chrome via CDP, Mac App via build+spawn+AX, iOS Simulator via simctl+idb, or any running Mac app via NSWorkspace+AX) and dispatches the call there. Multiple LLM sessions can run at once, each isolated to its own target. Native cursor + wire overlay paint Claude's intent on screen for every action.
- **World → agent.** cmdy's feedback controls capture selected UI or a screen
  region and route that context to the exact bound pane.

See [CAPABILITIES.md](CAPABILITIES.md) for the full per-adapter tool list with concrete "ask Claude" examples.

## Status

`TargetAdapter` unifies the four adapters and the cursor/wire feedback layer.
Bindings are ephemeral by design: quitting Bridge, closing the pane, or closing
the target removes the binding.

## Requirements

- macOS 26+ (Tahoe). Earlier versions probably work but are untested.
- Chrome installed (for the Chrome adapter).
- For iOS gestures (`sim_tap` / `sim_swipe` / etc.): `brew install idb-companion && pip3 install fb-idb`. The popover surfaces an inline install hint when missing. Simctl-based tools (screenshot, launch, openurl, install, push) work without it.
- An MCP-supporting agent CLI. Claude Code is the tested integration; other
  clients can register the bundled stdio shim manually.

## Dependencies

[swift-nio](https://github.com/apple/swift-nio) provides the loopback HTTP
server and streaming proxy. Product naming comes from cmdy's shared
`ProductIdentity` package.
