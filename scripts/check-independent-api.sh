#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline_dir="$repo_root/docs/independence/baselines"
api_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmdy-api-check.XXXXXX")"

cleanup() {
    if [[ -d "$api_work_dir" && "$api_work_dir" == *"/cmdy-api-check."* ]]; then
        find "$api_work_dir" -type f -delete 2>/dev/null || true
        find "$api_work_dir" -depth -type d -empty -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

for tool in swift xcrun jq cmp diff find python3; do
    command -v "$tool" >/dev/null || {
        echo "missing required tool: $tool" >&2
        exit 2
    }
done

for baseline in \
    CmdyPTY.symbols.json \
    CmdyGPU.symbols.json \
    CmdyGPU@Foundation.symbols.json; do
    [[ -f "$baseline_dir/$baseline" ]] || {
        echo "missing frozen public-symbol baseline: $baseline_dir/$baseline" >&2
        exit 2
    }
done

if [ -z "${CMDY_ZIG:-}" ]; then
    CMDY_ZIG="$("$repo_root/scripts/bootstrap-zig.sh")"
    export CMDY_ZIG
fi
python3 "$repo_root/Core/Tools/ZigEngine/build.py" --optimize ReleaseFast
swift build --manifest-cache none --disable-build-manifest-caching --package-path "$repo_root/Core" -c release
swift build --manifest-cache none --disable-build-manifest-caching --package-path "$repo_root/Renderer" -c release

core_bin="$(swift build --manifest-cache none --disable-build-manifest-caching --package-path "$repo_root/Core" -c release --show-bin-path)"
renderer_bin="$(swift build --manifest-cache none --disable-build-manifest-caching --package-path "$repo_root/Renderer" -c release --show-bin-path)"
sdk_path="$(xcrun --show-sdk-path)"
target_triple="$(swift -print-target-info | jq -r '.target.triple')"

extract_symbols() {
    local module="$1"
    local output_dir="$2"
    shift 2
    mkdir -p "$output_dir"
    xcrun swift-symbolgraph-extract \
        -module-name "$module" \
        -output-dir "$output_dir" \
        -minimum-access-level public \
        -skip-inherited-docs \
        -skip-protocol-implementations \
        -skip-synthesized-members \
        -target "$target_triple" \
        -sdk "$sdk_path" \
        "$@"
}

extract_symbols CmdyPTY "$api_work_dir/pty-raw" \
    -I "$core_bin/Modules" \
    -I "$core_bin/CmdyPTYShim.build"
extract_symbols CmdyGPU "$api_work_dir/gpu-raw" \
    -I "$renderer_bin/Modules" \
    -I "$renderer_bin/CmdyNative.build" \
    -I "$repo_root/Core/Sources/CmdyNative/include"

# Symbol graphs describe the public source surface without exposing private
# storage layout. Canonicalization removes source prose/locations, joins token
# fragments, and sorts set-like arrays. A public mutable stored property and
# a computed property with ordinary public get/set accessors have the same
# source API. Normalize only that exact accessor suffix on property symbols;
# get-only properties, let declarations, accessor modifiers and types remain
# distinct. The resulting JSON remains strict
# about names, argument labels/defaults, types, access, conformances, cases,
# relationships, and public declaration spelling.
canonicalize() {
    local input="$1"
    local output="$2"
    jq -S '
        del(.metadata.generator)
        | del(.symbols[].docComment, .symbols[].location)
        | walk(
            if type == "object" and has("declarationFragments") then
                .declaration = ([.declarationFragments[].spelling] | join(""))
                | del(.declarationFragments)
            else . end
          )
        | .symbols |= map(
            if (.kind.identifier == "swift.property" or .kind.identifier == "swift.type.property")
               and (.declaration | test("(^| )var ")) then
                .declaration |= sub(" \\{ get set \\}$"; "")
            else . end
          )
        | .symbols |= sort_by(.identifier.precise)
        | .relationships |= sort_by(.kind, .source, .target)
    ' "$input" > "$output"
}

canonicalize \
    "$api_work_dir/pty-raw/CmdyPTY.symbols.json" \
    "$api_work_dir/CmdyPTY.symbols.json"
canonicalize \
    "$api_work_dir/gpu-raw/CmdyGPU.symbols.json" \
    "$api_work_dir/CmdyGPU.symbols.json"
canonicalize \
    "$api_work_dir/gpu-raw/CmdyGPU@Foundation.symbols.json" \
    "$api_work_dir/CmdyGPU@Foundation.symbols.json"
for baseline in CmdyPTY.symbols.json CmdyGPU.symbols.json CmdyGPU@Foundation.symbols.json; do
    canonicalize "$baseline_dir/$baseline" "$api_work_dir/baseline-$baseline"
done

compare_exact() {
    local label="$1"
    local baseline="$2"
    local current="$3"
    if cmp -s "$baseline" "$current"; then
        echo "$label public API: exact baseline match"
        return
    fi
    echo "$label public API differs from frozen baseline" >&2
    echo "First 200 diff lines:" >&2
    diff -u "$baseline" "$current" | sed -n '1,200p' >&2 || true
    return 1
}

compare_exact \
    CmdyPTY \
    "$api_work_dir/baseline-CmdyPTY.symbols.json" \
    "$api_work_dir/CmdyPTY.symbols.json"

# One reviewed source-name migration is intentional: the old global
# SwiftTermUnderlineStyleKey becomes CmdyUnderlineStyleKey. Prove that each
# side has exactly one immutable NSAttributedString.Key declaration, remove
# only that declaration and its relationships, then compare every other public
# symbol exactly. No wildcard/substring allowlist is used.
strip_reviewed_underline_key() {
    local input="$1"
    local key_name="$2"
    local output="$3"
    local count identifier declaration
    count="$(jq --arg name "$key_name" \
        '[.symbols[] | select(.names.title == $name)] | length' "$input")"
    [[ "$count" == "1" ]] || {
        echo "expected exactly one public $key_name declaration, found $count" >&2
        return 1
    }
    identifier="$(jq -r --arg name "$key_name" \
        '.symbols[] | select(.names.title == $name) | .identifier.precise' "$input")"
    declaration="$(jq -r --arg name "$key_name" \
        '.symbols[] | select(.names.title == $name) | .declaration' "$input")"
    [[ "$declaration" == "let $key_name: NSAttributedString.Key" ]] || {
        echo "unexpected declaration for $key_name: $declaration" >&2
        return 1
    }
    jq -S --arg name "$key_name" --arg id "$identifier" '
        .symbols |= map(select(.names.title != $name))
        | .relationships |= map(select(.source != $id and .target != $id))
    ' "$input" > "$output"
}

strip_reviewed_underline_key \
    "$api_work_dir/baseline-CmdyGPU.symbols.json" \
    SwiftTermUnderlineStyleKey \
    "$api_work_dir/CmdyGPU-baseline-with-reviewed-key-removed.json"
strip_reviewed_underline_key \
    "$api_work_dir/CmdyGPU.symbols.json" \
    CmdyUnderlineStyleKey \
    "$api_work_dir/CmdyGPU-current-with-reviewed-key-removed.json"

compare_exact \
    CmdyGPU \
    "$api_work_dir/CmdyGPU-baseline-with-reviewed-key-removed.json" \
    "$api_work_dir/CmdyGPU-current-with-reviewed-key-removed.json"
compare_exact \
    'CmdyGPU Foundation extensions' \
    "$api_work_dir/baseline-CmdyGPU@Foundation.symbols.json" \
    "$api_work_dir/CmdyGPU@Foundation.symbols.json"

# Prove actual client operations for the properties whose backing storage moved
# behind the native ABI. Writable reference key paths preserve their class
# getter/setter semantics, including the optional closure's exact public type.
cat > "$api_work_dir/RendererPropertyClient.swift" <<'SWIFT'
import Foundation
import CmdyGPU

@MainActor
func rendererPropertyClient(_ renderer: MetalTerminalRenderer) {
    let booleans: [ReferenceWritableKeyPath<MetalTerminalRenderer, Bool>] = [
        \.smoothCursorEnabled, \.hostCursorHidden, \.smoothScrollEnabled,
    ]
    let floats: [ReferenceWritableKeyPath<MetalTerminalRenderer, Float>] = [
        \.cursorGlideSpeed, \.cursorGlideMaxDistance,
    ]
    for key in booleans { renderer[keyPath: key] = renderer[keyPath: key] }
    for key in floats { renderer[keyPath: key] = renderer[keyPath: key] }
    let callback: ReferenceWritableKeyPath<MetalTerminalRenderer, ((CGFloat) -> Void)?> = \.onScrollOffsetChanged
    renderer[keyPath: callback] = renderer[keyPath: callback]
    let presented: Int = MetalTerminalRenderer.framesPresented
    let rebuilt: Int = MetalTerminalRenderer.rowsRebuilt
    let reused: Int = MetalTerminalRenderer.rowsReused
    MetalTerminalRenderer.framesPresented = presented
    MetalTerminalRenderer.rowsRebuilt = rebuilt
    MetalTerminalRenderer.rowsReused = reused
    let _: String = MetalTerminalRenderer.userShaderPreamble
}
SWIFT
swiftc -typecheck -target "$target_triple" -sdk "$sdk_path" \
    -I "$renderer_bin/Modules" -I "$renderer_bin/CmdyNative.build" \
    -I "$repo_root/Core/Sources/CmdyNative/include" \
    "$api_work_dir/RendererPropertyClient.swift"
echo "CmdyGPU renderer properties: compiler read/write and writable-key-path probes passed"
