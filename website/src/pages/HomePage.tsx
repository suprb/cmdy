import type { ReactNode } from "react";

const releaseURL = "https://github.com/suprb/cmdy/releases/latest";

type FeatureExample = {
  description: string;
  name: string;
};

type Feature = FeatureExample & {
  examples?: FeatureExample[];
};

type FeatureGroup = {
  features: Feature[];
  id?: string;
  label: string;
};

const featureGroups: FeatureGroup[] = [
  {
    label: "Terminal",
    features: [
      { name: "Metal terminal", description: "own VT engine, crisp grid-snapped GPU rendering" },
      { name: "Full-screen TUIs", description: "correct mouse scrolling and alternate-screen behavior" },
      { name: "Inline images", description: "iTerm2, Kitty graphics, sixel, and cmdy show" },
      { name: "Command blocks", description: "command, output, status, duration, navigation, rerun and copy stay together" },
      { name: "Search + palette", description: "scrollback search and fuzzy access to commands, settings and history" },
      { name: "Smart input", description: "ghost-text history autocomplete" },
      { name: "Sessions + Workspaces", description: "restore automatically or save, update and reopen named window, tab, split and directory snapshots" },
      { name: "Appearance", description: "pane-owned fonts, themes and shaders with first-pane window chrome, plus live config, opacity, blur, inset, cursor and optional SID sounds" },
      { name: "Keybinding import", description: "preview and safely import Ghostty, tmux, iTerm2 and Terminal maps without replacing native shortcuts" },
      { name: "Native editor", description: "config, Markdown, source and plain text in a window or terminal split" }
    ]
  },
  {
    label: "Windows + Workflow",
    features: [
      { name: "Native tabs + splits", description: "AppKit tabs, arbitrarily nested panes and spatial focus" },
      { name: "Automatic window grid", description: "arrange, reorder and resize native windows using Window Inset as the gap" },
      { name: "Grid ↔ splits", description: "preserve the exact layout while combining windows or breaking splits apart" },
      { name: "Drag + merge", description: "dock windows and torn-out tabs as splits or tabs without stopping shells" },
      { name: "Adaptive frame", description: "tabs sidebar, contextual inspector and focus mode" },
      { name: "Attention", description: "mark waiting panes, tabs, windows and the Dock without stealing focus" }
    ]
  },
  {
    label: "Intelligence",
    features: [
      { name: "Command intelligence", description: "ask, compose, explain and fix with every command visible and reviewable" },
      { name: "Agent mode", description: "proposes one shell step at a time; the user presses Return" },
      { name: "Automatic error help", description: "inline explanations and reviewable fixes" }
    ]
  },
  {
    id: "platform",
    label: "Platform",
    features: [
      {
        name: "Extensions",
        description: "resident, capability-scoped tools with native UI surfaces",
        examples: [
          { name: "Browser", description: "source-only sandboxed Chromium for ad-hoc development" },
          { name: "Sim", description: "iOS Simulator split or live mirror with build, input and capture" },
          { name: "Swarm", description: "find, follow and gather live agent sessions" },
          { name: "Bridge", description: "MCP runtime spanning browser, macOS, Simulator and native apps" },
          { name: "Detox", description: "optional live-coding modular synth inside the terminal" }
        ]
      },
      { name: "Actions", description: "one-shot scripts, commands and multi-pane workflows" },
      {
        name: "Channels",
        description: "reviewable work in and separately approved results out",
        examples: [
          { name: "Slack", description: "one selected channel through the reviewed inbox" },
          { name: "iMessage", description: "allowlisted conversations with explicitly approved replies" },
          { name: "GitHub Issues", description: "allowlisted issues and comments as reviewable work" },
          { name: "Webhook Inbox", description: "authenticated JSON webhooks with approved callbacks" },
          { name: "RSS and Atom Feed", description: "read-only feed polling" },
          { name: "Apple Reminders", description: "incomplete items from allowlisted lists" }
        ]
      },
      { name: "Marketplace", description: "install and update themes, shaders, rigs, Extensions and connectors" },
      { name: "Updates", description: "stable GitHub releases auto-download, verify SHA-256, and wait for user install" },
      { name: "Open source", description: "native Swift + AppKit macOS app with public SDK and protocols" }
    ]
  }
];

const features = featureGroups.flatMap((group) => group.features);

function Case({ children }: { children: ReactNode }) {
  return <span className="case">{children}</span>;
}

function FeatureList() {
  return (
    <ul className="feature-list">
      {features.map((feature) => (
        <li className="feature-item" key={feature.name}>
          <b>{feature.name}</b>
          <span aria-hidden="true">: </span>
          {feature.description}
          {feature.examples && (
            <div className="feature-examples">
              <span className="feature-examples-label">Including</span>
              <ul>
                {feature.examples.map((example) => (
                  <li className="feature-example" key={example.name}>
                    <b>{example.name}</b>
                    <span aria-hidden="true">: </span>
                    {example.description}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </li>
      ))}
    </ul>
  );
}

export function HomePage() {
  return (
    <div className="home-page">
      <header className="hero">
        <div className="wrap">
          <h1>A terminal turned platform.</h1>
          <div className="ctas">
            <a className="btn solid" href={releaseURL}>Download for{" "}<Case>macOS</Case></a>
            <a className="btn ghost" href="https://github.com/suprb/cmdy">View source</a>
          </div>
        </div>
      </header>

      <section className="product-showcase" aria-label="cmdy product demonstration">
        <div className="wrap">
          <div className="hero-video-grid">
            <video className="hero-vid" autoPlay loop muted playsInline preload="metadata" poster="./hero-poster.jpg" aria-label="cmdy terminal product demonstration, primary sequence">
              <source src="./hero-4x-13-20.av1.mp4" type="video/mp4; codecs=av01.0.05M.08" />
              <source src="./hero-4x-13-20.h264.mp4" type="video/mp4; codecs=avc1.640028" />
            </video>
            <div className="hero-video-secondary-grid">
              <video className="hero-vid" autoPlay loop muted playsInline preload="metadata" poster="./hero-poster.jpg" aria-label="cmdy terminal product demonstration, secondary sequence one">
                <source src="./hero-4x-08-12.av1.mp4" type="video/mp4; codecs=av01.0.05M.08" />
                <source src="./hero-4x-08-12.h264.mp4" type="video/mp4; codecs=avc1.640028" />
              </video>
              <video className="hero-vid" autoPlay loop muted playsInline preload="metadata" poster="./hero-poster.jpg" aria-label="cmdy terminal product demonstration, secondary sequence two">
                <source src="./hero-4x-20-23.av1.mp4" type="video/mp4; codecs=av01.0.05M.08" />
                <source src="./hero-4x-20-23.h264.mp4" type="video/mp4; codecs=avc1.640028" />
              </video>
            </div>
          </div>
        </div>
      </section>

      <section className="feature-inventory" id="features">
        <div className="wrap feature-inventory-inner">
          <FeatureList />
        </div>
      </section>
    </div>
  );
}
