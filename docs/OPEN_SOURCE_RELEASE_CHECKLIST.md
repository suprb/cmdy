# Open-source release checklist

This is the first-publication runbook for cmdy. It is intentionally stricter
than the ordinary release process because repository history is part of the
artifact being published.

## Stop: do not publish this repository's history

**Do not change the current `andreas-pihlstrom/termite` repository from private
to public. Do not rename it to `cmdy`, convert it into a template, fork it, or
push it with `--mirror`.**

At the time this checklist was written, the private repository contained **315
commits** accumulated during product exploration. Even when the current tree is
clean, that history can retain deleted credentials, personal paths, recordings,
large binaries, abandoned experiments, private discussion, and objects that are
not visible in `git status`. Deleting a file in the latest commit does not remove
it from Git history.

The public project must be a new, independent repository with a clean or
squashed initial history. Keep the existing repository private as an internal
archive. `git filter-repo` is useful for forensic cleanup, but it is not a reason
to expose this development history when a clean launch repository is simpler and
safer.

## Canonical public surfaces

These names are contracts. Product identity, website links, update checks,
Marketplace defaults, release workflows, and issue templates already converge
on them.

| Surface | Canonical value |
|---|---|
| Source repository | `https://github.com/suprb/cmdy` |
| Default branch | `main` |
| Registry repository | `https://github.com/suprb/cmdy-registry` |
| Registry index | `https://raw.githubusercontent.com/suprb/cmdy-registry/main/registry.json` |
| Latest release API | `https://api.github.com/repos/suprb/cmdy/releases/latest` |
| Downloads | `https://github.com/suprb/cmdy/releases/latest` |
| Website | The HTTPS URL stored in the source repository's GitHub **Website** field |

Do not announce the project while any canonical URL redirects to the old
`termite` repository, returns a placeholder, or relies on a local development
server. The website field is the single source of truth for the live endpoint;
the public preflight reads it and checks `index.html`, `docs.html`, and
`marketplace.html`.

## 1. Freeze and validate the source tree

- [ ] Finish the open-source hardening branch without folding unrelated private
      history into a public branch.
- [ ] Run `./scripts/check-repository-hygiene.sh` and resolve every finding.
- [ ] Run the complete package, app, website, and packaging checks described in
      [ARCHITECTURE.md](ARCHITECTURE.md).
- [ ] Confirm `LICENSE` is MIT and `THIRD_PARTY_NOTICES.md` plus every bundled
      font, vendor, media, and code attribution is complete. A summary that
      points to a missing upstream license is a launch blocker.
- [ ] Remove generated apps, `dist/`, `.build/`, `node_modules/`, local CEF
      payloads, recordings containing local data, screenshots, swap files, and
      discovery credentials from the export.
- [ ] Review every tracked binary. Keep only deliberate product assets with a
      documented origin and redistribution right.
- [ ] Search tracked source for usernames, home directories, private hosts,
      tokens, API keys, signing identities, team identifiers, and internal-only
      notes.
- [ ] Run a secret scanner over both the private source history and the final
      clean public repository. Treat a hit in old history as compromised even if
      the value is believed to be inactive.

## 2. Create a clean source snapshot

Perform this outside the private repository so its `.git` directory, alternates,
refs, reflogs, and unreachable objects cannot follow the files.

```sh
# From the validated private checkout:
export CMDY_EXPORT="$(mktemp -d)/cmdy"
mkdir -p "$CMDY_EXPORT"
git archive --format=tar HEAD | tar -x -C "$CMDY_EXPORT"

cd "$CMDY_EXPORT"
git init -b main
git add --all
git commit -m "Initial open-source release"
```

- [ ] Verify `git rev-list --count HEAD` is `1` (or only a very small number of
      intentional launch commits).
- [ ] Verify the new repository has no object alternates and no remote pointing
      at `andreas-pihlstrom/termite`.
- [ ] Run the hygiene and secret scans again against the complete new history.
- [ ] Build and test from this exact export. Do not assume the private checkout's
      caches prove the export is complete.
- [ ] Before exporting, run the full historical similarity scan in the private
      repository and bind the approved review to a deterministic active-source
      path/hash manifest. The one-commit public repository cannot contain the
      two private historical comparison commits. Its CI must verify that
      approved manifest fail-closed for every terminal-stack file; do not simply
      skip provenance because the old refs are absent.
- [ ] Preserve contributor credit and upstream attribution in source headers,
      notices, and release notes. Squashing history does not erase attribution
      obligations.

## 3. Create the canonical GitHub repositories

Create `suprb/cmdy` and `suprb/cmdy-registry` as new,
independent repositories. They must not be forks of the private repository.
Keep them private while settings and first commits are prepared.

For both repositories:

- [ ] Default branch is `main`.
- [ ] Issues are enabled and the repository description is public-ready.
- [ ] An MIT license is detected by GitHub. Registry entries retain their own
      per-package licenses in addition to the registry repository license.
- [ ] `SECURITY.md`, `CODE_OF_CONDUCT.md`, support guidance, and contribution
      guidance are visible in the Community profile where applicable.
- [ ] Private vulnerability reporting is enabled.
- [ ] Secret scanning and push protection are enabled.
- [ ] Dependabot alerts and Dependabot security updates are enabled.
- [ ] The source repository's **Website** field contains the one canonical HTTPS
      production URL. The registry repository links back to the source project.

Push the clean source snapshot to `suprb/cmdy`. Seed
`cmdy-registry` from a separately reviewed clean export; do not carry private
registry history into it.

## 4. Protect `main`

Use branch protection on `main` in both repositories. The launch preflight
checks the classic branch-protection API, so configure equivalent settings there
rather than relying only on an unverified ruleset.

- [ ] Require pull requests and at least one approving review.
- [ ] Dismiss stale approvals when new commits are pushed.
- [ ] Require the repository's CI status checks and require the branch to be up
      to date before merging.
- [ ] Require conversation resolution.
- [ ] Require linear history.
- [ ] Apply the rules to administrators.
- [ ] Disable force pushes and branch deletion.
- [ ] Limit workflow permissions to read by default; grant `contents: write`
      only to the release job that publishes artifacts.
- [ ] Review every GitHub App, deploy key, environment, webhook, and Actions
      secret. Remove inherited or unused access.

For `cmdy-registry`, required CI must validate the schema, licenses, content
paths, hashes, archive boundaries, and shader compilation before merge.

## 5. Make releases trustworthy

- [ ] Add the Developer ID and App Store Connect notary secrets listed in
      [RELEASING.md](../RELEASING.md) to `suprb/cmdy`; use repository
      or environment secrets, never files or shell history.
- [ ] Set `VERSION`, update `CHANGELOG.md`, and create a signed release commit.
- [ ] Run `SKIP_NOTARIZE=1 ./release.sh` from the clean repository and inspect the
      `-rehearsal` ZIP, DMG, app signature, bundle identifiers, architecture,
      and checksums. Rehearsal filenames must not collide with stable assets.
- [ ] Publish one stable notarized release. It must contain matching
      `cmdy-<version>-macOS-<arch>.zip`, `.dmg`, and `.sha256` assets.
- [ ] Download the public assets on a clean Mac, verify checksums and Gatekeeper,
      launch the app, and exercise the update check.
- [ ] Confirm the latest-release API returns the stable release, not a draft or
      prerelease, and that the app selects the correct ZIP and exact checksum.

## 6. Verify the registry and website

- [ ] `cmdy-registry/main/registry.json` is valid JSON with a non-empty,
      duplicate-free `entries` array.
- [ ] Every native package URL is HTTPS, public, versioned, hash-pinned, and
      resolves to the advertised bytes.
- [ ] Marketplace install consent names the author, source, capabilities, and
      native-code trust boundary accurately.
- [ ] The website production root, `/docs.html`, and `/marketplace.html` return
      successfully without authentication.
- [ ] The live Marketplace reads the canonical raw registry and has a checked-in
      fallback snapshot generated from the same data.
- [ ] Download and source links point to `suprb/cmdy`, not the private
      repository or localhost.
- [ ] Test the website on a clean browser profile and at narrow and wide sizes.

## 7. Final visibility gate

Only after the clean repositories, settings, protections, release, registry, and
website are ready:

1. Change the two **new** canonical repositories to public.
2. Run the read-only external preflight from the clean source repository:

   ```sh
   ./scripts/check-public-release.sh
   ```

3. Require an all-green result. The script intentionally fails against the
   current private development checkout and missing canonical endpoints.
4. Re-clone `suprb/cmdy` anonymously into a new directory and repeat
   the build, tests, website verification, and license inspection.
5. Only then publish the announcement and enable public downloads in the site.

If a check fails after visibility changes, pause the announcement and fix the
new public repository. **Never solve a launch failure by making the old
315-commit private repository public.**
