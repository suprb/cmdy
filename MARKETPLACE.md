# the cmdy marketplace

Shaders, themes, rigs, Channel connectors, and Extensions: community work that is browsable and
installable without leaving the terminal. The registry, native browser,
installation pipeline, live enable/disable controls, and command-line client
are implemented. This document records the product and trust model plus the
remaining publishing work.

## Why it will feel different

Every marketplace shows you screenshots of the thing. cmdy can show you
the thing: shaders and themes are text, the app already hot-compiles user
shaders on save and re-skins live, and the palette already previews built-in
shaders while you arrow through them. So here, **browsing IS
previewing** — your own terminal restyles in real time as you move through
community content, with your text, your font, your session. ⏎ keeps it.
That's the demo moment, and it only works because the safe kinds are pure
data.

The second thing: the publish loop lives in the terminal too. Fork a shader,
edit it (save = live reload), and `cmdy share` opens the pull request. Edit →
see → publish in one sitting. A store is a mall; this is a scene.

## What's in it

| kind | format | trust | preview | install target |
|---|---|---|---|---|
| shader | one `.metal` file (`cmdy_main`) | **safe by construction** — fragment math, no I/O | live, full pane | `~/.config/cmdy/shaders/` |
| theme | one theme file (existing format) | safe — colors | live | `~/.config/cmdy/themes/` |
| rig | config preset: theme+shader+font+border+cursor as one file | safe — known keys only | live + diff panel before apply | applied via ConfigFile |
| patch | Detox instrument (JS for the synth's WKWebView) | sandboxed-ish — audible, not ambient | play it | Detox library |
| Channel | v1 Extension archive, registry `kind: channel`, manifest grants `channels` | **native code** — same consent and OS trust as an Extension | metadata + author + repo | `~/.config/cmdy/extensions/<id>/` |
| Extension | v1 `manifest.json` + entrypoint (+ payload), zipped | **native code** — scoped cmdy capabilities, but OS-level trust is still required | metadata + author + repo | `~/.config/cmdy/extensions/<id>/` |

Rigs matter more than they look: people screenshot their terminals
constantly — a rig is the shareable behind the screenshot. One link
reproduces the whole look.

## The registry

One git repo, `cmdy-registry`:

- `registry.json` — every entry: `kind`, `id` (reverse-DNS for Extensions,
  `author/name` for content), `name`, `description` (one line, has to earn
  its place), `author`, `license`, `version`, optional `homepage` (the public
  source/project URL), and per-kind fields. `repository` and `repo` remain
  accepted aliases for existing registries.
- Native entries may add `guide.whatItDoes`, `guide.safety`, and `guide.setup`
  string arrays. These are concrete pre-install facts, not promotional copy:
  data read or changed, reply and execution boundaries, requested authority,
  and the configuration required before the package can start. Older entries
  receive a conservative guide from their kind, mode, setup, and first-party
  package contract.
- **Content kinds live IN the repo** (`shaders/`, `themes/`, `rigs/`,
  `patches/`) — a contribution is one PR with one file. Lowest possible
  friction; this is where the community starts.
- **Extensions and Channel connectors are pointers**: GitHub Release asset URL + a
  required 64-hex `sha256` + min `sdk` version + arch. Big assets (chromium's
  CEF) use a `payload` `{url, sha256}` field with its own required 64-hex
  digest. Missing or malformed native-code digests fail before any download.
- CI validates every PR: schema, license present, `xcrun metal -c` compiles
  each shader, themes parse, Extension URLs and hashes resolve. A `channel`
  entry must request the `channels` capability. Merged = published.
  Malware response is `git revert` — the index is the truth on every fetch.
- No backend, no accounts, no stars. Curation replaces ratings: a `featured`
  rotation in the index ("this week's calm"), editorial like a zine. PRs are
  the submission queue and the review is a diff. If scale ever demands a
  real service, the client contract (fetch one JSON) doesn't change.

## In the terminal

- Palette → **"Browse the Marketplace…"** → the existing InlinePanel in tabs mode
  (the Config Mixer grammar): Shaders / Themes / Rigs / Patches / Channels /
  Extensions.
  Wheel-wrap navigation, filter-as-you-type.
- Shaders/themes/rigs preview live on selection (shader source hot-compiled
  exactly like user shaders; esc reverts, ⏎ installs). Rigs show a config
  diff panel before applying.
- Extension/Channel install: require pinned 64-hex sha256 → download → verify → unpack → **fresh inode +
  ad-hoc re-sign** (the kernel code-sign cache trap) → quarantine xattr
  dropped only after an explicit consent line naming author + repo →
  enable. Every Extensions-window row offers Download or Update when applicable;
  the window can also install all missing or updated Extensions with one consent step,
  and its switches start or stop each process immediately.
- Everything also scriptable: `cmdy marketplace install <id>`,
  `cmdy marketplace install-all`,
  `cmdy marketplace update`,
  and `POST /v1/marketplace/install` — agents can install tools mid-task with
  the user's consent. The marketplace is part of the SDK surface.

## Publishing

- `cmdy share` — takes the current user shader / theme / rig, prefills
  attribution and license, and opens the registry PR (gh CLI when present,
  web URL fallback).
- "Fork" on any marketplace shader copies it to `~/.config/cmdy/shaders/`
  with an attribution header and opens it in the editor — save and the
  terminal restyles. Remix culture is the point; the license field keeps it
  honest.
- The founding content is ours: the built-in calm shader set exported as
  forkable sources, the bundled themes, and signed first-party Extensions.
  Browser v1 is permanently withheld. Browser's independent signed/notarized
  release is a complete cmdy edition because current CEF requires its runtime
  inside the host app for the macOS sandbox.

## Trust, in tiers

- **Tier 0 (shaders, themes, rigs)**: data, not code. A shader can at worst
  look bad or run slow. Install friction: none. This is deliberate — the
  safe tier is where creativity compounds.
- **Tier 1 (patches)**: JS inside the synth's WKWebView — audio scope only.
- **Tier 2 (Extensions)**: arbitrary native executables, with the same honest
  operating-system trust model as Homebrew. v1 mitigations are a curated index,
  pinned hashes, consent screens, and one capability-scoped token per launch.
  The manifest declares exact grants (`events.read`, `commands`, `ui.surfaces`,
  `panes.read`, `panes.type`, `ui.companion`, and others); cmdy enforces route
  access and owner isolation. The UI can truthfully say, for example, “this
  Extension cannot type into your terminal.” Capabilities constrain cmdy's
  API, not arbitrary native OS access.
  Channel connectors are Tier 2 Extensions with a discoverable Marketplace
  label; `kind: channel` does not imply a stronger sandbox.

## The web mirror

The generated `site/dist/marketplace.html` renders the last-known registry snapshot
from `site/public/marketplace-data.js` immediately, then refreshes from the
public registry in the background. Live data remains the source of truth; the
generated copy keeps discovery working when GitHub is blocked, the visitor is
offline, or the static page is opened locally. Refresh the source snapshot
whenever the public registry changes.
Theme cards read their real palettes when available; rigs read their actual
config; shader cards clearly defer the live effect to cmdy instead of
pretending a static thumbnail is the shader. The site is discovery for people
who don't have cmdy yet; every card ends in the same line:
`cmdy marketplace install author/name`.

## Build order

1. **Registry repo + schema + CI** (validation incl. shader compile), seeded
   with the calm set, built-in themes, and the three Extensions.
2. **The marketplace panel**: tabs, live preview for content kinds, install/revert.
3. **Extension pipeline**: hash/quarantine/re-sign/enable + payload assembly
   (chromium is the proving ground).
4. **Publish loop**: fork, `cmdy share`, attribution headers.
5. **Web gallery** generated from the registry.
6. **Protocol hardening**: capability-scoped tokens, route ACLs, ownership, and
   lifecycle cleanup are shipped; update notifications and featured rotation remain.

Steps 1–2 are the soul; 3 makes it a real package manager; 4 makes it a
community; 5 makes it marketing; 6 makes it trustworthy at scale.

## Implementation status

The host, installer, authoring tools, and static gallery are implemented in this
source tree. The canonical public `cmdy-registry` repository contains the
reviewed package files and pinned hashes used by both the app and website.

- **Registry tooling** includes a schema, CI validator that compiles every
  shader, and a pack-plugin tool. The public snapshot contains the calm set as
  forkable sources, four themes, two rigs, distributable first-party
  Extensions, and nineteen Channel connectors. The legacy registry endpoint
  remains as a compatibility bridge for cmdy 1.0.0 and resolves native packages
  from the canonical public registry.
  Browser ships as a separately signed/notarized cmdy edition rather than a
  Marketplace payload. Current upstream CEF cannot safely load its framework
  from an external Extension under the macOS renderer/GPU sandbox; the old v1
  archive is not a compatible fallback.
- **In-app**: palette / View ▸ Browse the Marketplace… — sections per kind,
  live shader/theme try-on (previews are real installs, reverted and deleted
  on esc), remembered section positions, rig safe-preview, Extension consent +
  progress panel, and a separate Channel connector section. The Extensions
  window shows purpose, creator, installed version,
  and runtime state, compares registry and installation-receipt versions, and exposes
  per-row source links plus Download, Update, and Remove actions.
- **CLI**: `cmdy marketplace list | install <id> | install-all | update`
  (`--registry` override for local checkouts), `cmdy share` opens the
  prefilled registry PR for the current user shader.
- **Agents**: `POST /v1/marketplace/install {id, consent?}` — async, outcome
  streams on `/v1/events` as `kind: marketplace`; native code demands
  explicit consent.
- Gated: sha256 tamper → refusal; fresh-inode + re-sign + de-quarantine
  verified; marketplace-installed detox launches; Demo Inbox installs through
  the same pipeline, registers its owned Channel, and ingests its welcome Work
  Item; all 30 exported shaders compile against the app's real user-shader preamble.
- **Updates**: marketplace-installed Extensions are checked against the registry
  at most once daily. The Extensions menu and palette show the current count;
  each new version set raises one notification, and the check can be disabled in
  Settings or with `marketplace-update-checks = false`. Source-only installs do
  not trigger automatic registry access.

The deployable web gallery is generated into `site/dist/`; it prefers the public
registry and falls back to its checked-in last-known snapshot for browsing.
Extension and Channel rows include the CLI install command plus a direct,
hash-pinned ZIP link for manual download and source inspection. The CLI or
in-app action remains the verified, consented installation path. Browser links
to the complete signed Browser-edition release instead of pretending Chromium
can be installed as an ordinary Extension archive.
Pending: the patches kind, which needs a Detox library format.
Capability-scoped tokens and route ACLs are complete.
