# Release qualification boundary

Status: engineering integrity is automated; publication requires a recorded
human approval bound to the exact source and evidence set.

[`RELEASE_QUALIFICATION.json`](RELEASE_QUALIFICATION.json) is the machine-readable
trust root for the independent terminal stack. It deliberately separates two
claims:

- `engineering` proves that the active-source policy, provenance scanner, Core
  oracle, renderer checker and locked corpus, performance/resource/zoo tools,
  and package/release tools are the exact bytes named in the record. It also
  generates and verifies a fresh active-source manifest. That manifest remains
  explicitly `unreviewed`; passing this mode is not human provenance approval.
- `publication` is a strict superset. It fails unless a human has approved a
  committed active-source snapshot and bound every required result hash plus
  the exact permitted public wording. An independent reviewer may approve an
  authorship claim. A project owner may approve a release only when the bound
  wording explicitly says that the approval is not an independent authorship
  or legal clean-room review. Pending, rejected, incomplete, or internally
  inconsistent evidence cannot pass.

Normal CI runs:

```sh
python3 -B Tests/test-release-qualification.py
python3 -B scripts/check-release-qualification.py engineering
```

The real notarized path runs publication source verification before loading
signing credentials, then artifact verification after Apple accepts both
submissions and the final app/DMG have been stapled and Gatekeeper-tested:

```sh
python3 -B scripts/check-release-qualification.py publication --phase source
```

`SKIP_NOTARIZE=1 ./release.sh` is only a local rehearsal and intentionally does
not run or emit publication qualification.

## Approval data

To move `publication.state` to `approved`, durable, checked-in JSON evidence must
be added and referenced by repository-relative path and exact SHA-256. The
approval record must contain all of the following:

- a source commit and Git tree plus the canonical active-source manifest;
- the JSON output of the working-tree provenance scan with `ok=true`, zero
  unresolved matches, and zero issues;
- a Core matrix record for the fixed 17 seeds, exactly 3,176 cases per seed and
  53,992 total cases, with zero failures and no exceptions;
- renderer `comparison.json` and `environment.json` proving all 40 locked
  fixtures have byte-identical public inputs, zero pixel differences, and no
  exceptions;
- normal and maximized performance logs, a multi-run resource-plateau record,
  and a TUI-zoo capture manifest whose separate visual review passes the exact
  `check-zoo-review.py verify-review --require-decision approved` gate;
- a human reviewer identity, affiliation, UTC time, approval reference, exact
  approved wording, and a truthful declaration of whether the reviewer is
  independent of the replacement implementation. Owner approval must include
  the checker's exact non-independent-review notice.

The approval hashes the complete engineering policy and source/evidence set.
The source commit may precede the commit that adds the review record, avoiding a
self-referential Git hash. The verifier proves that the approved manifest
matches both that committed source snapshot and the current active tree. It
also rejects every release-tree delta except the qualification record and the
exact hash-bound files it references under `docs/independence/qualification/`;
being a descendant of the reviewed commit is never sufficient on its own.

The locked renderer corpus records `humanReviewStatus: "approved"` after the
project approver visually reviewed the two contact sheets covering all 40
fixtures at 1× and 2×. The resulting lock/checker bindings and strict candidate
evidence must still be regenerated against the final source freeze. The
active-source manifest itself remains
`reviewState: "unreviewed"` by design; the separate human approval is the only
component allowed to turn those exact bytes into a publication claim. Owner
approval authorizes the release but does not create an independence claim.

## Package evidence

Apple notarization occurs only after the source approval and before
stapling, so the submitted bytes are not the same as the downloadable bytes.
`release.sh` retains each raw Apple JSON result beside the release artifacts
plus the submitted SHA-256 for the initial ZIP and DMG, then the artifact phase
records the final checksums after stapling. It independently rechecks Developer
ID, hardened runtime, stapler validation, Gatekeeper, DMG structure, bundle
identity, version, and build. The emitted `*.publication.json` records therefore
never claim that the post-staple artifact itself was the submitted object.
Source approval and post-notary artifact attestation are separate, avoiding a
cycle in which approval would require Apple IDs that cannot exist before
approval.

This is an engineering/authorship control, not legal certification. Any broader
legal clean-room claim still requires counsel.
