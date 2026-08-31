#!/bin/bash
# Build the first-party external extensions and install them into
# ~/.config/<product>/extensions/ — exactly the layout any third-party Extension
# uses: a v1 manifest.json + executable, launched with capability-scoped
# CMDY_PORT/CMDY_TOKEN credentials. All use the public SDK/API.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/product-identity.sh

DEST="$HOME/.config/$PRODUCT_CONFIG_DIR_NAME/extensions"
mkdir -p "$DEST"

# A STABLE signing identity so Extensions that use Accessibility / Screen
# Recording (appdock, sim) keep their TCC grants across rebuilds. Ad-hoc
# signing changes the code identity every build and macOS re-prompts forever;
# a real certificate + a stable per-plugin identifier fixes it. Same knob as
# package.sh. Falls back to ad-hoc when no certificate is present.
SIGN_ID="$(product_env_value SIGN_ID "$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application|Apple Development/{print $2; exit}')")"
SIGN_ID="${SIGN_ID:--}"

install_plugin() {
    local name="$1" title="$2" sign="${3:-$SIGN_ID}"
    local capabilities="${4:-\"events.read\",\"commands\"}"
    echo "Building $name..."
    # SwiftPM can retain an old source graph for a local SDK dependency after
    # the SDK adds files. A package clean keeps source-checkout installs
    # deterministic and never touches the Extension's source.
    (cd "Plugins/$name" && swift package clean && swift build -c release)
    local bin="Plugins/$name/.build/release/$name"
    mkdir -p "$DEST/$name"
    # Fresh inode: overwriting a signed binary in place poisons the kernel's
    # code-signing cache and relaunches die with SIGKILL.
    rm -f "$DEST/$name/$name"
    cp "$bin" "$DEST/$name/$name"
    # Stable identifier so the TCC grant survives product-display renames.
    codesign --force --sign "$sign" \
        --identifier "$PRODUCT_CODE_SIGNING_IDENTIFIER_NAMESPACE.$name" \
        "$DEST/$name/$name" 2>/dev/null || true
    # Resource bundles (codio's JS engine) ride along next to the binary.
    for b in "Plugins/$name/.build/release/"*.bundle; do
        [ -e "$b" ] && rm -rf "$DEST/$name/$(basename "$b")" && cp -R "$b" "$DEST/$name/"
    done
    cat > "$DEST/$name/manifest.json" <<EOF
{
  "manifestVersion": 1,
  "id": "$PRODUCT_EXTENSION_IDENTIFIER_NAMESPACE.$name",
  "name": "$title",
  "version": "1.0.0",
  "entrypoint": "$name",
  "enabled": true,
  "capabilities": [$capabilities]
}
EOF
    echo "  installed → $DEST/$name"
}

# Register an Extension's neutral MCP stdio shim with installed AI clients so
# an agent in ANY directory can use it. Claude's default scope is "local"
# (one project directory), so its entry is explicitly user-scoped. Codex MCP
# entries are user-wide by default. Both paths are idempotent.
register_mcp() {
    local component="$1" shim="$2"
    local name="$PRODUCT_SLUG-$component"
    local configured=0
    [ -f "$shim" ] || return 0
    if command -v claude >/dev/null 2>&1; then
        local legacy
        for legacy in "${PRODUCT_LEGACY_SLUGS[@]}"; do
            claude mcp remove "$legacy-$component" -s local >/dev/null 2>&1 || true
            claude mcp remove "$legacy-$component" -s user  >/dev/null 2>&1 || true
        done
        if [ "$component" = "bridge" ]; then
            claude mcp remove bridge -s user >/dev/null 2>&1 || true
        fi
        claude mcp remove "$name" -s local >/dev/null 2>&1 || true  # clear old local-scope entry
        claude mcp remove "$name" -s user  >/dev/null 2>&1 || true  # idempotent re-add
        if claude mcp add --scope user "$name" -- node "$shim" >/dev/null 2>&1; then
            echo "  registered MCP '$name' with Claude Code (user scope)"
            configured=1
        else
            echo "  (Claude registration failed; run: claude mcp add --scope user $name -- node $shim)"
        fi
    fi
    if command -v codex >/dev/null 2>&1; then
        local legacy
        for legacy in "${PRODUCT_LEGACY_SLUGS[@]}"; do
            codex mcp remove "$legacy-$component" >/dev/null 2>&1 || true
        done
        if [ "$component" = "bridge" ]; then
            codex mcp remove bridge >/dev/null 2>&1 || true
        fi
        codex mcp remove "$name" >/dev/null 2>&1 || true
        if codex mcp add "$name" -- node "$shim" >/dev/null 2>&1; then
            echo "  registered MCP '$name' with Codex"
            configured=1
        else
            echo "  (Codex registration failed; run: codex mcp add $name -- node $shim)"
        fi
    fi
    if [ "$configured" -eq 0 ]; then
        echo "  (no supported AI CLI found; register $name with its MCP settings: node $shim)"
    fi
}

install_mcp_identity() {
    local directory="$1"
    cp Identity/Node/product-identity.js "$directory/product-identity.js"
    cp "$PRODUCT_IDENTITY_FILE" "$directory/product-identity.json"
}

install_plugin detox "Detox" "$SIGN_ID" '"events.read","commands","ui.panels"'
install_plugin bridge "Bridge" "$SIGN_ID" '"events.read","panes.read","panes.type","commands","ui.panels","notifications"'
# BraincellBridgeKit carries the neutral stdio MCP server as a resource. Point
# agents at the installed Extension bundle, never the retired plugins/ path.
BRIDGE_MCP_DIR="$DEST/bridge/BraincellBridge_BraincellBridgeKit.bundle/mcp"
install_mcp_identity "$BRIDGE_MCP_DIR"
register_mcp bridge "$BRIDGE_MCP_DIR/index.js"
install_plugin swarm "Swarm" "$SIGN_ID" '"events.read","panes.read","panes.manage","commands","hotkeys","ui.panels","ui.surfaces"'

# appdock — PARKED (temporarily). Its source stays in Plugins/appdock; sim
# supersedes it for the iOS case. Re-enable by uncommenting:
#   install_plugin appdock "AppDock" "$SIGN_ID" '"events.read","commands","hotkeys","ui.panels","ui.companion"'
#   rm -rf "$DEST/appdock/mcp" && cp -R "Plugins/appdock/mcp" "$DEST/appdock/"

install_plugin sim "Sim" "$SIGN_ID" '"events.read","panes.type","commands","hotkeys","ui.panels","ui.companion"'
# sim ships an MCP shim (agents build/run/screenshot the iOS Simulator).
rm -rf "$DEST/sim/mcp" && cp -R "Plugins/sim/mcp" "$DEST/sim/"
install_mcp_identity "$DEST/sim/mcp"
register_mcp sim "$DEST/sim/mcp/index.js"

# chromium is OPTIONAL: it needs the CEF payload (hundreds of MB, not in
# the repo). Bootstrap the pinned source toolchain with
# scripts/bootstrap-chromium.sh; see Plugins/chromium/README-CEF.md.
if [ ! -d "Plugins/chromium/Frameworks/Chromium Embedded Framework.framework" ]; then
    echo "skipping chromium (no CEF payload — see Plugins/chromium/README-CEF.md)"
elif [ "$SIGN_ID" != "-" ]; then
    # Distributed Browser is a complete cmdy edition so CEF can remain in the
    # sandbox-supported app layout. This installer only owns external process
    # Extensions and must not assemble or re-sign that edition in user config.
    echo "skipping chromium (use the signed Browser edition of cmdy)"
    echo "  build: ./scripts/release-chromium-browser.sh"
else
    # Keep the retired sidecar executable as an ad-hoc compatibility wrapper.
    # Source-checkout debug builds also use it as their flat CEF subprocess.
    # Packaged builds use the tiny signed Helper.app stubs in the product app.
    install_plugin chromium "Browser" "-" '"commands"'
    # Browser is a true in-window host component. The executable remains next
    # to the payload as CEF's multi-process helper; the host loads only this
    # small bridge dylib into its own process and parents Chromium to its real
    # center-column NSView.
    plutil -insert hostComponent -string "embedded-chromium" \
        "$DEST/chromium/manifest.json"
    CEF_BRIDGE_ARCHIVE="Plugins/chromium/Frameworks/libcef_bridge.a"
    [ -f "$CEF_BRIDGE_ARCHIVE" ] || {
        echo "chromium bridge is missing; run ./scripts/bootstrap-chromium.sh" >&2
        exit 1
    }
    clang++ -dynamiclib -std=c++20 -ObjC++ -fobjc-arc \
        "Plugins/chromium/Sources/ChromiumHost/ChromiumHostShim.mm" \
        -Wl,-all_load "$CEF_BRIDGE_ARCHIVE" \
        "Plugins/chromium/Frameworks/libcef_dll_wrapper.a" \
        -lc++ -framework AppKit -framework Foundation \
        -install_name "@rpath/libCmdyChromiumHost.dylib" \
        -o "$DEST/chromium/libCmdyChromiumHost.dylib"
    codesign --force --sign "$SIGN_ID" \
        --identifier "$PRODUCT_CODE_SIGNING_IDENTIFIER_NAMESPACE.chromium.host" \
        "$DEST/chromium/libCmdyChromiumHost.dylib" 2>/dev/null || true
    echo "  (in-window Chromium host installed)"

    # The framework rides NEXT TO the binary (rpath @executable_path/Frameworks).
    ln -sfn "$(cd Plugins/chromium/Frameworks && pwd -P)" "$DEST/chromium/Frameworks"
    echo "  (local CEF payload linked)"
    # CEF's GPU subprocess resolves these next to the helper executable.
    for lib in libGLESv2.dylib libEGL.dylib libvk_swiftshader.dylib; do
        ln -sfn "Frameworks/Chromium Embedded Framework.framework/Libraries/$lib" \
            "$DEST/chromium/$lib"
    done
    # MCP stdio shim (auto-registered with Claude Code at user scope below).
    rm -rf "$DEST/chromium/mcp" && cp -R "Plugins/chromium/mcp" "$DEST/chromium/"
    install_mcp_identity "$DEST/chromium/mcp"
    echo "  (MCP shim installed)"
    register_mcp browser "$DEST/chromium/mcp/index.js"
fi

echo "Done. Open View > Extensions to enable or disable them without relaunching."
