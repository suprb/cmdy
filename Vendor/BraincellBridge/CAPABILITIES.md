# cmdy Bridge — What It Can Do

**93 MCP tools across 4 target adapters**, plus cross-cutting capture and visualization. Any MCP-supporting LLM CLI (Claude Code, Cursor, Cline, Continue, anything Claude-Agent-SDK-built) running in any terminal can drive the surfaces below without leaving its existing setup.

## Targets

### Chrome — 32 tools

Drive any web page Claude has access to.

- **Navigate / observe**: `navigate` `reload` `back` `forward` `screenshot` `get_url` `get_title` `get_content` `get_console` `clear_console` `get_network` `clear_network` `get_failed_requests` `execute_js`
- **Interact**: `click` `type` `hover` `double_click` `right_click` `drag_drop` `scroll` `press_key` `focus`
- **Find / wait**: `find` (DOM scrape + Apple Vision OCR for canvas/SVG text in parallel) `list_interactive` `get_element` `wait_for`
- **Forms**: `get_forms` `fill_form` `submit_form` `select_option` `set_checkbox`

Examples:
- *"Open stripe.com, screenshot the pricing page, then click Contact Sales and fill out the form."*
- *"Find every Cmd-K shortcut on github.com and list them."*
- *"Wait for the Save button to enable, then click it."*

### Mac App — 22 tools

Build + run + drive any Swift Package or Xcode project from source.

- **Lifecycle**: `mac_build` `mac_run` `mac_stop` `mac_console` `mac_clear_console`
- **Observe**: `mac_screenshot` (SCK) `mac_ax_tree` `mac_get_content` (visible text) `mac_get_element`
- **Interact**: `mac_click` `mac_type` `mac_double_click` `mac_right_click` `mac_hover` `mac_scroll` `mac_drag` `mac_focus` `mac_key` (chord parser: `cmd+s` / `shift+cmd+t`) `mac_press_return`
- **Find / wait**: `mac_find` `mac_wait_for` `mac_list_interactive`

Examples:
- *"Build MyApp, run it, click Save, and screenshot the result."*
- *"Type 'hello' in the search field, list every interactive element on screen."*
- *"Wait for the dialog to appear, press Return."*

### iOS Simulator — 23 tools

Drive a booted iPhone/iPad. System-level tools work without idb; gesture tools require `brew install idb-companion && pip3 install fb-idb` (popover surfaces an inline install hint when missing).

- **System (simctl)**: `sim_screenshot` `sim_state` `sim_launch` `sim_terminate` `sim_openurl` `sim_install` `sim_uninstall` `sim_set_appearance` (light/dark) `sim_push` (notification payload)
- **Gestures (idb)**: `sim_tap` `sim_double_tap` `sim_long_press` `sim_swipe` `sim_drag` `sim_pinch` `sim_button` (home / lock / siri / apple-pay) `sim_text` `sim_key` `sim_keys`
- **Find / wait**: `sim_find_element` (via `idb ui describe-all`) `sim_wait_for` `sim_list_interactive` `sim_get_element`

Examples:
- *"Open Settings, turn on dark mode, screenshot."*
- *"Tap the camera button, swipe up, screenshot the photo picker."*
- *"Send a push notification to my app with payload `{aps:{alert:'hi'}}`."*

### Native App — 16 tools

Drive any *already-running* macOS app by bundle id — Slack, Notion, Figma desktop, Things, Bear, Discord, Mail, anything AX-aware.

- **Observe**: `native_screenshot` `native_ax_tree` `native_get_content` `native_get_element`
- **Interact**: `native_click` (CGEvent fallback for Electron `AXPress` no-ops) `native_type` `native_double_click` `native_right_click` `native_hover` `native_scroll` `native_drag` `native_focus` `native_key` `native_press_return`
- **Find / wait**: `native_find` `native_wait_for` `native_list_interactive`

Examples:
- *"Send a message in Slack #general saying 'lunch?'"*
- *"Find every unstarred email in Mail and list the senders."*
- *"Click Reply in the focused Notion page, type my response."*

## Cross-cutting

Works for every adapter:

- **⌘⇧B** — capture selected text from anywhere → choose a Claude session → injected into that terminal.
- **⌘⇧S** — capture a screen region (system region picker) → drop to `/tmp/braincell-bridge-cap-<uuid>.png` → inject `Look at <path>` so Claude reads the image via its Read tool.
- **Asset handoff** — payloads >4KB get pathed instead of pasted (no terminal flooding); `mac_screenshot` / `sim_screenshot` / `native_screenshot` all return paths.
- **Native cursor overlay** — every tool call paints intent on screen: cursor sweep along path, click ripple, double-click (two ripples), right-click (orange ripple), pinch (two finger glyphs), screenshot rect. Cursor lingers as a "Claude is working" beacon for 15s of idle; every tool call heartbeats it back to alive.
- **Wire overlay** — visible glowing wire from each bound terminal to its target window. Hidden window? Click the summon dot to bring it forward.
- **Intent overlay** — bound Chrome shows a labeled ribbon ("click .button" / "screenshot" / etc.) the moment dispatch begins, flashes green/red on success/error.
- **One-click bind** — `+` on any Claude-active terminal → bind. Project-aware default (Swift Package / Xcode project → Mac App; otherwise Chrome). Chevron menu for explicit choice (Chrome, Mac App, iOS Simulator (per-sim picker), Native App). Target dies → binding goes → `+` reappears for fresh re-bind.

## Distribution

Bridge ships as a bundled cmdy Extension. The repository's root `package.sh`
builds and signs the complete app; there is no second Bridge application or DMG.

## Adapter SDK

`Sources/BraincellBridge/Adapters/TargetAdapter.swift` is the protocol every
adapter conforms to. Its small surface (`anchorPid`, `windowFrame()`,
`onTerminated`, and `shutdown() async`) keeps new adapters out of cross-cutting
preflight, lifecycle, and wire-overlay plumbing.
