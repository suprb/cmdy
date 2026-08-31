# Independent provenance review record

This is the required record for the final human review of cmdy's replacement
terminal stack. Copy this file to a dated review record only after the exact
source has been committed and every referenced engineering artifact is durable.
Leaving any required field blank means the independence claim is not approved.

This review is an authorship/provenance assessment, not legal certification.
Counsel must review any stricter legal clean-room wording separately.

The completed review must also be encoded in
[`RELEASE_QUALIFICATION.json`](RELEASE_QUALIFICATION.json). The Markdown record
alone cannot unlock publication; the verifier requires exact machine-readable
source/evidence hashes and the independent-human approval fields.

## Reviewed identity

- Decision: `pending` (`approved` or `rejected` in a completed record)
- Reviewer name and affiliation:
- Reviewed date (UTC):
- Repository URL:
- Commit SHA:
- Git tree SHA:
- Active terminal-source path/hash manifest SHA-256:
- Reviewer confirms independence from replacement implementation: `no`

## Required engineering evidence

- Frozen lineage inventory SHA-256:
- Working-tree provenance report SHA-256:
- Working-tree provenance result (`unresolved=0`, `issues=0` required):
- Public API comparison manifest SHA-256:
- Unicode full-scalar result digest:
- Core reference library SHA-256:
- Core candidate library SHA-256:
- Core 17-seed result manifest SHA-256 (`53,992/53,992` required):
- Renderer corpus lock SHA-256:
- Renderer corpus archive SHA-256:
- Renderer corpus validator-vector SHA-256:
- Renderer reference manifest SHA-256:
- Renderer fixture-index SHA-256:
- Renderer candidate module SHA-256:
- Renderer candidate object-set aggregate SHA-256:
- Renderer fixture source SHA-256:
- Renderer `comparison.json` SHA-256 (`40/40`, zero input/pixel failures,
  and an empty exception list required):
- Renderer `environment.json` SHA-256:
- Performance-gate result hashes (normal and maximized):
- Resource-plateau result hash:
- TUI-zoo capture manifest hash:
- TUI-zoo visual-review record hash:

## Review questions

1. Does any active implementation remain copied, translated, moved, or adapted
   from SwiftTerm beyond declarations, data, or mechanics explicitly classified
   in the inventory?
2. Do all retained Cmdy-authored regions have repository evidence that predates
   or is independent of the imported implementation?
3. Are every uncertain match and every allowlist entry narrow, necessary, and
   bound to the reviewed source bytes?
4. Do the behavioral oracles expose results only, without supplying private
   implementation source to replacement authors?
5. Do current notices preserve all required historical attribution?
6. Is the proposed public wording no broader than the evidence supports?

## Verdict

- Approved public wording (exact text):
- Rejected or excluded wording:
- Conditions or follow-up work:
- Reviewer signature or verifiable approval reference:

## Post-approval artifact attestation

Complete this section only after the source verdict above is approved and the
release workflow has notarized and stapled the artifacts. Apple submission
cannot precede source approval because `release.sh` deliberately refuses to
load signing/notary credentials until publication source verification passes.
This attestation supplements the source verdict; it is not an input to it.

- Lean `*.publication.json` SHA-256:
- Lean archive Apple receipt SHA-256 and submission ID:
- Lean DMG Apple receipt SHA-256 and submission ID:
- Browser `*.publication.json` SHA-256:
- Browser archive Apple receipt SHA-256 and submission ID:
- Browser DMG Apple receipt SHA-256 and submission ID:
- Public GitHub Release URL:
- Artifact attestation reviewer, UTC time, and verifiable reference:
