#!/bin/bash
# Read-only first-publication preflight for cmdy.
# It performs GET requests only and never changes repositories or settings.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source scripts/product-identity.sh

OWNER="${CMDY_GITHUB_OWNER:-suprb}"
APP_REPOSITORY="${CMDY_PUBLIC_REPOSITORY:-$OWNER/cmdy}"
REGISTRY_REPOSITORY="${CMDY_REGISTRY_REPOSITORY:-$OWNER/cmdy-registry}"
DEFAULT_BRANCH="${CMDY_PUBLIC_BRANCH:-main}"
EXPECTED_SITE_URL="${CMDY_SITE_URL:-}"
MAX_INITIAL_COMMITS="${CMDY_MAX_INITIAL_COMMITS:-5}"
EXPECTED_PUBLIC_ROOT="${CMDY_PUBLIC_ROOT_COMMIT:-d9205a4a0673548a1552219337cf89f09d37a730}"
REGISTRY_URL="https://raw.githubusercontent.com/$REGISTRY_REPOSITORY/$DEFAULT_BRANCH/registry.json"
PROJECT_VERSION="$(tr -d '[:space:]' < VERSION)"
BROWSER_VERSION="$(tr -d '[:space:]' < Plugins/chromium/VERSION)"
EXPECTED_RELEASE_TAG="v$PROJECT_VERSION"
EXPECTED_BROWSER_ASSET="chromium-$BROWSER_VERSION.cmdyext"
EXPECTED_BROWSER_URL="https://github.com/$APP_REPOSITORY/releases/download/$EXPECTED_RELEASE_TAG/$EXPECTED_BROWSER_ASSET"
EXPECTED_BROWSER_SHA=""

FAILURES=0
PASSES=0

pass() {
    PASSES=$((PASSES + 1))
    printf 'PASS  %s\n' "$1"
}

fail() {
    FAILURES=$((FAILURES + 1))
    printf 'FAIL  %s\n' "$1" >&2
}

note() {
    printf '      %s\n' "$1"
}

for command_name in git gh curl python3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "required command is unavailable: $command_name"
    fi
done
if [ "$FAILURES" -ne 0 ]; then
    printf '\nPublic-release preflight stopped: install the required tools.\n' >&2
    exit 1
fi

if ! [[ "$MAX_INITIAL_COMMITS" =~ ^[0-9]+$ ]] || [ "$MAX_INITIAL_COMMITS" -lt 1 ]; then
    echo "CMDY_MAX_INITIAL_COMMITS must be a positive integer." >&2
    exit 2
fi
if ! [[ "$EXPECTED_PUBLIC_ROOT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "CMDY_PUBLIC_ROOT_COMMIT must be a lowercase 40-character Git object ID." >&2
    exit 2
fi
case "${APP_REPOSITORY##*/}" in
    termite|term64)
        echo "Refusing to treat the legacy private repository as the public source." >&2
        echo "Create the independent canonical repository: $OWNER/cmdy" >&2
        exit 2
        ;;
esac

if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI authentication is required for read-only security and branch-protection checks." >&2
    echo "Run 'gh auth login', then retry. No write scopes are used by this script." >&2
    exit 2
fi
export GH_PROMPT_DISABLED=1

CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cmdy-public-release.XXXXXX")"
trap 'rm -rf "$CHECK_TMP"' EXIT

json_value() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split("."):
    if not isinstance(value, dict):
        value = None
        break
    value = value.get(part)
if value is True:
    print("true")
elif value is False:
    print("false")
elif value is not None:
    print(value)
PY
}

json_count() {
    python3 - "$1" "${@:2}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)
count = 0
for path in sys.argv[2:]:
    value = document
    for part in path.split("."):
        value = value.get(part) if isinstance(value, dict) else None
    if isinstance(value, list):
        count += len(value)
print(count)
PY
}

fetch_url() {
    local label="$1"
    local url="$2"
    local output="$3"
    local error_file="$CHECK_TMP/curl-error"
    local status curl_status
    : > "$error_file"
    status="$(curl --location --silent --show-error \
        --connect-timeout 8 --max-time 25 \
        --output "$output" --write-out '%{http_code}' \
        "$url" 2>"$error_file")"
    curl_status=$?
    if [ "$curl_status" -ne 0 ]; then
        fail "$label is unreachable: $url"
        if [ -s "$error_file" ]; then
            note "$(head -n 1 "$error_file")"
        fi
        return 1
    fi
    case "$status" in
        2??)
            pass "$label returned HTTP $status"
            return 0
            ;;
        *)
            fail "$label returned HTTP $status: $url"
            return 1
            ;;
    esac
}

check_local_source() {
    local count branch origin roots root_count root
    count="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    roots="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"
    root_count="$(printf '%s\n' "$roots" | grep -Ec '^[0-9a-f]{40}$' || true)"
    root="$(printf '%s\n' "$roots" | head -n 1)"
    if [ "$root_count" -eq 1 ] && [ "$root" = "$EXPECTED_PUBLIC_ROOT" ]; then
        pass "local history descends from the reviewed clean public root ($count commit(s))"
    elif [ "$count" -le "$MAX_INITIAL_COMMITS" ]; then
        pass "local public history is intentionally small ($count commit(s))"
    else
        fail "local history has an unrecognized root and $count commits"
        note "Before first publication, allow at most $MAX_INITIAL_COMMITS commits; afterward, history must descend from $EXPECTED_PUBLIC_ROOT."
        note "Never publish the private 315-commit history."
    fi

    branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ "$branch" = "$DEFAULT_BRANCH" ]; then
        pass "local branch is $DEFAULT_BRANCH"
    else
        fail "local branch is '${branch:-detached}', expected '$DEFAULT_BRANCH'"
    fi

    origin="$(git remote get-url origin 2>/dev/null || true)"
    case "$origin" in
        "git@github.com:$APP_REPOSITORY.git"|\
        "https://github.com/$APP_REPOSITORY"|\
        "https://github.com/$APP_REPOSITORY.git")
            pass "origin is the canonical source repository"
            ;;
        *)
            fail "origin is '${origin:-unset}', expected github.com/$APP_REPOSITORY"
            ;;
    esac

    if [ -z "$(git status --porcelain)" ]; then
        pass "local working tree is clean"
    else
        fail "local working tree has uncommitted or untracked files"
    fi
}

fetch_repository() {
    local label="$1"
    local repository="$2"
    local output="$3"
    if gh api --method GET "repos/$repository" >"$output" 2>/dev/null; then
        pass "$label exists: $repository"
        return 0
    fi
    fail "$label is missing or inaccessible: $repository"
    return 1
}

check_repository_metadata() {
    local label="$1"
    local repository="$2"
    local metadata="$3"
    local visibility branch license fork archived issues
    visibility="$(json_value "$metadata" visibility)"
    branch="$(json_value "$metadata" default_branch)"
    license="$(json_value "$metadata" license.spdx_id)"
    fork="$(json_value "$metadata" fork)"
    archived="$(json_value "$metadata" archived)"
    issues="$(json_value "$metadata" has_issues)"

    [ "$visibility" = "public" ] \
        && pass "$label is public" \
        || fail "$label visibility is '${visibility:-unknown}', expected public"
    [ "$branch" = "$DEFAULT_BRANCH" ] \
        && pass "$label default branch is $DEFAULT_BRANCH" \
        || fail "$label default branch is '${branch:-unknown}', expected $DEFAULT_BRANCH"
    [ "$license" = "MIT" ] \
        && pass "$label license is detected as MIT" \
        || fail "$label license is '${license:-undetected}', expected MIT"
    [ "$fork" = "false" ] \
        && pass "$label is an independent repository" \
        || fail "$label is a fork; the public repositories must be independent"
    [ "$archived" = "false" ] \
        && pass "$label is active" \
        || fail "$label is archived"
    [ "$issues" = "true" ] \
        && pass "$label has Issues enabled" \
        || fail "$label has Issues disabled"
}

check_security() {
    local label="$1"
    local repository="$2"
    local metadata="$3"
    local branch="$4"
    local status security_file="$CHECK_TMP/${label}-security"

    for setting in secret_scanning secret_scanning_push_protection dependabot_security_updates; do
        status="$(json_value "$metadata" "security_and_analysis.$setting.status")"
        if [ "$status" = "enabled" ]; then
            pass "$label $setting is enabled"
        else
            fail "$label $setting is '${status:-unavailable}', expected enabled"
        fi
    done

    if gh api --method GET "repos/$repository/private-vulnerability-reporting" \
        >"$security_file" 2>/dev/null \
        && [ "$(json_value "$security_file" enabled)" = "true" ]; then
        pass "$label private vulnerability reporting is enabled"
    else
        fail "$label private vulnerability reporting is not enabled or not readable"
    fi

    if gh api --method GET "repos/$repository/contents/SECURITY.md?ref=$branch" \
        >/dev/null 2>&1; then
        pass "$label publishes SECURITY.md"
    else
        fail "$label does not publish SECURITY.md on $branch"
    fi
}

check_branch_protection() {
    local label="$1"
    local repository="$2"
    local branch="$3"
    local protection="$CHECK_TMP/${label}-protection.json"
    if ! gh api --method GET "repos/$repository/branches/$branch/protection" \
        >"$protection" 2>/dev/null; then
        fail "$label $branch protection is absent or unreadable"
        note "Configure classic protection and authenticate with repository-admin read access."
        return
    fi

    local approvals stale strict checks admins conversations linear force_pushes deletions
    approvals="$(json_value "$protection" required_pull_request_reviews.required_approving_review_count)"
    stale="$(json_value "$protection" required_pull_request_reviews.dismiss_stale_reviews)"
    strict="$(json_value "$protection" required_status_checks.strict)"
    checks="$(json_count "$protection" required_status_checks.contexts required_status_checks.checks)"
    admins="$(json_value "$protection" enforce_admins.enabled)"
    conversations="$(json_value "$protection" required_conversation_resolution.enabled)"
    linear="$(json_value "$protection" required_linear_history.enabled)"
    force_pushes="$(json_value "$protection" allow_force_pushes.enabled)"
    deletions="$(json_value "$protection" allow_deletions.enabled)"

    if [[ "$approvals" =~ ^[0-9]+$ ]] && [ "$approvals" -ge 1 ]; then
        pass "$label requires pull requests and $approvals approval(s)"
    else
        fail "$label does not require an approving pull-request review"
    fi
    [ "$stale" = "true" ] \
        && pass "$label dismisses stale approvals" \
        || fail "$label does not dismiss stale approvals"
    [ "$strict" = "true" ] && [ "$checks" -ge 1 ] \
        && pass "$label requires $checks up-to-date status check(s)" \
        || fail "$label does not require an up-to-date CI status check"
    [ "$admins" = "true" ] \
        && pass "$label protection applies to administrators" \
        || fail "$label protection does not apply to administrators"
    [ "$conversations" = "true" ] \
        && pass "$label requires conversation resolution" \
        || fail "$label does not require conversation resolution"
    [ "$linear" = "true" ] \
        && pass "$label requires linear history" \
        || fail "$label does not require linear history"
    [ "$force_pushes" = "false" ] \
        && pass "$label blocks force pushes" \
        || fail "$label allows force pushes"
    [ "$deletions" = "false" ] \
        && pass "$label blocks branch deletion" \
        || fail "$label allows branch deletion"
}

check_app_files() {
    local repository="$1"
    local branch="$2"
    for path in LICENSE CODE_OF_CONDUCT.md CONTRIBUTING.md SUPPORT.md \
        .github/dependabot.yml .github/workflows/ci.yml .github/workflows/release.yml; do
        if gh api --method GET "repos/$repository/contents/$path?ref=$branch" \
            >/dev/null 2>&1; then
            pass "source repository publishes $path"
        else
            fail "source repository is missing $path on $branch"
        fi
    done
}

check_release() {
    local repository="$1"
    local release_file="$CHECK_TMP/release.json"
    local assets_file="$CHECK_TMP/release-assets.txt"
    if ! gh api --method GET "repos/$repository/releases/latest" \
        >"$release_file" 2>/dev/null; then
        fail "latest stable release endpoint is missing: $repository/releases/latest"
        return
    fi
    pass "latest stable release endpoint is live"

    local draft prerelease tag
    draft="$(json_value "$release_file" draft)"
    prerelease="$(json_value "$release_file" prerelease)"
    tag="$(json_value "$release_file" tag_name)"
    [ "$draft" = "false" ] && [ "$prerelease" = "false" ] \
        && pass "latest release is stable" \
        || fail "latest release is a draft or prerelease"
    [ "$tag" = "$EXPECTED_RELEASE_TAG" ] \
        && pass "latest release is the checked-out version: $tag" \
        || fail "latest release is '${tag:-missing}', expected $EXPECTED_RELEASE_TAG"

    python3 - "$release_file" >"$assets_file" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)
for asset in release.get("assets", []):
    name = asset.get("name")
    if isinstance(name, str) and "\n" not in name:
        print(name)
PY

    local archive dmg
    archive="$(grep -E '^cmdy-[0-9]+\.[0-9]+(\.[0-9]+)?-macOS-[A-Za-z0-9_-]+\.zip$' \
        "$assets_file" | head -n 1 || true)"
    dmg="$(grep -E '^cmdy-[0-9]+\.[0-9]+(\.[0-9]+)?-macOS-[A-Za-z0-9_-]+\.dmg$' \
        "$assets_file" | head -n 1 || true)"
    [ -n "$archive" ] \
        && pass "release includes a canonical macOS ZIP: $archive" \
        || fail "release has no canonical cmdy macOS ZIP"
    [ -n "$dmg" ] \
        && pass "release includes a canonical macOS DMG: $dmg" \
        || fail "release has no canonical cmdy macOS DMG"
    if [ -n "$archive" ]; then
        grep -Fxq "$archive.sha256" "$assets_file" \
            && pass "release includes the ZIP checksum" \
            || fail "release is missing $archive.sha256"
    fi
    if [ -n "$dmg" ]; then
        grep -Fxq "$dmg.sha256" "$assets_file" \
            && pass "release includes the DMG checksum" \
            || fail "release is missing $dmg.sha256"
    fi

    local expected_assets browser_asset_url browser_checksum_url
    local asset_file checksum_file checksum_value actual_checksum release_digest
    expected_assets=(
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-macOS-arm64.zip"
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-macOS-arm64.zip.sha256"
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-macOS-arm64.dmg"
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-macOS-arm64.dmg.sha256"
        "$PRODUCT_RELEASE_PREFIX-macOS-arm64.zip"
        "$PRODUCT_RELEASE_PREFIX-macOS-arm64.zip.sha256"
        "$PRODUCT_RELEASE_PREFIX-macOS-arm64.dmg"
        "$PRODUCT_RELEASE_PREFIX-macOS-arm64.dmg.sha256"
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-browser-$BROWSER_VERSION-macOS-arm64.zip"
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-browser-$BROWSER_VERSION-macOS-arm64.zip.sha256"
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-browser-$BROWSER_VERSION-macOS-arm64.dmg"
        "$PRODUCT_RELEASE_PREFIX-$PROJECT_VERSION-browser-$BROWSER_VERSION-macOS-arm64.dmg.sha256"
        "$PRODUCT_RELEASE_PREFIX-browser-macOS-arm64.zip"
        "$PRODUCT_RELEASE_PREFIX-browser-macOS-arm64.zip.sha256"
        "$PRODUCT_RELEASE_PREFIX-browser-macOS-arm64.dmg"
        "$PRODUCT_RELEASE_PREFIX-browser-macOS-arm64.dmg.sha256"
        "$EXPECTED_BROWSER_ASSET"
        "$EXPECTED_BROWSER_ASSET.sha256"
    )
    for expected in "${expected_assets[@]}"; do
        grep -Fxq "$expected" "$assets_file" \
            && pass "release includes $expected" \
            || fail "release is missing $expected"
    done

    browser_asset_url="$(python3 - "$release_file" "$EXPECTED_BROWSER_ASSET" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)
for asset in release.get("assets", []):
    if asset.get("name") == sys.argv[2]:
        print(asset.get("browser_download_url", ""))
        break
PY
)"
    browser_checksum_url="$(python3 - "$release_file" "$EXPECTED_BROWSER_ASSET.sha256" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)
for asset in release.get("assets", []):
    if asset.get("name") == sys.argv[2]:
        print(asset.get("browser_download_url", ""))
        break
PY
)"
    checksum_file="$CHECK_TMP/browser-extension.sha256"
    if [ -n "$browser_checksum_url" ] \
        && fetch_url "Browser activation checksum" "$browser_checksum_url" "$checksum_file"; then
        if checksum_value="$(python3 - "$checksum_file" "$EXPECTED_BROWSER_ASSET" <<'PY'
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
if len(lines) != 1:
    raise SystemExit(1)
parts = lines[0].split()
if (len(parts) != 2 or not re.fullmatch(r"[0-9a-fA-F]{64}", parts[0])
        or pathlib.PurePosixPath(parts[1]).name != sys.argv[2]):
    raise SystemExit(1)
print(parts[0].lower())
PY
)"; then
            pass "Browser activation checksum names the exact release asset"
        else
            fail "Browser activation checksum is malformed"
        fi
    else
        fail "Browser activation checksum asset URL is missing"
    fi

    asset_file="$CHECK_TMP/$EXPECTED_BROWSER_ASSET"
    if [ -n "$browser_asset_url" ] \
        && fetch_url "Browser activation asset" "$browser_asset_url" "$asset_file"; then
        actual_checksum="$(python3 - "$asset_file" <<'PY'
import hashlib
import pathlib
import sys

digest = hashlib.sha256()
with pathlib.Path(sys.argv[1]).open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"
        if [ -n "${checksum_value:-}" ] \
            && [ "$actual_checksum" = "$checksum_value" ]; then
            EXPECTED_BROWSER_SHA="$actual_checksum"
            pass "Browser activation bytes match the published checksum"
        else
            fail "Browser activation bytes do not match the published checksum"
        fi
    else
        fail "Browser activation asset URL is missing"
    fi

    release_digest="$(python3 - "$release_file" "$EXPECTED_BROWSER_ASSET" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    release = json.load(handle)
for asset in release.get("assets", []):
    if asset.get("name") == sys.argv[2]:
        digest = asset.get("digest")
        if isinstance(digest, str):
            print(digest)
        break
PY
)"
    if [ -n "$release_digest" ]; then
        [ "$release_digest" = "sha256:$EXPECTED_BROWSER_SHA" ] \
            && pass "GitHub release metadata binds the Browser activation digest" \
            || fail "GitHub release metadata has a different Browser activation digest"
    fi
}

check_registry_index() {
    local registry_file="$CHECK_TMP/registry.json"
    if ! fetch_url "canonical registry index" "$REGISTRY_URL" "$registry_file"; then
        return
    fi
    local summary
    if summary="$(python3 - "$registry_file" "$BROWSER_VERSION" \
        "$EXPECTED_BROWSER_URL" "$EXPECTED_BROWSER_SHA" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)
entries = document.get("entries") if isinstance(document, dict) else None
if not isinstance(entries, list) or not entries:
    raise SystemExit("registry.json must contain a non-empty entries array")
ids = [entry.get("id") for entry in entries if isinstance(entry, dict)]
if len(ids) != len(entries) or any(not isinstance(item, str) or not item for item in ids):
    raise SystemExit("every registry entry must have a non-empty string id")
if len(ids) != len(set(ids)):
    raise SystemExit("registry entry ids must be unique")
browser = next((entry for entry in entries
                if entry.get("id") == "dev.termite.chromium"), None)
if not isinstance(browser, dict):
    raise SystemExit("Browser entry is missing")
expected_version, expected_url, expected_sha = sys.argv[2:]
if browser.get("version") != expected_version:
    raise SystemExit(f"Browser version is {browser.get('version')!r}, expected {expected_version}")
if browser.get("url") != expected_url:
    raise SystemExit("Browser URL does not target the expected immutable release")
if not expected_sha or browser.get("sha256", "").lower() != expected_sha:
    raise SystemExit("Browser SHA-256 does not match the published checksum")
print(f"{len(entries)} unique entries; Browser {expected_version} is release-bound")
PY
)"; then
        pass "canonical registry is valid ($summary)"
    else
        fail "canonical registry structure is invalid: $summary"
    fi
}

check_site() {
    local metadata="$1"
    local homepage
    homepage="$(json_value "$metadata" homepage)"
    if [ -z "$homepage" ]; then
        fail "source repository has no canonical Website URL"
        return
    fi
    case "$homepage" in
        https://*) ;;
        *)
            fail "source repository Website URL is not HTTPS: $homepage"
            return
            ;;
    esac
    if [ -n "$EXPECTED_SITE_URL" ] \
        && [ "${homepage%/}" != "${EXPECTED_SITE_URL%/}" ]; then
        fail "Website URL '$homepage' does not match CMDY_SITE_URL '$EXPECTED_SITE_URL'"
    else
        pass "source repository declares canonical Website URL: $homepage"
    fi

    local base="${homepage%/}"
    local index_file="$CHECK_TMP/site-index.html"
    if fetch_url "live website" "$base/" "$index_file"; then
        if grep -Eqi 'cmdy' "$index_file"; then
            pass "live website identifies cmdy"
        else
            fail "live website does not identify cmdy"
        fi
    fi
    fetch_url "live documentation" "$base/docs.html" "$CHECK_TMP/site-docs.html" || true
    fetch_url "live Marketplace" "$base/marketplace.html" "$CHECK_TMP/site-marketplace.html" || true
    local snapshot_file="$CHECK_TMP/site-marketplace-data.js"
    local registry_file="$CHECK_TMP/registry.json"
    if fetch_url "live Marketplace snapshot" "$base/marketplace-data.js" "$snapshot_file" \
        && [ -s "$registry_file" ]; then
        local snapshot_summary
        if snapshot_summary="$(python3 - "$snapshot_file" "$registry_file" <<'PY'
import hashlib
import json
import re
import sys

snapshot_bytes = open(sys.argv[1], "rb").read()
registry_bytes = open(sys.argv[2], "rb").read()
snapshot_text = snapshot_bytes.decode("utf-8")
match = re.search(r"window\.CMDY_MARKETPLACE_SNAPSHOT\s*=\s*(\{.*\})\s*;\s*$",
                  snapshot_text, re.DOTALL)
if not match:
    raise SystemExit("snapshot JavaScript does not contain the registry object")
snapshot = json.loads(match.group(1))
registry = json.loads(registry_bytes)
if snapshot != registry:
    raise SystemExit("snapshot content differs from the live registry")
digest = hashlib.sha256(registry_bytes).hexdigest()
if f"Registry sha256: {digest}" not in snapshot_text:
    raise SystemExit("snapshot header does not bind the live registry digest")
browser = next(entry for entry in snapshot["entries"]
               if entry.get("id") == "dev.termite.chromium")
print(f"Browser {browser['version']}; registry sha256 {digest[:12]}")
PY
)"; then
            pass "live Marketplace snapshot matches the registry ($snapshot_summary)"
        else
            fail "live Marketplace snapshot is stale or invalid: $snapshot_summary"
        fi
    fi
}

printf 'cmdy public-release preflight (read-only)\n'
printf '  source:   %s\n' "$APP_REPOSITORY"
printf '  registry: %s\n' "$REGISTRY_REPOSITORY"
printf '  branch:   %s\n\n' "$DEFAULT_BRANCH"

check_local_source

APP_METADATA="$CHECK_TMP/app-repository.json"
REGISTRY_METADATA="$CHECK_TMP/registry-repository.json"

if fetch_repository "source repository" "$APP_REPOSITORY" "$APP_METADATA"; then
    check_repository_metadata "source repository" "$APP_REPOSITORY" "$APP_METADATA"
    check_security "source" "$APP_REPOSITORY" "$APP_METADATA" "$DEFAULT_BRANCH"
    check_branch_protection "source" "$APP_REPOSITORY" "$DEFAULT_BRANCH"
    check_app_files "$APP_REPOSITORY" "$DEFAULT_BRANCH"
    check_release "$APP_REPOSITORY"
else
    fail "latest release, live website, source security, and source branch protection cannot be verified"
fi

if fetch_repository "registry repository" "$REGISTRY_REPOSITORY" "$REGISTRY_METADATA"; then
    check_repository_metadata "registry repository" "$REGISTRY_REPOSITORY" "$REGISTRY_METADATA"
    check_security "registry" "$REGISTRY_REPOSITORY" "$REGISTRY_METADATA" "$DEFAULT_BRANCH"
    check_branch_protection "registry" "$REGISTRY_REPOSITORY" "$DEFAULT_BRANCH"
else
    fail "registry security and branch protection cannot be verified"
fi

check_registry_index
if [ -s "$APP_METADATA" ]; then
    check_site "$APP_METADATA"
fi

if [ "$FAILURES" -ne 0 ]; then
    printf '\nResult: %d passed, %d failed.\n' "$PASSES" "$FAILURES" >&2
    echo "Public launch is NOT ready. See docs/OPEN_SOURCE_RELEASE_CHECKLIST.md." >&2
    exit 1
fi
printf '\nResult: %d passed, %d failed.\n' "$PASSES" "$FAILURES"
echo "Public launch preflight passed."
