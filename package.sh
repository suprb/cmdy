#!/bin/bash
# Build the canonical product as a signed, double-clickable macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/product-identity.sh
source scripts/package-resource-policy.sh

APP="$PRODUCT_APP_BUNDLE"
BIN=".build/release/$PRODUCT_EXECUTABLE"
PROJECT_VERSION="$(tr -d '[:space:]' < VERSION)"
VERSION="$(product_env_value VERSION "$PROJECT_VERSION")"
BUILD_NUMBER="$(product_env_value BUILD_NUMBER 1)"
BROWSER_EDITION="${PRODUCT_BROWSER_EDITION:-0}"
REQUIRE_CHROMIUM_HELPERS="${PRODUCT_REQUIRE_CHROMIUM_HELPERS:-$BROWSER_EDITION}"
BROWSER_DEFAULT_ENABLED="${PRODUCT_BROWSER_DEFAULT_ENABLED:-0}"

if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "PRODUCT_VERSION must contain two or three numeric components (for example 1.2.0)" >&2
    exit 2
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "PRODUCT_BUILD_NUMBER must be a numeric build identifier" >&2
    exit 2
fi
if [ "$REQUIRE_CHROMIUM_HELPERS" != "0" ] \
   && [ "$REQUIRE_CHROMIUM_HELPERS" != "1" ]; then
    echo "PRODUCT_REQUIRE_CHROMIUM_HELPERS must be 0 or 1" >&2
    exit 2
fi
if [ "$BROWSER_EDITION" != "0" ] && [ "$BROWSER_EDITION" != "1" ]; then
    echo "PRODUCT_BROWSER_EDITION must be 0 or 1" >&2
    exit 2
fi
for value_name in BROWSER_DEFAULT_ENABLED; do
    value="${!value_name}"
    if [ "$value" != "0" ] && [ "$value" != "1" ]; then
        echo "PRODUCT_${value_name} must be 0 or 1" >&2
        exit 2
    fi
done
if [ "$BROWSER_EDITION" != "$REQUIRE_CHROMIUM_HELPERS" ]; then
    echo "Browser edition and Chromium-helper packaging must match exactly." >&2
    exit 2
fi

echo "Building release..."
swift build -c release

echo "Generating icon..."
ICONSET="$PRODUCT_ICON_BASENAME.iconset"
ICON="$PRODUCT_ICON_BASENAME.icns"
rm -rf "$ICONSET" "$ICON"
"$BIN" --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON"
rm -rf "$ICONSET"

echo "Assembling ${APP} ..."
rm -rf "${APP}"
COMPONENT_SWITCH_HELPER_NAME="$PRODUCT_TITLE_NAME Component Helper"
COMPONENT_SWITCH_HELPER_APP="${APP}/Contents/Helpers/$COMPONENT_SWITCH_HELPER_NAME.app"
COMPONENT_SWITCH_HELPER="${COMPONENT_SWITCH_HELPER_APP}/Contents/MacOS/$PRODUCT_SLUG-component-helper"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" \
    "${COMPONENT_SWITCH_HELPER_APP}/Contents/MacOS"
cp "${BIN}" "${APP}/Contents/MacOS/$PRODUCT_EXECUTABLE"
# The restart/swap process must remain outside the app bundle while that bundle
# is atomically replaced. A copy of the app's signed main executable is not a
# valid standalone program: its code signature binds Contents/Info.plist, so
# macOS kills the detached copy in a real Developer-ID build. Package this
# second copy as a complete, independently signed helper app so its bundle and
# notarization identity survive the move to per-user Application Support.
cp "${BIN}" "$COMPONENT_SWITCH_HELPER"
chmod 755 "$COMPONENT_SWITCH_HELPER"
cat > "${COMPONENT_SWITCH_HELPER_APP}/Contents/Info.plist" <<HELPER_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$COMPONENT_SWITCH_HELPER_NAME</string>
  <key>CFBundleDisplayName</key><string>$COMPONENT_SWITCH_HELPER_NAME</string>
  <key>CFBundleIdentifier</key><string>$PRODUCT_CODE_SIGNING_IDENTIFIER_NAMESPACE.component-switch</string>
  <key>CFBundleExecutable</key><string>$PRODUCT_SLUG-component-helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
HELPER_PLIST
# The active SwiftPM resource bundles live in the conventional app Resources
# directory. Copy only the manifest-audited allowlist: incremental build output
# can retain bundles from retired targets. App code uses an app-aware locator;
# generated Bundle.module accessors are intentionally not used because they
# embed this build machine's absolute .build path.
cmdy_copy_required_swiftpm_resource_bundles \
    ".build/release" "${APP}/Contents/Resources" "$BROWSER_EDITION"
cp "$ICON" "${APP}/Contents/Resources/$ICON"
cp ACTIONS.md BUILDING.md CHANNELS.md EXTENSIONS.md EXTENSION_PROTOCOL.md MARKETPLACE.md PLATFORM.md SURFACE_PROTOCOL.md \
   "${APP}/Contents/Resources/"
mkdir -p "${APP}/Contents/Resources/Schemas"
cp Schemas/action-manifest-v1.schema.json \
   Schemas/extension-manifest-v1.schema.json \
   Schemas/surface-v1.schema.json \
   "${APP}/Contents/Resources/Schemas/"
cp LICENSE THIRD_PARTY_NOTICES.md Plugins/chromium/CEF-LICENSE.txt \
   "${APP}/Contents/Resources/"

for packaged_reference in \
    PLATFORM.md \
    Schemas/action-manifest-v1.schema.json \
    Schemas/extension-manifest-v1.schema.json \
    Schemas/surface-v1.schema.json; do
    if [ ! -f "${APP}/Contents/Resources/$packaged_reference" ]; then
        echo "Missing packaged documentation dependency: $packaged_reference" >&2
        exit 4
    fi
done

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$PRODUCT_NAME</string>
  <key>CFBundleDisplayName</key><string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key><string>$PRODUCT_BUNDLE_IDENTIFIER</string>
  <key>CFBundleExecutable</key><string>$PRODUCT_EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>$PRODUCT_ICON_BASENAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Andreas Pihlstrom. MIT licensed.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Text document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.plain-text</string>
        <string>public.source-code</string>
        <string>public.shell-script</string>
        <string>public.json</string>
        <string>net.daringfireball.markdown</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>txt</string><string>text</string><string>md</string><string>markdown</string>
        <string>conf</string><string>cfg</string><string>toml</string>
        <string>yaml</string><string>yml</string><string>json</string><string>sh</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>cmdy Extension Package</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key>
      <array><string>$PRODUCT_BUNDLE_IDENTIFIER.extension-package</string></array>
      <key>CFBundleTypeExtensions</key>
      <array><string>cmdyext</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>$PRODUCT_BUNDLE_IDENTIFIER.extension-package</string>
      <key>UTTypeDescription</key><string>cmdy Extension Package</string>
      <key>UTTypeConformsTo</key>
      <array><string>public.zip-archive</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>cmdyext</string></array>
        <key>public.mime-type</key><string>application/vnd.cmdy.extension+zip</string>
      </dict>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$PRODUCT_BUNDLE_IDENTIFIER.extension-install</string>
      <key>CFBundleURLSchemes</key><array><string>$PRODUCT_SLUG</string></array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -replace CFBundleShortVersionString -string "$VERSION" "${APP}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "${APP}/Contents/Info.plist"
if [ "$BROWSER_EDITION" = "1" ]; then
    BROWSER_COMPONENT_VERSION="$(tr -d '[:space:]' < Plugins/chromium/VERSION)"
    # This marker is the fail-closed selector for edition-preserving updates
    # and Marketplace component swaps. Every CEF-bearing package is Browser;
    # the canonical lean package never carries the marker or payload.
    plutil -insert CMDYBrowserEdition -bool true "${APP}/Contents/Info.plist"
    plutil -insert CMDYBrowserEnabledByDefault -bool \
        "$([ "$BROWSER_DEFAULT_ENABLED" = "1" ] && echo true || echo false)" \
        "${APP}/Contents/Info.plist"
    plutil -insert CMDYBrowserVersion -string "$BROWSER_COMPONENT_VERSION" \
        "${APP}/Contents/Info.plist"
fi

# Upstream CEF's macOS sandbox requires the framework and all four subprocess
# bundles to live in cmdy.app's standard Contents/Frameworks layout. Only the
# Browser release variant carries that sealed runtime; its removable Extension
# activation decides whether cmdy starts it.
# Bash 3.2 treats an empty-array expansion as an unset variable under `set -u`.
# Keep one sentinel so the normal Browser-free package path remains portable.
CHROMIUM_HELPER_APPS=("")
CEF_INCLUDE_DIR="Plugins/chromium/Frameworks/CEF"
CEF_WRAPPER_ARCHIVE="Plugins/chromium/Frameworks/libcef_dll_wrapper.a"
CEF_BRIDGE_ARCHIVE="Plugins/chromium/Frameworks/libcef_bridge.a"
CEF_FRAMEWORK="Plugins/chromium/Frameworks/Chromium Embedded Framework.framework"
CHROMIUM_HELPER_SOURCE="Plugins/chromium/Sources/ChromiumHost/ChromiumHelper.mm"
CHROMIUM_HOST_SOURCE="Plugins/chromium/Sources/ChromiumHost/ChromiumHostShim.mm"
if [ "$REQUIRE_CHROMIUM_HELPERS" = "1" ] &&
   [ -d "$CEF_INCLUDE_DIR" ] &&
   [ -f "$CEF_WRAPPER_ARCHIVE" ] &&
   [ -f "$CHROMIUM_HELPER_SOURCE" ]; then
    echo "Building Chromium helper apps..."
    HELPER_TMP="$(mktemp -d "${TMPDIR:-/tmp}/$PRODUCT_SLUG-chromium-helper.XXXXXX")"
    trap 'rm -rf "$HELPER_TMP"' EXIT
    HELPER_BASE="$PRODUCT_TITLE_NAME Chromium Helper"
    HELPER_BINARY="$HELPER_TMP/$HELPER_BASE"
    clang++ -std=c++20 -ObjC++ -fobjc-arc \
        -I "$CEF_INCLUDE_DIR" \
        -mmacosx-version-min=15.0 \
        "$CHROMIUM_HELPER_SOURCE" \
        "$CEF_WRAPPER_ARCHIVE" \
        -framework Cocoa -framework IOKit \
        -Wl,-rpath,@executable_path/../../.. \
        -o "$HELPER_BINARY"

    mkdir -p "${APP}/Contents/Frameworks"
    for TYPE in "" " (Renderer)" " (GPU)" " (Plugin)"; do
        HNAME="$HELPER_BASE$TYPE"
        HDIR="${APP}/Contents/Frameworks/$HNAME.app"
        HSFX=""
        case "$TYPE" in
            *Renderer*) HSFX=".renderer" ;;
            *GPU*) HSFX=".gpu" ;;
            *Plugin*) HSFX=".plugin" ;;
        esac
        mkdir -p "$HDIR/Contents/MacOS"
        cp "$HELPER_BINARY" "$HDIR/Contents/MacOS/$HNAME"
        printf 'APPL????' > "$HDIR/Contents/PkgInfo"
        cat > "$HDIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$HNAME</string>
  <key>CFBundleIdentifier</key><string>$PRODUCT_BUNDLE_IDENTIFIER.helper$HSFX</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$HNAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF
        CHROMIUM_HELPER_APPS+=("$HDIR")
    done

    if [ "$BROWSER_EDITION" = "1" ]; then
        [ -f "$CEF_BRIDGE_ARCHIVE" ] \
            && [ -d "$CEF_FRAMEWORK" ] \
            && [ -f "$CHROMIUM_HOST_SOURCE" ] || {
            echo "Browser package CEF inputs are incomplete." >&2
            echo "Run ./scripts/bootstrap-chromium.sh and retry." >&2
            exit 5
        }
        echo "Embedding the pinned CEF runtime for Browser activation..."
        ditto "$CEF_FRAMEWORK" \
            "${APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
        clang++ -dynamiclib -std=c++20 -ObjC++ -fobjc-arc \
            -mmacosx-version-min=26.0 \
            -ffile-prefix-map="$PWD"=/cmdy-source \
            -fmacro-prefix-map="$PWD"=/cmdy-source \
            "$CHROMIUM_HOST_SOURCE" \
            -Wl,-all_load "$CEF_BRIDGE_ARCHIVE" \
            "$CEF_WRAPPER_ARCHIVE" \
            -framework AppKit -framework Foundation \
            -install_name "@rpath/libCmdyChromiumHost.dylib" \
            -o "${APP}/Contents/Frameworks/libCmdyChromiumHost.dylib"
        cp Plugins/chromium/Frameworks/CEF-CREDITS.html \
            "${APP}/Contents/Resources/CEF-CREDITS.html"
        mkdir -p "${APP}/Contents/Resources/BrowserMCP"
        cp -R Plugins/chromium/mcp/. \
            "${APP}/Contents/Resources/BrowserMCP/"
        cp Identity/Node/product-identity.js \
            "${APP}/Contents/Resources/BrowserMCP/product-identity.js"
        cp "$PRODUCT_IDENTITY_FILE" \
            "${APP}/Contents/Resources/BrowserMCP/product-identity.json"
    fi
    rm -rf "$HELPER_TMP"
    trap - EXIT
else
    if [ "$REQUIRE_CHROMIUM_HELPERS" = "1" ]; then
        echo "Chromium helper inputs are required for this development build." >&2
        echo "Run ./scripts/bootstrap-chromium.sh before packaging." >&2
        exit 5
    fi
    echo "Skipping Chromium runtime (Browser is not part of this package)."
fi

# Edition layout is a release invariant, not just a build option. A future
# workflow typo must fail here instead of silently publishing Chromium in the
# canonical download (or publishing a Browser archive without its runtime).
BROWSER_FRAMEWORK_BINARY="${APP}/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"
BROWSER_HOST_BINARY="${APP}/Contents/Frameworks/libCmdyChromiumHost.dylib"
BROWSER_MCP_INDEX="${APP}/Contents/Resources/BrowserMCP/index.js"
BROWSER_HELPER_COUNT=0
if [ -d "${APP}/Contents/Frameworks" ]; then
    BROWSER_HELPER_COUNT="$(find "${APP}/Contents/Frameworks" -maxdepth 1 -type d \
        -name "$PRODUCT_TITLE_NAME Chromium Helper*.app" \
        | wc -l | tr -d '[:space:]')"
fi
if [ "$BROWSER_EDITION" = "1" ]; then
    [ "$(plutil -extract CMDYBrowserEdition raw "${APP}/Contents/Info.plist")" = "true" ] \
        || { echo "Browser package marker is missing." >&2; exit 5; }
    [ "$(plutil -extract CMDYBrowserVersion raw "${APP}/Contents/Info.plist")" \
        = "$(tr -d '[:space:]' < Plugins/chromium/VERSION)" ] \
        || { echo "Browser package component version is wrong." >&2; exit 5; }
    [ -f "$BROWSER_FRAMEWORK_BINARY" ] \
        && [ "$(stat -f %z "$BROWSER_FRAMEWORK_BINARY")" -ge $((50 * 1024 * 1024)) ] \
        || { echo "Browser package CEF framework is missing or incomplete." >&2; exit 5; }
    [ -f "$BROWSER_HOST_BINARY" ] \
        && [ "$(stat -f %z "$BROWSER_HOST_BINARY")" -ge $((64 * 1024)) ] \
        || { echo "Browser package host library is missing or incomplete." >&2; exit 5; }
    [ -f "$BROWSER_MCP_INDEX" ] \
        && [ "$(stat -f %z "$BROWSER_MCP_INDEX")" -ge 1024 ] \
        || { echo "Browser package MCP adapter is missing or incomplete." >&2; exit 5; }
    [ "$BROWSER_HELPER_COUNT" = "4" ] \
        || { echo "Browser package must contain exactly four Chromium helpers." >&2; exit 5; }
else
    if plutil -extract CMDYBrowserEdition raw "${APP}/Contents/Info.plist" \
        >/dev/null 2>&1 \
        || plutil -extract CMDYBrowserVersion raw "${APP}/Contents/Info.plist" \
            >/dev/null 2>&1 \
        || plutil -extract CMDYBrowserEnabledByDefault raw "${APP}/Contents/Info.plist" \
            >/dev/null 2>&1 \
        || [ -e "$BROWSER_FRAMEWORK_BINARY" ] \
        || [ -e "$BROWSER_HOST_BINARY" ] \
        || [ -e "${APP}/Contents/Resources/BrowserMCP" ] \
        || [ "$BROWSER_HELPER_COUNT" != "0" ]; then
        echo "Lean package unexpectedly contains Browser marker or Chromium payload." >&2
        exit 5
    fi
fi

# Scan only after both the base resources and optional Browser payload are in
# place. A stale build artifact or future copy step must never put a retired
# SwiftTerm/Termite-named path into a distributable app.
cmdy_assert_packaged_product_identity \
    "$PRODUCT_IDENTITY_FILE" "$APP/Contents/Resources"
cmdy_assert_no_retired_packaged_paths "$APP"

# Release binaries must not disclose the build user's home directory or a
# machine-specific macOS temporary-directory token. SwiftPM resource accessors
# and C/C++ __FILE__ macros can otherwise retain these paths even in optimized,
# stripped builds. Keep this before signing so a failure never leaves an
# apparently releasable signature behind.
private_home_pattern="/""Users/[^[:space:]]+"
private_temp_pattern="(/private)?/""var/folders/[^[:space:]]+"
private_path_pattern="($private_home_pattern|$private_temp_pattern)"
while IFS= read -r -d '' packaged_file; do
    if ! /usr/bin/file -b "$packaged_file" | grep -Fq 'Mach-O'; then
        continue
    fi
    leaked_paths="$(/usr/bin/strings "$packaged_file" \
        | grep -E "$private_path_pattern" \
        | head -n 8 || true)"
    if [ -n "$leaked_paths" ]; then
        echo "Packaged binary contains a build-machine path: $packaged_file" >&2
        printf '%s\n' "$leaked_paths" >&2
        exit 6
    fi
done < <(find "$APP/Contents" -type f -print0)

# Sign with a STABLE identity so macOS keeps its Accessibility / Screen
# Recording grants across rebuilds. Ad-hoc (`-`) mints a new code identity
# every build, which silently invalidates every TCC grant — the permission
# reads "on" but points at a dead identity, so macOS re-prompts forever.
# A Developer ID (or any real) certificate has a stable designated
# requirement: grant once, sticks. Override with PRODUCT_SIGN_ID; falls back
# to ad-hoc when no certificate is available (still runs locally).
SIGN_ID="$(product_env_value SIGN_ID "$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application|Apple Development/{print $2; exit}')")"
SIGN_ID="${SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
    echo "Signing (ad-hoc — no certificate; macOS will re-ask for permissions each rebuild)..."
    if [ "$BROWSER_EDITION" = "1" ]; then
        while IFS= read -r -d '' browser_code; do
            if /usr/bin/file -b "$browser_code" | grep -Fq 'Mach-O'; then
                codesign --force --sign - "$browser_code"
            fi
        done < <(find \
            "${APP}/Contents/Frameworks/Chromium Embedded Framework.framework" \
            -type f -print0)
        codesign --force --sign - \
            "${APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
        codesign --force --sign - \
            --identifier "$PRODUCT_CODE_SIGNING_IDENTIFIER_NAMESPACE.chromium.host" \
            "${APP}/Contents/Frameworks/libCmdyChromiumHost.dylib"
    fi
    for HDIR in "${CHROMIUM_HELPER_APPS[@]}"; do
        [ -n "$HDIR" ] || continue
        HNAME="$(basename "$HDIR" .app)"
        codesign --force --sign - \
            --entitlements Plugins/chromium/ChromiumHelper.entitlements \
            "$HDIR/Contents/MacOS/$HNAME"
        codesign --force --sign - \
            --entitlements Plugins/chromium/ChromiumHelper.entitlements \
            "$HDIR"
    done
    codesign --force --sign - "$COMPONENT_SWITCH_HELPER_APP"
    codesign --force --sign - --identifier "$PRODUCT_BUNDLE_IDENTIFIER" \
        --entitlements Cmdy.entitlements "${APP}"
else
    echo "Signing (stable identity ${SIGN_ID:0:12}… — permissions persist across rebuilds)..."
    # Hardened runtime + a trusted timestamp are required by Apple's notary
    # service. Local Developer-ID builds now exercise the exact release mode.
    if [ "$BROWSER_EDITION" = "1" ]; then
        while IFS= read -r -d '' browser_code; do
            if /usr/bin/file -b "$browser_code" | grep -Fq 'Mach-O'; then
                codesign --force --sign "$SIGN_ID" --options runtime \
                    --timestamp "$browser_code"
            fi
        done < <(find \
            "${APP}/Contents/Frameworks/Chromium Embedded Framework.framework" \
            -type f -print0)
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
            "${APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
            --identifier "$PRODUCT_CODE_SIGNING_IDENTIFIER_NAMESPACE.chromium.host" \
            "${APP}/Contents/Frameworks/libCmdyChromiumHost.dylib"
    fi
    for HDIR in "${CHROMIUM_HELPER_APPS[@]}"; do
        [ -n "$HDIR" ] || continue
        HNAME="$(basename "$HDIR" .app)"
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
            --entitlements Plugins/chromium/ChromiumHelper.entitlements \
            "$HDIR/Contents/MacOS/$HNAME"
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
            --entitlements Plugins/chromium/ChromiumHelper.entitlements \
            "$HDIR"
    done
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
        "$COMPONENT_SWITCH_HELPER_APP"
    codesign --force --sign "$SIGN_ID" --identifier "$PRODUCT_BUNDLE_IDENTIFIER" \
        --options runtime --timestamp --entitlements Cmdy.entitlements "${APP}"
fi
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign --verify --deep --strict --verbose=2 "$COMPONENT_SWITCH_HELPER_APP"
codesign --verify --strict --verbose=2 "$COMPONENT_SWITCH_HELPER"
MAIN_TEAM=""
if [ "$SIGN_ID" != "-" ]; then
    MAIN_TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 \
        | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    COMPONENT_HELPER_TEAM="$(codesign -dv --verbose=4 "$COMPONENT_SWITCH_HELPER_APP" 2>&1 \
        | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    if ! [[ "$MAIN_TEAM" =~ ^[A-Z0-9]{10}$ ]] \
       || [ "$COMPONENT_HELPER_TEAM" != "$MAIN_TEAM" ]; then
        echo "The component-switch helper is not signed by the app's Apple Team." >&2
        exit 6
    fi
fi
if [ "$REQUIRE_CHROMIUM_HELPERS" = "1" ]; then
    for HDIR in "${CHROMIUM_HELPER_APPS[@]}"; do
        [ -n "$HDIR" ] || continue
        HNAME="$(basename "$HDIR" .app)"
        HBIN="$HDIR/Contents/MacOS/$HNAME"
        codesign --verify --strict --verbose=2 "$HBIN"
        if [ "$SIGN_ID" != "-" ]; then
            HELPER_TEAM="$(codesign -dv --verbose=4 "$HBIN" 2>&1 \
                | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
            [ "$HELPER_TEAM" = "$MAIN_TEAM" ] || {
                echo "$HNAME is not signed by the app's Apple Team." >&2
                exit 6
            }
        fi
        HELPER_ENTITLEMENTS="$(codesign -d --entitlements :- "$HBIN" 2>&1 || true)"
        grep -Fq 'com.apple.security.cs.allow-jit' <<< "$HELPER_ENTITLEMENTS" || {
            echo "$HNAME is missing its required JIT entitlement." >&2
            exit 6
        }
        if grep -Fq 'com.apple.security.cs.disable-library-validation' \
            <<< "$HELPER_ENTITLEMENTS"; then
            echo "$HNAME unexpectedly disables Apple library validation." >&2
            exit 6
        fi
    done
fi
if [ "$BROWSER_EDITION" = "1" ]; then
    BROWSER_FRAMEWORK="${APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
    BROWSER_HOST="${APP}/Contents/Frameworks/libCmdyChromiumHost.dylib"
    codesign --verify --deep --strict --verbose=2 "$BROWSER_FRAMEWORK"
    codesign --verify --strict --verbose=2 "$BROWSER_HOST"
    if [ "$SIGN_ID" != "-" ]; then
        for browser_code in "$BROWSER_FRAMEWORK" "$BROWSER_HOST"; do
            BROWSER_TEAM="$(codesign -dv --verbose=4 "$browser_code" 2>&1 \
                | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
            [ "$BROWSER_TEAM" = "$MAIN_TEAM" ] || {
                echo "Browser runtime code is not signed by the app's Apple Team: $browser_code" >&2
                exit 6
            }
        done
    fi
fi

# A packaged executable must resolve every resource from the app itself. These
# checks run via the finished bundle (not .build/release/cmdy), with isolated
# user state, so a missing identity/font/shader bundle fails packaging now
# instead of crashing after distribution to another Mac.
RESOURCE_SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PRODUCT_SLUG-resource-smoke.XXXXXX")"
cleanup_resource_smoke() {
    if [ -n "$RESOURCE_SMOKE_DIR" ] && [ "$RESOURCE_SMOKE_DIR" != "/" ]; then
        rm -rf "$RESOURCE_SMOKE_DIR"
    fi
}
trap cleanup_resource_smoke EXIT INT TERM
FONT_SMOKE="$(env "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$RESOURCE_SMOKE_DIR/config" \
    "${APP}/Contents/MacOS/$PRODUCT_EXECUTABLE" --fonts)"
if ! grep -Eq '^[1-9][0-9]* bundled fonts$' <<< "$FONT_SMOKE"; then
    echo "Packaged font resource smoke failed:" >&2
    printf '%s\n' "$FONT_SMOKE" >&2
    exit 5
fi
SHADER_SMOKE="$(env "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$RESOURCE_SMOKE_DIR/config" \
    "${APP}/Contents/MacOS/$PRODUCT_EXECUTABLE" --shader-test)"
if ! grep -Fq 'ALL SHADER TESTS PASS' <<< "$SHADER_SMOKE"; then
    echo "Packaged shader resource smoke failed:" >&2
    printf '%s\n' "$SHADER_SMOKE" >&2
    exit 5
fi
if [ "$BROWSER_EDITION" = "1" ]; then
    echo "Running packaged Browser sandbox/UI smoke..."
    BROWSER_SMOKE_STARTED=$SECONDS
    BROWSER_SMOKE="$(env \
        HOME="$RESOURCE_SMOKE_DIR/home" \
        CFFIXED_USER_HOME="$RESOURCE_SMOKE_DIR/home" \
        "${PRODUCT_ENV_PREFIX}_CONFIG_DIR=$RESOURCE_SMOKE_DIR/browser-config" \
        "${APP}/Contents/MacOS/$PRODUCT_EXECUTABLE" \
        --ui-test-embedded-browser 2>&1)" || {
        printf '%s\n' "$BROWSER_SMOKE" >&2
        echo "Packaged Browser smoke failed." >&2
        exit 5
    }
    BROWSER_SMOKE_SECONDS=$((SECONDS - BROWSER_SMOKE_STARTED))
    if ! grep -Fq 'UIBROWSER ' <<< "$BROWSER_SMOKE" \
       || ! grep -Fq 'ok=true' <<< "$BROWSER_SMOKE"; then
        printf '%s\n' "$BROWSER_SMOKE" >&2
        echo "Packaged Browser did not load a sandboxed page." >&2
        exit 5
    fi
    if [ "$BROWSER_SMOKE_SECONDS" -gt 12 ]; then
        printf '%s\n' "$BROWSER_SMOKE" >&2
        echo "Packaged Browser Cmd-W shutdown took ${BROWSER_SMOKE_SECONDS}s (limit: 12s)." >&2
        exit 5
    fi
fi
if ! cmp -s Plugins/chromium/CEF-LICENSE.txt \
    "${APP}/Contents/Resources/CEF-LICENSE.txt"; then
    echo "Packaged CEF license is missing or does not match the pinned payload." >&2
    exit 5
fi
cleanup_resource_smoke
trap - EXIT INT TERM

echo "Done. Built ${APP} ${VERSION} (${BUILD_NUMBER}) -- drag it to /Applications."
