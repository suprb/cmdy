# Opt-in post-sample public history verification

This mode adds `--post-sample-history` to `memory_bench.py` and
`NativePerformance/compare_memory.py prepare`. The default remains memory schema
4. The September 16 current-build comparison (`2026-09-16-input-activity-memory.md` in the private performance notes)
uses the qualified frozen schema-5 harness with its recorded runtime/cache/path
and owned-window-origin corrections. It completed a fresh two-app pilot and
36 measured launches. The direct-checkout scripts do not yet include every
frozen-harness correction. No performance or visual qualification is inherited
from the earlier file-only pilots.

| Record | Existing memory mode | Opt-in memory mode | File-only pilot |
| --- | --- | --- | --- |
| Memory manifest | 4 | 5 | none |
| Supervisor plan | 1 | 2 | separate pilot plan |
| Public session binding | 1 | 3 | 2 for phased export |
| History result | 1 | 3 | 2 for phased export |
| Transfer | 1 | 4 | 2 / 3 |
| Generated file proof | original compatibility | strict 2 | strict 2 |
| Native window ownership | existing visual guard | same existing visual guard | explicitly nonvisual |

The new transport is `public-case-file-paste-path-post-sample-visual-v1`, with
`verificationScope=strict-visual-memory-v1` and
`verificationPolicy=post-sample-public-history-v1`. Native `proofScope` remains
absent. The new selector allows only inspection and key posting; it cannot
authorize `observe`, resize, or startup capture. All original native window,
foreground, occlusion, process lifetime, UID, ancestry, TTY and grid checks remain.
The known OS window-occlusion rejection is therefore still possible and must
remain a failed precondition. No process allowlist or transparency assumption
has been added.

All six original memory samples finish before verification: the matched-grid
sample, five-second settled baseline, separate five-second idle-CPU endpoint,
and post-drain samples at 0, 1 and 5 seconds. The original workload bytes, DSR
drain, settle intervals, samples, CPU normalization and metric extraction are
unchanged. The phase boundary is the last sample's complete guard finish. The
reader joins that exact boundary to the phase, native clock conversion, original
drain, owned identities, shortcut, complete generated export and cleanup.

Primary 1,000- and 5,000-row cases then write the existing fixed verification
payload: position at row 36 / column 1, exactly 35 CRLFs, and the exact row 36 /
column 1 DSR. Alternate-screen verification writes no extra output and uses the
public `write_screen_file:paste` action. Nothing synthesizes missing numbered
rows, broadens the padding bound, changes screens, uses a selection, or accesses
the clipboard. Key-post receipts keep `actionInvocationVerified=false`; actual
complete generated-file delivery must independently succeed.

Both owned app launches explicitly select child-only umask 0077. The plan,
launch and binding record the same value; generic session defaults are unchanged.
The new reader joins app and worker executable paths using the previously
qualified canonical alias function, with exact regular-file identity, size,
SHA-256 and stable descriptor/named-path checks. The interpreter is separately
pinned before launch and checked again at completion. Alias replay consequently
requires the corresponding exact executable files to remain available.

File-only transfer schemas 2 and 3 remain rejected by the memory reader, even if
relabelled or given a fabricated `occluded=false` field. A new schema 5 archive
must retain the extra shared executable-identity source; old schema 4 inventories
retain their original meaning. All new preparation inputs, helper bytes and
tooling must be frozen and reviewed before a native run. The shared activity
supervisor and parity policy are unchanged.
