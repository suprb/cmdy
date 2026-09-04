# chromium plugin — the CEF payload

This Extension needs the Chromium Embedded Framework next to its helper binary:

    Plugins/chromium/Frameworks/
    ├── Chromium Embedded Framework.framework
    ├── libcef_bridge.a          (the compiled cef_bridge.mm)
    ├── libcef_dll_wrapper.a
    ├── CEF-LICENSE.txt
    └── CEF-CREDITS.html         (complete Chromium third-party notices)

For source/ad-hoc development, `plugins.sh` combines the two static bridge
archives into `libCmdyChromiumHost.dylib`. For distribution,
`PRODUCT_BROWSER_EDITION=1 ./package.sh` puts that host library, the pinned CEF
framework, and all four helper apps into `cmdy.app/Contents/Frameworks`. cmdy
passes a real in-window `NSView` to `cef_bridge_create_browser`.
Browser sits in cmdy's native split hierarchy between the terminal and the
outer-right Inspector. It does not create or align a second window.

The framework is intentionally not committed to the main repository. The
canonical public cmdy artifact contains it so Browser can be activated safely;
fast local developer packages omit it. Source builds use the reproducible
bootstrap below, which downloads CEF from the
upstream build service, verifies the archive's SHA-256 digest, builds
`libcef_dll_wrapper`, and compiles the open-source bridge in this repository:

```sh
./scripts/bootstrap-chromium.sh
./scripts/bootstrap-chromium.sh --check
PRODUCT_BROWSER_EDITION=1 PRODUCT_BROWSER_DEFAULT_ENABLED=0 ./package.sh
./scripts/package-browser-extension.sh
```

The pin is CEF `145.0.28+g51162e8+chromium-145.0.7632.160` for Apple silicon.
The generated `Frameworks/` directory is local build state and is ignored by Git.
CEF's license is also tracked at `CEF-LICENSE.txt`; see `CEF-NOTICE.md` for the
reproducible notice policy. The bootstrap check requires both upstream notice
files, and `plugins.sh` keeps them beside the installed framework.

## Agent API (MCP)

The Extension runs a local HTTP API so any agent can drive the embedded page:

    GET  /health
    POST /execute        {"tool": "navigate", "arguments": {"url": "…"}}
                         → {"result": …} | {"error": "…"}

Discovery mirrors cmdy's plugin-api.json: the plugin writes
`~/.config/cmdy/browser-api.json` ({port, token, api}, 0600) on launch;
every route except /health wants `Authorization: Bearer <token>`. Tools:
navigate/back/forward/reload/get_url/get_title/execute_js are native CEF
calls; click/type/find/get_content & co are CSS-selector JS injection, with
eval results returned through the console-callback round-trip. `screenshot`
captures the cmdy window via ScreenCaptureKit and crops it to the embedded
Chromium viewport — macOS will ask for Screen Recording permission the first
time.

When Browser is visible, cmdy owns its bottom control row: back, forward,
reload, close, and URL/search input stay with the shell instead of consuming
browser pixels. `Cmd+L` reaches the row from either Browser or the paired
terminal; `Tab`/`Shift+Tab` select its actions, `Return` activates, and `Esc`
returns to the shell. Annotation is semantic rather than a screenshot markup tool:
click selects one live DOM element; drag selects a region and every meaningful
element intersecting it. The queued record includes selectors, bounds,
accessibility names, useful computed styles, React debug metadata when present,
and Sim Mirror device metadata when the page is `serve-sim`.

Agents speak MCP through the stdio shim. Browser-capable apps keep it at a stable
path inside the app:

    claude mcp add --scope user cmdy-browser -- node /Applications/cmdy.app/Contents/Resources/BrowserMCP/index.js
    codex mcp add cmdy-browser -- node /Applications/cmdy.app/Contents/Resources/BrowserMCP/index.js

Source/ad-hoc installs use
`~/.config/cmdy/extensions/chromium/mcp/index.js` instead. The shim reads the
discovery file, advertises zero tools while Browser is down, and at
thoroughness ≥ 2 auto-appends a screenshot after page-mutating actions.

Environment hooks are optional: `CMDY_BROWSER_PORT` pins the API port (default
4680+) and `CMDY_CHROMIUM_CACHE` relocates the Chromium profile so a second
instance can run beside a live one during diagnostics. The legacy `TERMITE_`
aliases remain accepted for compatibility.

## CEF-free tests

The Browser HTTP transport, local start page, and DOM feedback script live in
the standalone `Support/` package. They can be compiled and tested without a
CEF framework or bridge libraries:

    swift test --package-path Plugins/chromium/Support -c release

The main Chromium package imports that same module, so this exercises shipping
code rather than a test-only copy.

## Signing and helper processes

Browser keeps CEF's macOS sandbox and Chromium's Mach-port peer validation
enabled. There is no `no-sandbox` fallback and no Security.framework result
rewriting. Every renderer/GPU/plugin helper loads `libcef_sandbox.dylib` from
the pinned framework and must enter the sandbox before the CEF framework is
loaded; failure aborts that subprocess.

Debug executables can re-exec a flat helper binary, but a signed `.app` cannot.
Chromium requires type-specific app bundles and otherwise terminates its
renderer with launch error 1003. The Browser-capable app package
(`PRODUCT_BROWSER_EDITION=1 ./package.sh`) builds these four loader bundles into
`cmdy.app/Contents/Frameworks` from
`Sources/ChromiumHost/ChromiumHelper.mm`:

    cmdy Chromium Helper.app
    cmdy Chromium Helper (Renderer).app
    cmdy Chromium Helper (GPU).app
    cmdy Chromium Helper (Plugin).app

Their hardened-runtime signatures use `ChromiumHelper.entitlements` only for
JIT and executable memory. They do not disable Apple library validation. The
canonical release re-signs the complete framework, sandbox library, host, and
helpers with cmdy's Developer ID as one trust domain, then notarizes and staples
the complete app and DMG. Fast local packages may omit this code.
The legacy external `chromium` executable remains the flat subprocess fallback
for consistently ad-hoc source-checkout builds.

CEF 145 cannot load its framework from a different app/Extension directory
after its real renderer/GPU sandbox is applied, even when both bundles share a
Developer ID and valid notary tickets. This is the open upstream external-load
work tracked in https://github.com/chromiumembedded/cef/issues/3940. cmdy does
not work around that with `no-sandbox`, disabled library validation, or altered
signature checks. The supported distribution is therefore one cmdy app with
CEF in the standard internal layout and a small removable `.cmdyext` activation
package. The visible Browser remains a child view in cmdy's split hierarchy.

The full build gate compiles both Swift and Objective-C++ hosts, stress-tests
concurrent lifecycle ordering, and proves that the production helper enters the
pinned sandbox:

```sh
./scripts/bootstrap-chromium.sh
./scripts/check-chromium-build.sh
PRODUCT_BROWSER_EDITION=1 ./package.sh
PRODUCT_NOTARY_PROFILE=cmdy-notary ./release.sh
./scripts/package-browser-extension.sh
```
