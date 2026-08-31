#!/bin/bash
# Dispatch the notarized GitHub release workflow and optionally watch it finish.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/product-identity.sh

usage() {
    echo "Usage: ./publish-release.sh [--dry-run] [--no-watch] VERSION" >&2
    echo "Example: ./publish-release.sh 1.2.0" >&2
}

DRY_RUN=0
WATCH=1
VERSION=""
for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1 ;;
        --no-watch) WATCH=0 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $argument" >&2; usage; exit 2 ;;
        *)
            if [ -n "$VERSION" ]; then
                echo "Only one version may be supplied." >&2
                usage
                exit 2
            fi
            VERSION="${argument#v}"
            ;;
    esac
done

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "VERSION must be numeric, for example 1.2.0." >&2
    usage
    exit 2
fi
PROJECT_VERSION="$(tr -d '[:space:]' < VERSION)"
if [ "$VERSION" != "$PROJECT_VERSION" ]; then
    echo "Requested version $VERSION does not match VERSION ($PROJECT_VERSION)." >&2
    echo "Update VERSION and CHANGELOG.md, commit them, then retry." >&2
    exit 2
fi

REPOSITORY="${PRODUCT_RELEASE_REPOSITORY:-$PRODUCT_GITHUB_REPOSITORY}"
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ -z "$BRANCH" ]; then
    echo "Publish from a branch, not a detached HEAD." >&2
    exit 2
fi

echo "Release:    $PRODUCT_TITLE_NAME $VERSION"
echo "Repository: $REPOSITORY"
echo "Source:     $BRANCH ($(git rev-parse --short HEAD))"

if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run only; no workflow was dispatched."
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI is required. Install it with: brew install gh" >&2
    exit 3
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit the release first; the working tree has uncommitted changes." >&2
    exit 3
fi

gh auth status >/dev/null
repository_info="$(gh repo view "$REPOSITORY" \
    --json visibility,defaultBranchRef \
    --jq '[.visibility, .defaultBranchRef.name] | @tsv' 2>/dev/null || true)"
visibility="${repository_info%%$'\t'*}"
default_branch="${repository_info#*$'\t'}"
if [ -z "$visibility" ]; then
    echo "GitHub repository '$REPOSITORY' does not exist or is not accessible." >&2
    echo "Create or rename the public release repository, push this branch, then retry." >&2
    exit 3
fi
if [ "$visibility" != "PUBLIC" ]; then
    echo "'$REPOSITORY' is $visibility. Public downloads and automatic updates require a PUBLIC repository." >&2
    exit 3
fi
if [ "$BRANCH" != "$default_branch" ]; then
    echo "Publish from the default branch '$default_branch', not '$BRANCH'." >&2
    exit 3
fi

remote_commit="$(gh api "repos/$REPOSITORY/commits/$BRANCH" --jq .sha 2>/dev/null || true)"
if [ -z "$remote_commit" ] || [ "$(git rev-parse HEAD)" != "$remote_commit" ]; then
    echo "Local $BRANCH is not exactly pushed to $REPOSITORY." >&2
    echo "Push the release commit before publishing." >&2
    exit 3
fi

if ! gh workflow view release.yml --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "release.yml is not available on $REPOSITORY's default branch yet." >&2
    echo "Merge or push the release workflow before publishing." >&2
    exit 3
fi

run_title="Release $VERSION"
previous_run_id="$(gh run list --repo "$REPOSITORY" --workflow release.yml \
    --event workflow_dispatch --branch "$BRANCH" --limit 20 \
    --json databaseId,displayTitle \
    --jq ".[] | select(.displayTitle == \"$run_title\") | .databaseId" \
    | head -n 1)"

echo "Dispatching notarized release workflow…"
gh workflow run release.yml --repo "$REPOSITORY" --ref "$BRANCH" -f version="$VERSION"
if [ "$WATCH" = "0" ]; then
    echo "Workflow dispatched. Watch it with:"
    echo "  gh run list --repo $REPOSITORY --workflow release.yml"
    exit 0
fi

run_id=""
for _ in {1..30}; do
    run_id="$(gh run list --repo "$REPOSITORY" --workflow release.yml \
        --event workflow_dispatch --branch "$BRANCH" --limit 20 \
        --json databaseId,displayTitle \
        --jq ".[] | select(.displayTitle == \"$run_title\") | .databaseId" \
        | head -n 1)"
    if [ -n "$run_id" ] && [ "$run_id" != "$previous_run_id" ]; then break; fi
    run_id=""
    sleep 2
done
if [ -z "$run_id" ]; then
    echo "The workflow was dispatched, but its run did not appear within 60 seconds." >&2
    echo "Check: gh run list --repo $REPOSITORY --workflow release.yml" >&2
    exit 4
fi

gh run watch "$run_id" --repo "$REPOSITORY" --exit-status
browser_version="$(tr -d '[:space:]' < Plugins/chromium/VERSION)"
asset_names="$(gh release view "v$VERSION" --repo "$REPOSITORY" \
    --json assets --jq '.assets[].name')"
expected_assets=(
    "$PRODUCT_RELEASE_PREFIX-$VERSION-macOS-arm64.zip"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-macOS-arm64.zip.sha256"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-macOS-arm64.dmg"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-macOS-arm64.dmg.sha256"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-macOS-arm64.archive-notary.json"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-macOS-arm64.dmg-notary.json"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-macOS-arm64.publication.json"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.zip"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.zip.sha256"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.dmg"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.dmg.sha256"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.archive-notary.json"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.dmg-notary.json"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.publication.json"
    "$PRODUCT_RELEASE_PREFIX-$VERSION-browser-$browser_version-macOS-arm64.json"
)
for expected_asset in "${expected_assets[@]}"; do
    if ! grep -Fxq "$expected_asset" <<< "$asset_names"; then
        echo "Published release is missing required asset: $expected_asset" >&2
        exit 5
    fi
done
release_url="$(gh release view "v$VERSION" --repo "$REPOSITORY" \
    --json url --jq .url)"
echo "Published: $release_url"
echo "Verified lean and Browser edition assets."
