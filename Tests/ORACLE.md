# The parked oracle

SwiftTerm was removed on 2026-07-05 after all caught divergences were fixed
and a fresh soak ran clean. The differential harness and its oracle corpus
were archived outside the repository, while this document preserves the
repeatable test procedure:

- The last SwiftTerm-linked `termite-diff` contained all 25 divergence
  fixes. Soaking ran as GENERATION LANES: `soak-worker.sh <lane>` loops
  bounded 12k-round generations, a fresh process and a fresh seed each
  time. Reason: an unbounded run leaks ~10 KB/round (autorelease churn
  plus per-instance growth deep in the reference engine) — six immortal
  workers once reached 23 GB EACH. Generations cap the damage at
  ~300 MB/worker peak (measured) and add seed diversity, which is what finds bugs. The
  harness also drains an autoreleasepool per round now; the patch is
  `harness-autoreleasepool.patch` next to the binary (apply to a
  worktree of the pre-deletion commit to rebuild).
- Status: `grep -c "✗ fuzz round" ~/.cache/termite-oracle/soak/lane-*.log`.
  All zeros is an immediate clean result. Nonzero counts require
  `Tests/oracle-triage.sh` and comparison with `baseline.tsv`; acceptance then
  means zero *new* characterized divergences, not zero raw historical repros.
  Use that exact string — bare "diverged" matches the startup banner and
  "DIVERGE" misses the lowercase reality.
- If a worker ever finds something: the minimized `.bin` lands in
  `/tmp/termite-diff-fuzz-<seed>-<round>.bin`; verify with
  `~/.cache/termite-oracle/termite-diff --bytes <file>` (the marker is
  **`DIVERGED`**, not "DIVERGENCE" — grepping the wrong word scores every
  repro as clean), then decide fix-vs-mirror and, if you fix, copy the repro
  into `Tests/corpus/regressions/`.
- **Triage a batch**: `Tests/oracle-triage.sh` replays every repro in
  `~/.cache/termite-oracle/soak/repros/`, drops the stale ones, and clusters
  survivors by signature. Baseline of known-characterized divergences:
  `~/.cache/termite-oracle/soak/baseline.tsv` — diff new soaks against it so
  only NEW divergences raise a flag. Full writeup: `Tests/DIVERGENCES.md`.
- The regressions corpus (31 locked-in repros) + the recorded sessions
  are replayed by `Core/Tests` (`testCorpusReplaysAreDeterministic`) on
  every `swift test` — no crash, byte-identical across runs.
- Full resurrection, if ever needed: `git revert` of the removal commit
  brings back `Vendor/SwiftTerm`, the adapter, and the harness intact.

History: the plan's soak gate earned its keep — the first six-seed soak
caught 22 divergences about an hour in (+3 more from a fresh seed during
the fixing; six root causes, commit 4fbd3d2). A later 3.8-day four-lane soak
(2026-07-09) surfaced 173 repros → 75 that reproduce standalone → **zero core
bugs**: 10 cases where the *reference* is buggy (core correctly clears on
RIS/DECCOLM where SwiftTerm keeps stale text), 30 C1/invalid-UTF-8 cursor
policy gray areas, 35 erased-cell-attribute quirks. The oracle's verdict was
"don't touch the engine" and it was right (`Tests/DIVERGENCES.md`, commit
2ef3f99). Lesson: a mature engine's remaining divergences are increasingly the
reference's own bugs — never blind-fix to match.
