#!/usr/bin/env bash
# Resource-bundle policy shared by package.sh and its fixture-based tests.
# shellcheck shell=bash

# These are the only SwiftPM resource bundles in the active application graph:
# CmdyKit owns the bundled fonts and ProductIdentity owns the canonical identity
# manifest. Developer and Browser-capable packages require the same two bundles; Browser
# adds its CEF and MCP resources explicitly in package.sh.
CMDY_REQUIRED_SWIFTPM_RESOURCE_BUNDLES=(
    "Kit_CmdyKit.bundle"
    "ProductIdentity_ProductIdentity.bundle"
)
readonly CMDY_REQUIRED_SWIFTPM_RESOURCE_BUNDLES

cmdy_copy_required_swiftpm_resource_bundles() {
    if [ "$#" -ne 3 ]; then
        echo "usage: cmdy_copy_required_swiftpm_resource_bundles BUILD_PRODUCTS DESTINATION EDITION" >&2
        return 4
    fi

    local build_products_dir="$1"
    local destination_dir="$2"
    local edition="$3"
    local required_bundle
    local source_bundle
    local destination_bundle

    case "$edition" in
        0|1) ;;
        *)
            echo "Package Browser payload flag must be 0 or 1." >&2
            return 4
            ;;
    esac

    if [ ! -d "$build_products_dir" ]; then
        echo "Missing SwiftPM release-products directory: $build_products_dir" >&2
        return 4
    fi
    if ! mkdir -p "$destination_dir"; then
        echo "Could not create packaged Resources directory: $destination_dir" >&2
        return 4
    fi

    for required_bundle in "${CMDY_REQUIRED_SWIFTPM_RESOURCE_BUNDLES[@]}"; do
        source_bundle="$build_products_dir/$required_bundle"
        destination_bundle="$destination_dir/$required_bundle"
        if [ ! -d "$source_bundle" ]; then
            echo "Missing required SwiftPM resource bundle: $source_bundle" >&2
            return 4
        fi
        if [ -e "$destination_bundle" ]; then
            echo "Refusing to merge an existing packaged resource bundle: $destination_bundle" >&2
            return 4
        fi
        if ! cp -R "$source_bundle" "$destination_bundle"; then
            echo "Could not package required SwiftPM resource bundle: $required_bundle" >&2
            return 4
        fi
    done
}

cmdy_assert_packaged_product_identity() {
    if [ "$#" -ne 2 ]; then
        echo "usage: cmdy_assert_packaged_product_identity SOURCE_IDENTITY PACKAGED_RESOURCES" >&2
        return 4
    fi

    local source_identity="$1"
    local packaged_resources="$2"
    local packaged_identity="$packaged_resources/ProductIdentity_ProductIdentity.bundle/product-identity.json"
    local browser_identity="$packaged_resources/BrowserMCP/product-identity.json"

    if [ ! -f "$source_identity" ]; then
        echo "Missing canonical product identity: $source_identity" >&2
        return 4
    fi
    if [ ! -f "$packaged_identity" ]; then
        echo "Missing packaged product identity: $packaged_identity" >&2
        return 4
    fi
    if ! cmp -s "$source_identity" "$packaged_identity"; then
        echo "Packaged product identity differs from the canonical source manifest." >&2
        return 4
    fi
    if [ -d "$packaged_resources/BrowserMCP" ]; then
        if [ ! -f "$browser_identity" ]; then
            echo "Browser MCP product identity is missing: $browser_identity" >&2
            return 4
        fi
        if ! cmp -s "$source_identity" "$browser_identity"; then
            echo "Browser MCP product identity differs from the canonical source manifest." >&2
            return 4
        fi
    fi
}

cmdy_assert_no_retired_packaged_paths() {
    if [ "$#" -ne 1 ]; then
        echo "usage: cmdy_assert_no_retired_packaged_paths PACKAGE_ROOT" >&2
        return 4
    fi

    local package_root="$1"
    local packaged_path
    local relative_path
    local lowercase_path

    if [ ! -d "$package_root" ]; then
        echo "Missing package root for retired-path check: $package_root" >&2
        return 4
    fi

    while IFS= read -r -d '' packaged_path; do
        relative_path="${packaged_path#"$package_root"/}"
        lowercase_path="$(printf '%s' "$relative_path" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        case "$lowercase_path" in
            *swiftterm*|*termite*)
                echo "Packaged path contains a retired terminal name: $relative_path" >&2
                return 4
                ;;
        esac
    done < <(find "$package_root" -mindepth 1 -print0)
}
