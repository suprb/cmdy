#!/usr/bin/env bash
# Fast, deterministic checks for mistakes that must never reach the public repo.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    printf 'repository hygiene: %s\n' "$*" >&2
    exit 1
}

required_documents=(
    LICENSE
    THIRD_PARTY_NOTICES.md
    SECURITY.md
    CODE_OF_CONDUCT.md
    CONTRIBUTING.md
    SUPPORT.md
    CHANGELOG.md
    docs/ARCHITECTURE.md
)
for document in "${required_documents[@]}"; do
    [ -f "$document" ] || fail "missing $document"
done

for lockfile in \
    Vendor/BraincellBridge/Package.resolved; do
    [ -f "$lockfile" ] || fail "missing reproducible dependency lockfile $lockfile"
done

temporary_files="$(git ls-files | grep -E '(^|/)(\.DS_Store|.*\.sw[a-z]$|.*~$)' || true)"
[ -z "$temporary_files" ] || {
    printf '%s\n' "$temporary_files" >&2
    fail "tracked editor or operating-system temporary files"
}

generated_captures="$(git ls-files 'Tests/zoo-results/*.png' 'Tests/zoo-results/**/*.png')"
[ -z "$generated_captures" ] || {
    printf '%s\n' "$generated_captures" >&2
    fail "tracked zoo captures may expose machine-local state"
}

# The website, first-party Extensions and working notes live in the private
# cmdy-private repository. Keep them out of this open-source tree.
private_tree="$(git ls-files 'site' 'site/**' 'website' 'website/**' \
    'Plugins/appdock' 'Plugins/appdock/**' 'Plugins/bridge' 'Plugins/bridge/**' \
    'Plugins/detox' 'Plugins/detox/**' \
    'Plugins/sim' 'Plugins/sim/**' 'Plugins/swarm' 'Plugins/swarm/**' \
    'docs/performance' 'docs/performance/**' 'docs/roadmap' 'docs/roadmap/**' \
    'docs/history' 'docs/history/**')"
[ -z "$private_tree" ] || {
    printf '%s\n' "$private_tree" >&2
    fail "private website, Extension, or notes content is tracked in the public repository"
}

ci_publication_gate="$(grep -n -E '(^|[[:space:]])publication([[:space:]]|$)' .github/workflows/ci.yml || true)"
[ -z "$ci_publication_gate" ] || {
    printf '%s\n' "$ci_publication_gate" >&2
    fail "ordinary CI must not require human publication approval; keep that gate in the release workflow"
}

while read -r mode _ _ tracked_path; do
    [ "$mode" = "120000" ] || continue
    target="$(git show ":$tracked_path")"
    case "$target" in
        /*)
            printf '%s -> %s\n' "$tracked_path" "$target" >&2
            fail "tracked absolute symlink"
            ;;
    esac
done < <(git ls-files -s)

personal_literals="$(git grep -I -n -E \
    '(/Users/suprb|/var/folders/[^[:space:]]+|andreass-mbp|suprb@)' \
    -- ':!scripts/check-repository-hygiene.sh' || true)"
[ -z "$personal_literals" ] || {
    printf '%s\n' "$personal_literals" >&2
    fail "machine-local identity or path literal"
}

secret_literals="$(git grep -I -n -E \
    '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})' \
    -- ':!scripts/check-repository-hygiene.sh' || true)"
[ -z "$secret_literals" ] || {
    printf '%s\n' "$secret_literals" >&2
    fail "possible committed credential"
}

trailing_whitespace="$(git grep -I -n -E '[[:blank:]]+$' \
    -- . ':!Tests/corpus/**' || true)"
[ -z "$trailing_whitespace" ] || {
    printf '%s\n' "$trailing_whitespace" >&2
    fail "tracked text contains trailing whitespace"
}

for schema in Schemas/*.schema.json; do
    python3 -m json.tool "$schema" >/dev/null
done
./scripts/check-product-identity.sh >/dev/null
git diff --check
# `git diff --check` is intentionally empty on a clean CI checkout. Check the
# committed change as well there; `--root` also makes the future clean-snapshot
# repository validate every file in its first public commit.
if git diff --quiet && git diff --cached --quiet; then
    git diff-tree --check --root --no-commit-id -r HEAD
fi

printf 'Repository hygiene checks passed.\n'
