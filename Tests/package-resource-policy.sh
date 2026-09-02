#!/usr/bin/env bash
# Fixture-based regression tests for the fail-closed package resource policy.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/package-resource-policy.sh

fail() {
    printf 'package resource policy test: %s\n' "$*" >&2
    exit 1
}

test_root="$(mktemp -d "${TMPDIR:-/tmp}/cmdy-package-resources.XXXXXX")"
cleanup() {
    if [ -n "$test_root" ] && [ "$test_root" != "/" ]; then
        rm -rf "$test_root"
    fi
}
trap cleanup EXIT INT TERM

declared_bundles="$(
    printf '%s\n' "${CMDY_REQUIRED_SWIFTPM_RESOURCE_BUNDLES[@]}" \
        | LC_ALL=C sort
)"
expected_bundles="$(
    printf '%s\n' \
        'Kit_CmdyKit.bundle' \
        'ProductIdentity_ProductIdentity.bundle' \
        | LC_ALL=C sort
)"
[ "$declared_bundles" = "$expected_bundles" ] \
    || fail "the audited SwiftPM bundle allowlist changed without a policy update"

build_products="$test_root/release"
mkdir -p "$build_products"
for required_bundle in "${CMDY_REQUIRED_SWIFTPM_RESOURCE_BUNDLES[@]}"; do
    mkdir -p "$build_products/$required_bundle"
    printf 'fixture\n' > "$build_products/$required_bundle/resource.txt"
done
identity_fixture="$test_root/product-identity.json"
printf '{"name":"cmdy","repositoryOwner":"suprb"}\n' > "$identity_fixture"
cp "$identity_fixture" \
    "$build_products/ProductIdentity_ProductIdentity.bundle/product-identity.json"

# Old products can remain in an incremental SwiftPM build directory. They must
# never be copied merely because their filename ends in .bundle.
mkdir -p "$build_products/Kit_TermiteKit.bundle"
mkdir -p "$build_products/Renderer_TermiteGPU.bundle"
mkdir -p "$build_products/UnrelatedFixture.bundle"

for edition in 0 1; do
    destination="$test_root/edition-$edition"
    cmdy_copy_required_swiftpm_resource_bundles \
        "$build_products" "$destination" "$edition"
    if [ "$edition" = "1" ]; then
        mkdir -p "$destination/BrowserMCP"
        cp "$identity_fixture" "$destination/BrowserMCP/product-identity.json"
    fi

    actual_bundles="$(
        for packaged_bundle in "$destination"/*.bundle; do
            basename "$packaged_bundle"
        done | LC_ALL=C sort
    )"
    [ "$actual_bundles" = "$expected_bundles" ] \
        || fail "edition $edition copied outside the explicit allowlist"
    cmdy_assert_packaged_product_identity "$identity_fixture" "$destination"
    cmdy_assert_no_retired_packaged_paths "$destination"
done

rm "$test_root/edition-1/BrowserMCP/product-identity.json"
if browser_missing_output="$(cmdy_assert_packaged_product_identity \
        "$identity_fixture" "$test_root/edition-1" 2>&1)"; then
    fail "missing Browser MCP product identity was accepted"
fi
grep -Fq 'Browser MCP product identity is missing' <<< "$browser_missing_output" \
    || fail "missing Browser identity failure was not actionable"
cp "$identity_fixture" "$test_root/edition-1/BrowserMCP/product-identity.json"
printf '{"name":"cmdy","repositoryOwner":"wrong"}\n' \
    > "$test_root/edition-1/BrowserMCP/product-identity.json"
if browser_mismatch_output="$(cmdy_assert_packaged_product_identity \
        "$identity_fixture" "$test_root/edition-1" 2>&1)"; then
    fail "mismatched Browser MCP product identity was accepted"
fi
grep -Fq 'Browser MCP product identity differs' <<< "$browser_mismatch_output" \
    || fail "Browser identity mismatch failure was not actionable"

printf '{"name":"cmdy","repositoryOwner":"wrong"}\n' \
    > "$test_root/edition-0/ProductIdentity_ProductIdentity.bundle/product-identity.json"
if identity_output="$(cmdy_assert_packaged_product_identity \
        "$identity_fixture" "$test_root/edition-0" 2>&1)"; then
    fail "mismatched packaged product identity was accepted"
fi
grep -Fq 'differs from the canonical source manifest' <<< "$identity_output" \
    || fail "identity mismatch failure was not actionable"

rm -rf "$build_products/ProductIdentity_ProductIdentity.bundle"
if missing_output="$(cmdy_copy_required_swiftpm_resource_bundles \
        "$build_products" "$test_root/missing" 0 2>&1)"; then
    fail "missing required bundle was accepted"
fi
grep -Fq 'Missing required SwiftPM resource bundle:' <<< "$missing_output" \
    || fail "missing-bundle failure did not explain the required input"

retired_root="$test_root/retired-package"
mkdir -p "$retired_root/Contents/Resources/LegacyTermite.bundle"
if retired_output="$(cmdy_assert_no_retired_packaged_paths \
        "$retired_root" 2>&1)"; then
    fail "Termite package path was accepted"
fi
grep -Fq 'contains a retired terminal name:' <<< "$retired_output" \
    || fail "Termite-path failure was not actionable"

rm -rf "$retired_root/Contents/Resources/LegacyTermite.bundle"
mkdir -p "$retired_root/Contents/Frameworks/SwIfTtErM.framework"
if cmdy_assert_no_retired_packaged_paths "$retired_root" >/dev/null 2>&1; then
    fail "mixed-case SwiftTerm package path was accepted"
fi

grep -Fq 'cmdy_copy_required_swiftpm_resource_bundles' package.sh \
    || fail "package.sh does not invoke the explicit resource policy"
grep -Fq 'source scripts/package-resource-policy.sh' package.sh \
    || fail "package.sh does not load the explicit resource policy"
grep -Fq 'cmdy_assert_no_retired_packaged_paths' package.sh \
    || fail "package.sh does not enforce the final retired-path scan"
grep -Fq 'cmdy_assert_packaged_product_identity' package.sh \
    || fail "package.sh does not verify its embedded product identity"
if grep -Fq '.build/release/*.bundle' package.sh; then
    fail "package.sh restored a broad SwiftPM bundle wildcard"
fi

printf 'Package resource policy passed for lean and Browser editions.\n'
