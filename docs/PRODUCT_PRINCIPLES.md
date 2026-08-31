# cmdy: a terminal you can reshape

Status: product and architecture direction, July 2026.

## Platform milestone: 2026-07-17

The programmable-terminal direction is now represented by working public
contracts rather than only a proposal:

- **Extension Protocol v1** has typed manifests, capability-scoped credentials,
  owner-isolated resources, private callbacks, deterministic decision hooks,
  trusted project discovery, and automatic lifecycle cleanup.
- **Surface Protocol v1** has native list, table, diff, task, form, and text
  components; stable command-block identity; sequenced patches; semantic
  actions; text fallback; and explicit resource budgets.
- **Authoring** includes `cmdy extension new`, `validate`, `install`, `list`,
  `dev`, `trust`, `untrust`, and `trusted`. Development sessions watch and
  restart source while cleaning up after heartbeat loss.
- **Compatibility** preserves legacy plugin manifests, paths, discovery files,
  and environment variables while all new UI and examples use “Extension.”
- **Ordinary commands** can opt into native UI through `cmdy surface` while
  their input remains canonical stdout.
- **Actions** turn a personal or trusted project script, command, or pane
  workflow into a native menu, palette entry, form, and app-scoped shortcut.
- **Channels** are the shipped third layer: a capability-scoped connector
  contract, durable Work Inbox and Outbox, typed SDK, native routing UI, agent
  and shell result drafts, explicit reply delivery, and Marketplace category.

The durable references are `PLATFORM.md`, `EXTENSIONS.md`, `ACTIONS.md`,
`CHANNELS.md`, `EXTENSION_PROTOCOL.md`, `SURFACE_PROTOCOL.md`, and the
machine-readable shipped contracts in `Schemas/`.

Future work should extend these versioned contracts only when real extensions
need it. It should not reopen the PTY or Metal hot paths to third-party code.

This document is intentionally written for readers who do not already know
terminal or plugin architecture. Technical terms are explained where they
first appear.

## The one-sentence idea

**cmdy is a fast native terminal you can reprogram while it is running.**

A normal terminal is a finished appliance. Its maker decides what commands
look like, what happens after a command finishes, which applications it can
connect to, and which workflows belong inside it.

cmdy should instead be an excellent default terminal built on a small,
reliable core, with a simple platform that lets people change the behavior
above that core without rebuilding the app.

The short public explanation is:

> cmdy is a native GPU terminal you can build on. Extensions add resident
> capabilities, Actions run personal workflows, and Channels bring
> selected work in from other applications and send reviewed results back.

## A simple analogy

Think of cmdy as a very fast car with a carefully protected engine.

- The engine is the terminal core: process input/output, terminal rules, text,
  windows, and GPU rendering.
- Extensions are replaceable instruments and controls attached around it.
- The Extension Protocol is the agreed wiring between the engine and those
  controls.
- A Surface is a small piece of native interface an extension can ask cmdy
  to draw, such as a table, diff, progress view, or set of actions.

An extension should be able to change the experience. It should not be able to
put untrusted code inside the engine or slow down every character being drawn.

## Why Pi feels open

Pi is not open merely because it supports plugins. Pi gives extensions a say
in its decisions.

An extension can add or replace a tool, intercept lifecycle events, change a
prompt, add a model provider, change how results render, or replace parts of
the editor. A single TypeScript file can be loaded directly, changed, and
reloaded. A project can carry its own Pi resources. Pi deliberately leaves
several workflows out of its core rather than choosing one approach for
everyone.

That produces three feelings:

1. **The program belongs to you.** The author's workflow is not the only one.
2. **Changing it is immediate.** There is little distance between an idea and
   seeing it work.
3. **The mechanism is visible.** Files, commands, events, and packages are not
   hidden behind a large product surface.

Pi's useful lesson for cmdy is not “use TypeScript” or “add AI.” It is:

> Ship a strong default, but make the product an instance of the platform
> rather than the only possible version of it.

## Where cmdy is today

The base is a dedicated VT engine, a native Metal renderer, and a GPU-owned
display path. Above that base, Extension Protocol v1 now gives
separate processes capability-scoped HTTP/JSON access from any language.

Extensions can own commands, hotkeys, panels, native Surfaces, decision hooks,
events, and companion-window space. They can be enabled or disabled live,
installed from the marketplace, loaded temporarily with restart-on-save, or
trusted per project. Bridge, Browser, Sim, Detox, and Swarm use the same public
API as third parties.

Actions provide the smaller one-shot path: drop in a script, or describe a
command and pane workflow with inputs, confirmation, context, and a shortcut.
They execute through real terminal input, so ordinary output, history, command
blocks, and Extension hooks remain intact. Channels add the reviewed external
work loop without granting connectors permission to run or send on their own.

The important inversion of control is implemented at five deliberate policy
boundaries: command submit, paste, pane split, pane close, and notification.
cmdy asks registered hooks in deterministic order; an Extension may
continue, replace, or cancel. Strict deadlines and fail-open behavior keep an
unhealthy Extension from making the terminal unhealthy.

This is a credible programmable-terminal foundation. Its next test is not how
many endpoints exist, but whether independent authors can create useful,
surprising behavior with very little code.

## Is the position unique?

### The honest answer

“A fast terminal with plugins” is not unique.

- Ghostty is a fast native terminal with extensive configuration.
- WezTerm has Lua configuration, plugins, events, and callbacks that can stop
  default actions.
- Kitty has Python kittens and a large remote-control protocol.
- iTerm2 has a mature Python API for sessions, windows, prompts, selection,
  status bars, and custom control sequences.
- Zellij has permissioned WebAssembly plugins that can draw UI and control its
  terminal workspace.
- Wave has graphical widgets controlled from its shell command.

cmdy should never claim that it invented extensible terminals.

### The position cmdy can own

No established product clearly owns this complete combination:

1. A small macOS-native terminal emulator and Metal renderer built as one
   coherent core.
2. Extensions in any language, running outside the terminal process.
3. Hooks that let extensions safely participate in terminal decisions.
4. Native, theme-aware surfaces attached to ordinary command output.
5. Standard stdout remaining present and correct when an extension is absent.
6. Project-local, shareable behavior with a very fast edit/reload loop.
7. A one-shot Action path for useful custom behavior that does not need a
   resident process or SDK.
8. A strict refusal to turn the default terminal into a busy IDE dashboard.

That is a defensible position:

> **The programmable native terminal.**

Or, in language that is easier to understand:

> **A terminal you can reshape.**

This is not guaranteed to become a large project. The idea only becomes
special if the implementation is simpler, faster, and more coherent than the
systems above. The opportunity is real; the claim must be earned.

## What belongs in the core

The core is the part that must remain fast and extremely dependable:

- PTY process input and output.
- VT escape-sequence parsing and terminal compatibility.
- Scrollback and the cell model.
- Text shaping, glyph caching, images, and Metal drawing.
- Keyboard, mouse, paste, accessibility, and input-method correctness.
- Window, pane, and process lifecycle.
- Extension authentication, ownership, and cleanup.
- The stable protocol definitions.

These operations happen for every byte, cell, or frame. They must never wait
for a plugin HTTP request.

## What should become extendable

Policies and workflows happen at slower, meaningful boundaries. Those are safe
places to ask extensions what should happen.

Examples:

```text
command.willRun         continue, replace, or cancel the command
command.didFinish       add actions, metadata, or a Surface
pane.willCreate         change directory, environment, or profile
paste.willSend          continue, replace, or cancel pasted text
link.willOpen           choose how a link or file is handled
notification.received   transform, suppress, or redirect it
window.didChange        observe movement, focus, hiding, and closure
```

Hooks that may change an action need a short deadline and a safe default. If an
extension is slow or dead, cmdy continues normally.

The rule is:

> **Open the policy plane. Protect the hot loop.**

## A small public vocabulary

Plugin, add-on, integration, package, workflow, and app should not
all compete for the same job. cmdy uses three author-facing terms because
they describe three genuinely different lifecycles:

| Term | Status | Meaning |
|---|---|---|
| **Extension** | Shipped | An installed resident process that listens, changes bounded behavior, or hosts a mini app. |
| **Action** | Shipped | A script, command, or pane workflow that runs when a person invokes it. |
| **Channel** | Shipped | A connected external source that receives reviewable work and retains an address for explicitly approved replies. |

The compact model is:

```text
Extensions add capabilities.
Actions perform work.
Channels move work in and out.
```

An Extension may contain commands, event listeners, decision hooks, native
Surfaces, a companion application, and optional settings. A Channel connector
is distributed as an Extension, but people connect an account as
a Channel and see its requests as Work Items. Packaging and product experience
do not need the same name.

Surface, SDK, Marketplace, workspace, Inbox, and Outbox are supporting
primitives or interfaces—not additional ways to package behavior. Schedules and
event rules should remain composition between the three layers until durable
retry, audit, and cancellation semantics—and multiple proven workflows—show
that another public model is actually necessary.

## The three things an extension can do

The entire mental model should fit in one line:

> **Listen. Change. Show.**

1. **Listen:** learn that a command finished, a pane opened, or a window moved.
2. **Change:** continue, replace, or cancel a supported cmdy action.
3. **Show:** attach a native action, list, table, diff, form, or progress view.

The SDK and documentation should be organized around those three verbs.

## The Extension Protocol

The Extension Protocol is the shared language between cmdy and external
Extensions. It keeps HTTP/JSON's language independence while adding the reverse
direction needed for policy decisions.

Version 1 provides:

- A machine-readable manifest schema and documented HTTP contract.
- Events for observation.
- Request/response hooks for decisions.
- Registration of commands, actions, handlers, and settings.
- Per-extension identity and automatic resource cleanup.
- Declared capabilities such as `panes.read`, `panes.type`, `ui.surfaces`, and `hooks`.
- Deadlines, cancellation, and deterministic ordering.
- Versioned manifests, additive compatibility rules, and contract tests.

Do not stream every PTY byte or rendered cell through it. Extensions should
receive semantic events, not the renderer's internal workload.

## The Surface Protocol

The Surface Protocol is the visual half of the idea.

Normally a command prints characters. cmdy must always keep those characters
as the canonical record. An extension may additionally attach structured data
that cmdy renders with native controls.

Examples:

- `git status` keeps its text and gains a navigable file list with Diff and
  Stage actions.
- A test run keeps its log and gains a failed-test list with Retry actions.
- A deployment keeps its output and gains progress, service links, and a
  rollback action.
- An agent keeps its terminal transcript and gains checkpoints, permissions,
  and branch actions.

If the extension is disabled, the command is still a normal command. If the
same program runs over SSH or in another terminal, stdout still works.

Version 1 deliberately starts with a small set of native primitives:

- Actions.
- List and table.
- Diff.
- Progress and tasks.
- Simple input and confirmation.

Do not build a second web browser or a general layout framework. cmdy owns
spacing, typography, keyboard behavior, accessibility, colors, and rendering.
Extensions provide meaning and data. This keeps every Surface coherent and
fast.

## The authoring experience

The shortest path from idea to working Extension is:

```sh
cmdy extension dev ./my-extension.py
```

cmdy then:

1. Launch the file with temporary credentials.
2. Make its commands or Surfaces available immediately.
3. Watch its files.
4. Restart it on save.
5. Remove everything it registered when it exits or heartbeats stop.
6. Streams its concise logs back to the development command.

No installation and no permanent manifest should be required for development.
A shebang executable, Python, JavaScript, Swift, Rust, or any other language
should work through the same protocol.

Projects can also carry trusted local behavior:

```text
.cmdy/
  extensions/
```

Opening a project containing executable cmdy resources shows one clear trust
prompt with the requested capabilities. Approved project Extensions then load
while any pane is inside that project and can be committed for a team.

This is how cmdy gains Pi's “change it here and reload” feeling without
copying Pi's in-process TypeScript architecture.

## Why separate processes are an advantage

Pi extensions are powerful because they run inside Pi. cmdy should not copy
that part blindly.

An extension process is a separate small program. This provides:

- Crash isolation: the terminal survives a broken extension.
- Language freedom: the author is not forced into Swift or Lua.
- Capability enforcement: cmdy can prove what the extension may access.
- Easy cleanup: commands, hotkeys, Surfaces, and insets belong to one process.
- Performance isolation: extension work stays outside the rendering loop.

This can make cmdy more open while remaining more robust.

## What to prove next

The authoring loop, Extension Protocol v1, Surface Protocol v1, Action model,
and Channel manual loop
described in the original roadmap are implemented. Do not answer that milestone
by building more showcase applications. Bridge, Browser, Sim, Detox, and Swarm
already demonstrate breadth. Channels now need real provider connectors and
field evidence before their scope grows.

The next phase is evidence and adoption:

1. Keep every first-party extension on explicit v1 capabilities.
2. Exercise the public contracts with small examples and compatibility tests.
3. Move additional visible policy out of `App/` only when doing so improves a
   real workflow; never move PTY or Metal work out merely to prove extensibility.
4. Build provider connectors through the public Channel SDK, keeping incoming
   data untrusted and every route/send action manual in v1.
5. Publish repeatable performance and crash-isolation demonstrations.
6. Keep the MIT repository, CI, contribution guide, schemas, and compatibility
   policy current from a clean checkout.

If a first-party extension needs private authority, or a broken extension can
stall the terminal, the platform contract is not deep enough yet.

## The demonstration that can travel online

Architecture does not spread by itself. People need to see the result in less
than a minute.

A strong demonstration is:

1. Open a normal, extremely fast cmdy window.
2. Run one command that loads a small extension file.
3. Run tests and watch the ordinary output gain a native failed-test Surface.
4. Edit ten lines of the extension and save.
5. The Surface changes immediately without rebuilding or restarting cmdy.
6. Disable the extension and reveal the untouched standard terminal output.

The message is not “look at our plugin manager.” It is:

> **The terminal was a fixed application. Now it is a medium.**

AI can make this more powerful because an agent can write a small extension in
response to a request. AI must not be required. The system is useful because
the protocol is simple and open; AI merely shortens the creation time.

## What would impress serious builders

No serious technical leader will be impressed by the words “GPU” and “plugins”
alone. Both already exist.

The impressive result would be visible leverage:

- A small, readable core with clear ownership boundaries.
- Terminal correctness and latency equal to the best terminals.
- A 20-line extension that creates behavior previously requiring an app fork.
- Live reload without state leaks.
- Native UI without a web runtime.
- An extension crash that leaves the terminal untouched.
- A permission screen that can truthfully say, for example, “this extension
  can read command results but cannot type into your terminal.”
- First-party features using exactly the same public API as everyone else.

That makes someone think: “Of course the terminal should have been a runtime,
not a sealed window.”

It is possible to earn that reaction. It cannot be designed as a reaction or
guaranteed for particular people.

## What cmdy must refuse

A tight point of view is defined by refusal.

cmdy should refuse:

- A mandatory AI account or built-in AI workflow.
- Replacing standard stdout with proprietary content.
- Arbitrary extension code inside the PTY or Metal hot path.
- A default screen full of dashboards, cards, and sidebars.
- A different visual language for every extension.
- Hidden permissions or an unreviewable native-code trust story.
- Dozens of overlapping public terms and APIs.
- Performance claims not backed by repeatable tests.
- Shipping platform abstractions before two real extensions need them.

cmdy with no extensions must remain an excellent terminal. Extensions
should make it personal, not make the base product incomplete.

## Risks

The main risks are not competitors. They are loss of focus and loss of trust.

1. **Terminal compatibility:** users abandon a terminal after small rendering,
   input, SSH, or TUI failures. Correctness comes before platform spectacle.
2. **API instability:** an ecosystem will not form around a moving contract.
3. **Complexity:** a Surface system can accidentally become a second browser or
   IDE framework.
4. **Security:** native extensions run as the user unless capabilities and
   sandboxing become real enforcement.
5. **Latency:** synchronous hooks in the wrong path can destroy the reason for
   the GPU core.
6. **Discoverability:** powerful architecture without tiny examples will feel
   like infrastructure work, not possibility.
7. **Scope:** supporting every operating system too early would weaken the
   native macOS experience that currently makes cmdy concrete.

## The final point of view

cmdy is not primarily “the fastest terminal,” although it must be fast.
It is not “the AI terminal,” although agents should be able to use it. It is
not “a terminal with apps,” although extensions may include applications.

The point of view is:

> **The terminal should be small, native, and excellent by default, but its
> behavior should belong to the person using it.**

The GPU core earns trust. The Extension Protocol gives control. The Surface
Protocol makes that control visible. MIT and a public repository make the
ownership real.

That is a coherent project worth pursuing.

## Primary references reviewed

- [Pi philosophy and extensions](https://pi.dev/)
- [Pi packages](https://pi.dev/docs/latest/packages)
- [WezTerm plugins](https://wezterm.org/config/plugins.html)
- [WezTerm events](https://wezterm.org/config/lua/wezterm/on.html)
- [Kitty custom kittens](https://sw.kovidgoyal.net/kitty/kittens/custom/)
- [Kitty remote control](https://sw.kovidgoyal.net/kitty/remote-control/)
- [iTerm2 Python API](https://iterm2.com/python-api/)
- [Zellij plugin API](https://zellij.dev/documentation/plugin-api-commands)
- [Wave custom widgets](https://docs.waveterm.dev/customwidgets)
- [Ghostty configuration philosophy](https://ghostty.org/docs/config)
