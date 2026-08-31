#!/bin/bash
# Rename every public product surface from the canonical identity manifest.
# Stable bundle/signing namespaces remain unchanged by design.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/product-identity.sh

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <new-product-name>" >&2
    exit 2
fi

NEW_NAME="$1"
NEW_SLUG="$(printf '%s' "$NEW_NAME" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
if [ -z "$NEW_SLUG" ] || ! [[ "$NEW_SLUG" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "The name must begin with a letter and use letters, numbers, spaces, or dashes." >&2
    exit 2
fi
if [ "$NEW_SLUG" = "$PRODUCT_SLUG" ]; then
    echo "Product identity is already '$PRODUCT_NAME'."
    exit 0
fi

# Keep the former public name as a config/environment compatibility alias.
old_is_legacy=0
legacy_index=0
while legacy_name="$(/usr/bin/plutil \
    -extract "legacyNames.$legacy_index" raw -o - \
    "$PRODUCT_IDENTITY_FILE" 2>/dev/null)"; do
    [ "$legacy_name" = "$PRODUCT_NAME" ] && old_is_legacy=1
    legacy_index=$((legacy_index + 1))
done
if [ "$old_is_legacy" -eq 0 ]; then
    # The most recent former identity has priority over older aliases when a
    # user still has multiple generations of config or environment variables.
    /usr/bin/plutil -insert "legacyNames.0" \
        -string "$PRODUCT_NAME" "$PRODUCT_IDENTITY_FILE"
fi
/usr/bin/plutil -replace name -string "$NEW_NAME" "$PRODUCT_IDENTITY_FILE"

echo "Renamed '$PRODUCT_NAME' → '$NEW_NAME' in:"
echo "  $PRODUCT_IDENTITY_FILE"
echo
echo "Public app, executable, config, environment, MCP, updater, plugin installer,"
echo "and release names now derive from '$NEW_SLUG'. Stable bundle/signing IDs stay"
echo "unchanged so existing macOS permissions and update continuity survive."
echo
echo "Run ./scripts/check-product-identity.sh, ./test.sh, and ./package.sh."
