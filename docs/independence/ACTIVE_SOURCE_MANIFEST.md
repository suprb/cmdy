# Active terminal-source manifest

Status: integrity tooling only; no human provenance approval is recorded here.

The private-history provenance scan and the public-export manifest check answer
different questions:

- `check-working-tree-provenance.py` compares active implementation source with
  the frozen vendor and retired commits before export.
- `check-active-source-manifest.py` binds the resulting source paths, modes,
  sizes, hashes, and discovery policy. It uses no historical Git refs, so it can
  run fail-closed in a one-commit public export.

Passing the manifest check means only that the checked tree matches the exact
unreviewed or separately reviewed snapshot supplied to it. It does not establish
independent authorship. A human review record must separately bind the manifest
SHA-256 before any approval claim is made.

## Governed source set

The policy includes every recursive Swift source in `App/` and the complete
active CmdyCore, CmdyPTY, CmdyPTYShim, CmdyC, CmdyGPU, CmdyKit,
ProductIdentity, CmdySDK, and ChromiumSupport source targets. It rejects new
uncovered source roots; Swift, Metal, C-family, assembly, header, module-map, or
API-notes file types that are not allowed by a configured root; retired
source/test roots or App files; every `SwiftTerm` or `Termite*` module import in
the active product source layers; and retired module references in the active
package manifests.
Every configured import-scan root must exist as a real directory, and no path
component or child in a governed, trust-input, or import-scan tree may be a
symlink.

Every manifest source entry records its repository-relative path, regular-file
mode (`100644` or `100755`), byte size, and SHA-256. The manifest also records a
canonical policy descriptor and the SHA-256 of the checker implementation. A
separate `trustFiles` collection binds the bytes, mode, and identity of every
active Swift package manifest plus the product-identity resource read by the
root manifest, so dependency/product/target graph changes fail verification
even when terminal source files are unchanged.
Verification rejects any path addition or removal, byte or mode change, source
symlink, missing scan root, retired boundary, malformed manifest, package graph
drift, or policy drift. JSON integer fields require actual integers; booleans are
not accepted as Python/JSON integer aliases. Verification checks the supplied
manifest path before canonicalization and refuses a symlink rather than silently
following it.

## Provisional local snapshot

Generate only outside the repository while review is pending:

```sh
PROVISIONAL_DIR="$(mktemp -d /tmp/cmdy-active-source.XXXXXX)"
python3 -B scripts/check-active-source-manifest.py generate \
  --output "$PROVISIONAL_DIR/active-terminal-sources.json"
python3 -B scripts/check-active-source-manifest.py verify \
  --manifest-root "$PROVISIONAL_DIR" \
  --manifest "$PROVISIONAL_DIR/active-terminal-sources.json"
shasum -a 256 "$PROVISIONAL_DIR/active-terminal-sources.json"
```

Private-history CI runs the historical similarity scanner while its frozen
comparison commits are available. The clean public repository does not carry
those commits: its CI instead verifies the checked-in manifest and the approved
publication record fail-closed. Missing historical refs never turn the check
into a skip.

Generation refuses to overwrite an existing file. Output is deterministic and
contains `reviewState: "unreviewed"`; the tool has no approval mode.

Run the focused fail-closed suite with:

```sh
python3 -B Tests/test-active-source-manifest.py
```

## Clean public export

Before a public source manifest is checked in, the private source review must be
green and an independent reviewer must bind the exact generated manifest hash.
Public CI can then run the same `verify --manifest <reviewed-path>` command in a
fresh checkout. It must not catch a missing historical ref and silently switch
modes: private-history comparison and public manifest verification are explicit,
separate gates.

The manifest, checker, test, and eventual CI invocation are review trust roots.
Changes to any of them require the protected review policy chosen for the public
repository. No reviewed or approved manifest is committed by this document.
