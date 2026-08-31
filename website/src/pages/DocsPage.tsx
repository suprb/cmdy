import { type ReactNode, useMemo, useState } from "react";
import {
  ActionButton,
  SacredCard,
  SacredWindow,
  SimpleTable,
  TerminalInput
} from "../components/Sacred";

const repo = "https://github.com/suprb/cmdy/blob/main";

function Code({ children }: { children: string }) {
  return <pre className="code-block"><code>{children}</code></pre>;
}

function SourceLink({ file, children }: { children: ReactNode; file: string }) {
  return <a href={`${repo}/${file}`}>{children} ↗</a>;
}

type DocSection = {
  group: "START" | "THE TERMINAL" | "EXTEND IT" | "REFERENCE";
  id: string;
  keywords: string;
  title: string;
  content: ReactNode;
};

const sections: DocSection[] = [
  {
    group: "START",
    id: "model",
    title: "What cmdy is",
    keywords: "terminal extensions actions channels model overview",
    content: <>
      <p><b>cmdy is a terminal with three ways to extend it.</b> Start with the terminal. Add only the kind of extension your work needs.</p>
      <SimpleTable label="Three ways to extend cmdy" data={[
        ["PATH", "USE IT WHEN", "SHORT VERSION"],
        ["Extensions", "a capability should stay running", "add capabilities"],
        ["Actions", "a script, command, or workflow should run once", "perform work"],
        ["Channels", "work should move between cmdy and another app", "move work in and out"]
      ]} />
      <p>Surfaces, the Marketplace, and the first-party examples support these three paths. They are not additional extension systems.</p>
    </>
  },
  {
    group: "START",
    id: "install",
    title: "Install",
    keywords: "build package macos apple silicon setup requirements doctor mcp",
    content: <>
      <p>Requirements: macOS 26+ on Apple silicon. The terminal itself needs no account and no configuration.</p>
      <Code>{`./package.sh
# builds a signed cmdy.app; move it to /Applications`}</Code>
      <p>On first launch, cmdy writes a commented template to <code>~/.config/cmdy/config</code>. Optional Extensions can be installed later; none are required to use the terminal.</p>
      <div className="doc-actions">
        <ActionButton hotkey="↵" href="https://github.com/suprb/cmdy#quick-start">build instructions</ActionButton>
        <ActionButton hotkey="G" href="https://github.com/suprb/cmdy">view source</ActionButton>
      </div>
    </>
  },
  {
    group: "START",
    id: "tour",
    title: "Five-minute tour",
    keywords: "command blocks splits tabs palette session restore attention shortcut",
    content: <ul className="doc-list">
      <li><b>Type first.</b> zsh shell integration is injected automatically.</li>
      <li><b>Commands become blocks.</b> Jump with <kbd>⌘↑</kbd>/<kbd>⌘↓</kbd>; click a command row to type it again.</li>
      <li><b>Split freely.</b> <kbd>⌘D</kbd> right, <kbd>⌘⇧D</kbd> down, <kbd>⌘T</kbd> tab, <kbd>⌘]</kbd>/<kbd>⌘[</kbd> focus.</li>
      <li><b>Find anything.</b> <kbd>⌘⇧P</kbd> opens a fuzzy palette for terminal commands, Actions, and Extension commands.</li>
      <li><b>Resume.</b> Windows, splits, working directories, and scrollback return after relaunch.</li>
      <li><b>Follow attention.</b> <kbd>⌘⇧U</kbd> jumps to the next pane asking for you.</li>
    </ul>
  },
  {
    group: "EXTEND IT",
    id: "platform",
    title: "Choose one of three paths",
    keywords: "extensions actions channels model lifecycle platform",
    content: <>
      <p>Choose the smallest path that fits the job. The distinction is about what the addition does, not how much code it contains.</p>
      <SimpleTable label="cmdy extension paths" data={[
        ["NEED", "USE"],
        ["Listen to terminal events, add commands, or keep a tool running", "Extension"],
        ["Run a script, command, or pane workflow once", "Action"],
        ["Receive work from another app and optionally return a reviewed result", "Channel"]
      ]} />
      <Code>{`Extensions add capabilities.
Actions perform work.
Channels move work in and out.`}</Code>
      <p>A Channel is implemented by an Extension, and a Surface is something an Extension can show. Those implementation details do not add more choices to the model. <SourceLink file="PLATFORM.md">Read the complete platform model</SourceLink>.</p>
    </>
  },
  {
    group: "EXTEND IT",
    id: "actions",
    title: "Actions",
    keywords: "scripts commands workflows menus palette shortcut action json trust project",
    content: <>
      <p><b>Use an Action when something should run once.</b> An Action turns a script, command, or pane workflow into a menu item, palette result, or shortcut. Personal Actions live in <code>~/.config/cmdy/actions/</code>; project Actions live in <code>.cmdy/actions/</code> and require project trust.</p>
      <Code>{`cmdy action install-starters
cmdy action new ~/.config/cmdy/actions/deploy-preview
cmdy action validate ~/.config/cmdy/actions/deploy-preview
cmdy action list
cmdy action run deploy-preview --input environment=staging`}</Code>
      <p>The opt-in starter pack adds five editable personal workflows: continue Claude, inspect a Git project, preview a folder on loopback, watch listening ports, and copy a concise handoff note. It never replaces an existing Action or folder.</p>
      <p>An optional <code>action.json</code> adds factual guide copy, inputs, choices, confirmation, context rules, shortcuts, and right/down pane workflows. Commands are inserted as real terminal input, so output, history, command blocks, and Extension hooks remain intact. <SourceLink file="ACTIONS.md">Read the Actions guide</SourceLink>.</p>
    </>
  },
  {
    group: "EXTEND IT",
    id: "extensions",
    title: "Extensions",
    keywords: "extension sdk protocol capabilities http json sse events hooks hotkeys panels panes companion",
    content: <>
      <p><b>Use an Extension when a capability should stay running.</b> It can listen to semantic events, add commands and shortcuts, change supported decisions, or show native interfaces. An Extension is a separate program, so it never links into the renderer or terminal core.</p>
      <Code>{`cmdy extension new ./hello-cmdy
cmdy extension validate ./hello-cmdy
cmdy extension dev ./hello-cmdy
cmdy extension install ./hello-cmdy`}</Code>
      <Code>{`{
  "manifestVersion": 1,
  "id": "dev.example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "entrypoint": "extension.py",
  "capabilities": ["events.read", "commands", "ui.surfaces"]
}`}</Code>
      <h3>Capability groups</h3>
      <SimpleTable label="Extension capability groups" data={[
        ["GRANT", "WHAT IT ALLOWS"],
        ["events.read", "semantic command, pane, window, theme, and attention events"],
        ["panes.read / type / manage", "inspect, enter input, and compose pane lifecycles"],
        ["commands / hotkeys", "register owned palette commands and shortcuts"],
        ["ui.panels / surfaces / companion", "native panels, structured UI, or an attached app"],
        ["channels", "register sources, ingest Work Items, receive approved replies"],
        ["hooks", "continue, replace, or cancel bounded decisions"],
        ["notifications / marketplace.install / debug", "independently granted authority"],
      ]} />
      <p>Every object belongs to one launch. Exit revokes the token and removes its commands, hotkeys, hooks, panels, Surfaces, and insets. <SourceLink file="EXTENSIONS.md">Build an Extension</SourceLink> · <SourceLink file="EXTENSION_PROTOCOL.md">Protocol v1</SourceLink>.</p>
    </>
  },
  {
    group: "REFERENCE",
    id: "surfaces",
    title: "Extension UI: Surfaces",
    keywords: "surface native ui table diff task form text structured accessibility",
    content: <>
      <p>A Surface adds a live list, table, diff, task view, form, or text view to a semantic command block. cmdy owns typography, colors, focus, controls, and accessibility; the producer sends structured data and stable IDs, never HTML or arbitrary drawing.</p>
      <Code>{`git diff | cmdy surface diff --id working-tree --title "Working tree"
jq -c '.[]' data.json | cmdy surface table --id records --title "Records"
my-test-json | cmdy surface task --id tests --title "Tests"`}</Code>
      <p>The adapter echoes stdin before attaching UI, so every pipeline remains useful in another terminal, over SSH, in CI, or redirected to a file. <SourceLink file="SURFACE_PROTOCOL.md">Surface Protocol v1</SourceLink>.</p>
    </>
  },
  {
    group: "EXTEND IT",
    id: "channels",
    title: "Channels",
    keywords: "channels sdk connector slack telegram discord matrix imessage mastodon github linear jira mail webhook rss ntfy clipboard reminders work inbox outbox receive route reply agent shell drafts marketplace",
    content: <>
      <p><b>Use a Channel when work starts in another app.</b> A connector turns an external request into a reviewable Work Item. You choose what happens, inspect the result, and separately approve any reply.</p>
      <Code>{`provider → Channel Extension → durable Work Inbox
                                  ↓
                         read · agent · shell · ignore
                                  ↓
                           private result draft
                                  ↓ user confirms
                         connector sends + acknowledges`}</Code>
      <h3>Build a connector</h3>
      <Code>{`cmdy channel new ./my-channel
cmdy extension validate ./my-channel
cmdy extension dev ./my-channel

cmdy channel list
cmdy channel items
cmdy channel replies
cmdy channel doctor [channel-id]`}</Code>
      <p>A Channel is packaged as an Extension with the <code>channels</code> capability. Guided setup stores secrets in Keychain and keeps incomplete connectors stopped. Drafts stay private until you approve a send, and there are no automatic replies. <SourceLink file="CHANNELS.md">Read the complete Channel contract, safety model, and SDK guide</SourceLink>.</p>
    </>
  },
  {
    group: "REFERENCE",
    id: "first-party",
    title: "Extension examples",
    keywords: "detox swarm browser sim bridge demo inbox reference extensions panes agents chromium simulator mcp",
    content: <>
      <p>These optional packages show how far an Extension can go. They use the same public protocol available to everyone and are not required parts of the terminal.</p>
      <SimpleTable label="First-party Extensions" data={[
        ["PACKAGE", "WHAT IT PROVES", "STATE"],
        ["Detox", "commands + native editor driving WebAudio", "LIVE"],
        ["Swarm", "agent sessions + selected/all live-pane composition", "LIVE"],
        ["Browser", "sandboxed Chromium + local automation", "SOURCE / AD-HOC"],
        ["Sim", "Simulator build, run, input, logs, capture, reload", "LIVE"],
        ["Bridge", "product-scale MCP runtime across several targets", "LIVE"],
        ["Channel catalog", "19 installable provider, feed, and local-workflow connectors", "LIVE"]
      ]} />
      <p>Browser ships as an optional, separately signed and notarized cmdy edition so CEF can stay inside the app layout required by Chromium&apos;s macOS sandbox. The lean edition remains small, both editions share the same settings and sessions, and app updates preserve the edition you installed. The incompatible v1 Marketplace artifact is withheld. Open Extensions with <kbd>⌘⇧L</kbd> to inspect purpose, creator, version, source, grants, and runtime state. Distributable Marketplace packages use pinned hashes and explicit native-code consent.</p>
    </>
  },
  {
    group: "REFERENCE",
    id: "cmdy-cli",
    title: "The cmdy helper",
    keywords: "cmdy cli helper surface action marketplace channel command line",
    content: <>
      <p><code>cmdy</code> is the app and its command-line entry point for scripting Actions, Surfaces, Extensions, Channels, Marketplace operations, inline images, and notifications.</p>
      <Code>{`cmdy action list
cmdy channel items
cmdy marketplace list
cmdy surface table --id build-status --title "Build"
cmdy show photo.png
cmdy notify "Build complete"`}</Code>
    </>
  },
  {
    group: "REFERENCE",
    id: "lib_cmdy",
    title: "lib_cmdy (internal C ABI)",
    keywords: "lib cmdy c abi internal parser grid renderer vt",
    content: <>
      <p><code>lib_cmdy</code> is an internal C ABI over cmdy’s Swift terminal engine. It is tested and narrow, but it is not the public Extension boundary. External tools should use Protocol v1 or the optional SDK.</p>
      <p>This separation keeps third-party code out of PTY callbacks and the Metal frame loop while allowing the engine to evolve independently.</p>
    </>
  },
  {
    group: "THE TERMINAL",
    id: "config",
    title: "Configuration",
    keywords: "config file settings font theme shader opacity blur cursor restore",
    content: <>
      <p>cmdy reads <code>~/.config/cmdy/config</code>. The command palette exposes the same settings with live previews; comments and unknown keys remain intact when the app saves a value.</p>
      <SimpleTable label="Selected configuration keys" data={[
        ["KEY", "EXAMPLE", "PURPOSE"],
        ["font-family", "Geist Mono", "terminal typeface"],
        ["font-size", "14", "grid text size"],
        ["theme", "cmdy-dark", "color palette"],
        ["shader", "breath", "background fragment shader"],
        ["background-opacity", "0.94", "window transparency"],
        ["background-blur", "24", "behind-window blur"],
        ["cursor-style", "block", "block, beam, or underline"],
        ["option-as-meta", "true", "send Option combinations as terminal Meta/Esc sequences"],
        ["shell-integration", "true", "mark commands for blocks, durations, navigation, and notifications"],
        ["restore-session", "true", "restore windows and scrollback"],
        ["marketplace-update-checks", "true", "daily Extension version check"]
      ]} />
      <SourceLink file="README.md">See the complete configuration reference</SourceLink>.
    </>
  },
  {
    group: "THE TERMINAL",
    id: "editor",
    title: "Text editor",
    keywords: "editor native text palette configuration extension panel",
    content: <p>cmdy includes a native text editor for config files, user shaders, Actions, and Extension-provided editor panels. Changes to themes and shaders preview live; saving a user shader recompiles it in place and reports diagnostics without replacing a working shader with a broken build.</p>
  },
  {
    group: "THE TERMINAL",
    id: "keys",
    title: "Keyboard",
    keywords: "keyboard shortcuts keys copy paste split tab palette fullscreen zoom attention",
    content: <SimpleTable label="Core keyboard shortcuts" data={[
      ["KEY", "ACTION"],
      ["⌘T / ⌘W", "new tab / close pane or tab"],
      ["⌘D / ⌘⇧D", "split right / split down"],
      ["⌘] / ⌘[", "focus next / previous pane"],
      ["⌘↑ / ⌘↓", "previous / next command block"],
      ["⌘⇧P", "command palette"],
      ["⌘⇧L", "Extensions window"],
      ["⌘⇧U", "next attention request"],
      ["⌘+ / ⌘- / ⌘0", "zoom in / out / reset"],
      ["⌃⌘F", "toggle full screen"]
    ]} />
  },
  {
    group: "THE TERMINAL",
    id: "blocks",
    title: "Command blocks",
    keywords: "command blocks osc 133 shell integration exit status output navigation",
    content: <>
      <p>OSC 133 shell integration gives each command a semantic boundary: prompt, command, output, exit code, and completion time. Blocks power navigation, rerun, fixes, bounded Channel results, Extension events, and session restoration.</p>
      <p>cmdy does not guess completion from screen text. Shell-mode Channel work finishes only when its associated command block exits.</p>
    </>
  },
  {
    group: "THE TERMINAL",
    id: "attention",
    title: "Attention signals",
    keywords: "attention notification bell background tab dock badge agent",
    content: <p>A background agent or process can request attention without stealing focus. cmdy marks its tab, window, and Dock icon; <kbd>⌘⇧U</kbd> moves to the next request. Extensions may observe semantic attention events only with <code>events.read</code>.</p>
  },
  {
    group: "THE TERMINAL",
    id: "shaders",
    title: "Shaders",
    keywords: "metal shaders fragment gpu live preview marketplace share fork",
    content: <>
      <p>User shaders are Metal fragment programs compiled with cmdy’s fixed preamble and bounded inputs. Marketplace browsing previews them against your live pane; Escape restores the prior shader and Return installs it.</p>
      <Code>{`cmdy marketplace install cmdy/breath
cmdy share ~/.config/cmdy/shaders/my-shader.metal`}</Code>
      <p>A malformed shader reports compiler diagnostics and cannot replace the last valid program.</p>
    </>
  },
  {
    group: "THE TERMINAL",
    id: "themes",
    title: "Themes + fonts",
    keywords: "themes fonts colors rigs marketplace config appearance",
    content: <p>Themes are data-only color palettes; rigs combine theme, shader, font, border, and cursor settings in one shareable preset. Both preview live in the Marketplace. Fonts are selected by installed family name and remain a local choice.</p>
  },
  {
    group: "THE TERMINAL",
    id: "ai",
    title: "AI, optional",
    keywords: "ai agent claude codex pi optional shell safety review",
    content: <>
      <p>cmdy does not require an AI provider. Claude, Codex, and Pi are ordinary terminal programs with optional integrations. Agent Mode improves session semantics and bridges, but every proposed command is still visible, editable, and submitted only when you press Return.</p>
      <p>Channels delimit external text as untrusted task context; it is never silently pasted into the shell.</p>
    </>
  },
  {
    group: "REFERENCE",
    id: "proof",
    title: "How the engine was proven",
    keywords: "tests fuzz conformance parser snapshot benchmark engine proof ship",
    content: <>
      <p>The VT parser/grid core is exercised independently of AppKit through conformance cases, fuzz input, snapshots, and C ABI tests. Renderer and host tests cover glyph placement, damage, pane lifecycle, restoration, protocols, package validation, and trust boundaries.</p>
      <p>The reference Extensions and first-party Channel catalog are end-to-end proofs: they install through the public package path and exercise the same capability checks as third-party code.</p>
    </>
  }
];

const sectionOrder = [
  "model", "install", "tour",
  "blocks", "keys", "config", "editor", "attention", "themes", "shaders", "ai",
  "platform", "extensions", "actions", "channels",
  "surfaces", "first-party", "cmdy-cli", "lib_cmdy", "proof"
];

const groupOrder: DocSection["group"][] = ["START", "THE TERMINAL", "EXTEND IT", "REFERENCE"];

export function DocsPage() {
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase();
  const visible = useMemo(() => sections.filter((section) => {
    if (!normalizedQuery) return true;
    return `${section.title} ${section.keywords}`.toLocaleLowerCase().includes(normalizedQuery);
  }).sort((left, right) => sectionOrder.indexOf(left.id) - sectionOrder.indexOf(right.id)), [normalizedQuery]);
  const groups = groupOrder.filter((group) => visible.some((section) => section.group === group));

  return (
    <div className="docs-page page-shell">
      <aside className="docs-sidebar" aria-label="Documentation sections">
        <div className="sidebar-head">
          <span>cmdy Docs</span>
          <span className="docs-version">v1</span>
        </div>
        <TerminalInput
          aria-label="Filter documentation sections"
          onChange={(event) => setQuery(event.currentTarget.value)}
          placeholder="filter the manual"
          type="search"
          value={query}
        />
        <nav>
          {groups.map((group) => (
            <div className="docs-nav-group" key={group}>
              <span>{group}</span>
              {visible.filter((section) => section.group === group).map((section) => (
                <a href={`#${section.id}`} key={section.id}>{section.title}</a>
              ))}
            </div>
          ))}
        </nav>
      </aside>

      <div className="docs-content" id="top">
        <div className="docs-mobile-tools">
          <TerminalInput
            aria-label="Filter documentation sections"
            onChange={(event) => setQuery(event.currentTarget.value)}
            placeholder="filter the manual"
            type="search"
            value={query}
          />
          <label className="docs-mobile-nav">
            <span className="visually-hidden">Browse documentation</span>
            <select
              aria-label="Browse documentation"
              defaultValue=""
              onChange={(event) => {
                if (event.currentTarget.value) window.location.hash = event.currentTarget.value;
              }}
            >
              <option disabled value="">browse docs</option>
              {groups.map((group) => (
                <optgroup label={group} key={group}>
                  {visible.filter((section) => section.group === group).map((section) => (
                    <option value={section.id} key={section.id}>{section.title}</option>
                  ))}
                </optgroup>
              ))}
            </select>
          </label>
        </div>
        <header className="docs-intro">
          <h1>cmdy Docs</h1>
          <p>cmdy is a terminal with three ways to extend it: Extensions add capabilities, Actions perform work, and Channels move work in and out.</p>
        </header>

        {visible.length ? visible.map((section, index) => (
          <section className="doc-section" id={section.id} key={section.id}>
            <div className="doc-section-number" aria-hidden="true">{String(index + 1).padStart(2, "0")}</div>
            <SacredWindow>
              <SacredCard mode="left" title={section.title}>
                <div className="doc-copy">{section.content}</div>
              </SacredCard>
            </SacredWindow>
          </section>
        )) : (
          <SacredWindow className="docs-empty">
            <p>No manual section matches “{query}”.</p>
            <ActionButton hotkey="ESC" onClick={() => setQuery("")}>clear filter</ActionButton>
          </SacredWindow>
        )}
      </div>
    </div>
  );
}
