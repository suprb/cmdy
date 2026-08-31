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

for tool in swift xcrun jq cmp diff find; do
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

swift build --package-path "$repo_root/Core"
swift build --package-path "$repo_root/Renderer"

core_bin="$(swift build --package-path "$repo_root/Core" --show-bin-path)"
renderer_bin="$(swift build --package-path "$repo_root/Renderer" --show-bin-path)"
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
    -I "$renderer_bin/Modules"

# Symbol graphs describe the public source surface without exposing private
# storage layout. Canonicalization removes source prose/locations, joins token
# fragments (stored and computed read-only properties print the same public
# declaration), and sorts set-like arrays. The resulting JSON remains strict
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
    "$baseline_dir/CmdyPTY.symbols.json" \
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
    "$baseline_dir/CmdyGPU.symbols.json" \
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
    "$baseline_dir/CmdyGPU@Foundation.symbols.json" \
    "$api_work_dir/CmdyGPU@Foundation.symbols.json"
