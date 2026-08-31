#!/bin/bash
# Shared product identity for build, install, and release scripts.
# shellcheck shell=bash

PRODUCT_IDENTITY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_IDENTITY_FILE="${PRODUCT_IDENTITY_FILE:-$PRODUCT_IDENTITY_ROOT/Identity/Sources/ProductIdentity/Resources/product-identity.json}"

product_identity_extract() {
    /usr/bin/plutil -extract "$1" raw -o - "$PRODUCT_IDENTITY_FILE"
}

PRODUCT_NAME="$(product_identity_extract name)"
PRODUCT_REPOSITORY_OWNER="$(product_identity_extract repositoryOwner)"
PRODUCT_BUNDLE_IDENTIFIER="$(product_identity_extract bundleIdentifier)"
PRODUCT_EXTENSION_IDENTIFIER_NAMESPACE="$(product_identity_extract extensionIdentifierNamespace)"
PRODUCT_CODE_SIGNING_IDENTIFIER_NAMESPACE="$(product_identity_extract codeSigningIdentifierNamespace)"
PRODUCT_SLUG="$(printf '%s' "$PRODUCT_NAME" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
# Compatibility variable used by prose and helper bundle names. Preserve the
# exact public casing selected in the identity manifest.
PRODUCT_TITLE_NAME="$PRODUCT_NAME"
PRODUCT_ENV_PREFIX="$(printf '%s' "$PRODUCT_SLUG" \
    | tr '[:lower:]-' '[:upper:]_')"
PRODUCT_EXECUTABLE="$PRODUCT_SLUG"
PRODUCT_APP_BUNDLE="$PRODUCT_SLUG.app"
PRODUCT_ICON_BASENAME="$PRODUCT_SLUG"
PRODUCT_CONFIG_DIR_NAME="$PRODUCT_SLUG"
PRODUCT_RELEASE_PREFIX="$PRODUCT_SLUG"
PRODUCT_GITHUB_REPOSITORY="$PRODUCT_REPOSITORY_OWNER/$PRODUCT_SLUG"

PRODUCT_LEGACY_ENV_PREFIXES=()
PRODUCT_LEGACY_SLUGS=()
product_identity_legacy_index=0
while product_identity_legacy_name="$(/usr/bin/plutil \
    -extract "legacyNames.$product_identity_legacy_index" raw -o - \
    "$PRODUCT_IDENTITY_FILE" 2>/dev/null)"; do
    product_identity_legacy_slug="$(printf '%s' "$product_identity_legacy_name" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    if [ -n "$product_identity_legacy_slug" ] \
       && [ "$product_identity_legacy_slug" != "$PRODUCT_SLUG" ]; then
        PRODUCT_LEGACY_SLUGS+=("$product_identity_legacy_slug")
        PRODUCT_LEGACY_ENV_PREFIXES+=("$(printf '%s' "$product_identity_legacy_slug" \
            | tr '[:lower:]-' '[:upper:]_')")
    fi
    product_identity_legacy_index=$((product_identity_legacy_index + 1))
done
unset product_identity_legacy_index product_identity_legacy_name product_identity_legacy_slug

product_env_value() {
    local suffix="$1"
    local fallback="${2:-}"
    local key="${PRODUCT_ENV_PREFIX}_${suffix}"
    if [ -n "${!key:-}" ]; then
        printf '%s' "${!key}"
        return
    fi
    key="PRODUCT_${suffix}"
    if [ -n "${!key:-}" ]; then
        printf '%s' "${!key}"
        return
    fi
    local prefix
    for prefix in "${PRODUCT_LEGACY_ENV_PREFIXES[@]}"; do
        key="${prefix}_${suffix}"
        if [ -n "${!key:-}" ]; then
            printf '%s' "${!key}"
            return
        fi
    done
    printf '%s' "$fallback"
}

if [ -z "$PRODUCT_SLUG" ] || [ -z "$PRODUCT_ENV_PREFIX" ]; then
    echo "Invalid product identity in $PRODUCT_IDENTITY_FILE" >&2
    return 2 2>/dev/null || exit 2
fi
