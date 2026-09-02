#!/bin/bash
# Fast consistency gate for every functional surface controlled by identity.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/product-identity.sh

test "$PRODUCT_APP_BUNDLE" = "$PRODUCT_SLUG.app"
test "$PRODUCT_EXECUTABLE" = "$PRODUCT_SLUG"
test "$PRODUCT_GITHUB_REPOSITORY" \
    = "$PRODUCT_REPOSITORY_OWNER/$PRODUCT_SLUG"

node_values="$(node -e '
const p = require("./Identity/Node/product-identity.js");
process.stdout.write([
  p.name, p.slug, p.environmentPrefix, p.configDirectoryName,
  p.mcpServerName("browser")
].join("|"));
')"
test "$node_values" \
    = "$PRODUCT_NAME|$PRODUCT_SLUG|$PRODUCT_ENV_PREFIX|$PRODUCT_CONFIG_DIR_NAME|$PRODUCT_SLUG-browser"

for script in package.sh release.sh publish-release.sh plugins.sh test.sh; do
    grep -Fq 'source scripts/product-identity.sh' "$script"
done

grep -Fq "${PRODUCT_ENV_PREFIX}_PORT=4664" EXTENSIONS.md
grep -Fq "os.environ['${PRODUCT_ENV_PREFIX}_TOKEN']" EXTENSIONS.md
grep -Fq "~/.config/$PRODUCT_CONFIG_DIR_NAME/shaders/" \
    Kit/Sources/CmdyKit/UserShaders.swift
grep -Fq "# $PRODUCT_SLUG demo" scripts/demo.sh

for source in \
    Kit/Sources/CmdyKit/ConfigFile.swift \
    Kit/Sources/CmdyKit/AppUpdates.swift \
    App/TerminalWindowController.swift \
    App/EmbeddedChromium.swift \
    Plugins/chromium/mcp/index.js \
    Plugins/sim/mcp/index.js \
    Plugins/appdock/mcp/index.js; do
    test -f "$source"
done

# Public website links must follow the canonical repository. Legacy registry
# URLs remain valid only in compatibility snapshots and runtime fallbacks.
for source in \
    site/src/components/SiteShell.tsx \
    site/src/pages/HomePage.tsx; do
    grep -Fq "https://github.com/$PRODUCT_GITHUB_REPOSITORY" "$source"
    if grep -Eq 'github\.com/[^/]+/(termite|term64)(/|"|$)' "$source"; then
        echo "Legacy public repository URL found in $source" >&2
        exit 1
    fi
done

# The stable protocol namespaces are deliberately not renamed with the public
# product. Make that compatibility contract explicit rather than silently
# letting schemas and identity drift apart.
schema_namespace="$(/usr/bin/plutil -extract extensionIdentifierNamespace raw -o - "$PRODUCT_IDENTITY_FILE")"
for schema in Schemas/action-manifest-v1.schema.json \
              Schemas/extension-manifest-v1.schema.json \
              Schemas/surface-v1.schema.json; do
    grep -Fq "${schema_namespace#*.}" "$schema"
done

bash -n scripts/product-identity.sh scripts/rename-product.sh \
    scripts/check-product-identity.sh scripts/package-resource-policy.sh \
    scripts/demo.sh scripts/record-tour.sh Tests/package-resource-policy.sh \
    package.sh release.sh publish-release.sh plugins.sh test.sh
node --check Identity/Node/product-identity.js
node --check Plugins/chromium/mcp/index.js
node --check Plugins/sim/mcp/index.js
node --check Plugins/appdock/mcp/index.js
bash Tests/package-resource-policy.sh >/dev/null

# Prove that the public rename command mutates only an isolated manifest and
# carries the old name forward as a compatibility alias.
rename_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/$PRODUCT_SLUG-identity.XXXXXX")"
trap 'rm -rf "$rename_check_dir"' EXIT
rename_check_manifest="$rename_check_dir/product-identity.json"
cp "$PRODUCT_IDENTITY_FILE" "$rename_check_manifest"
PRODUCT_IDENTITY_FILE="$rename_check_manifest" \
    ./scripts/rename-product.sh "Identity Check TTY" >/dev/null
test "$(/usr/bin/plutil -extract name raw -o - "$rename_check_manifest")" \
    = "Identity Check TTY"
/usr/bin/plutil -extract legacyNames json -o - "$rename_check_manifest" \
    | grep -Fq "\"$PRODUCT_NAME\""
rm -rf "$rename_check_dir"
trap - EXIT

echo "Product identity is consistent: $PRODUCT_NAME ($PRODUCT_SLUG)"
