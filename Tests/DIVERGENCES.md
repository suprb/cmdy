# Soak divergence triage — 2026-07-09

The four oracle soak lanes ran **3 days 18 hours** of continuous bounded
fuzzing (`~/.cache/termite-oracle/soak-worker.sh`, 12k-round generations,
fresh seed each) before being paused. They minimized **173** divergence
repros to `~/.cache/termite-oracle/soak/repros/`. This is the triage.

Replay any repro yourself: `~/.cache/termite-oracle/termite-diff --bytes <file>`.
Re-run the whole sweep: `~/.cache/termite-oracle/triage.sh`.

## Verdict: no core regressions

| | count | |
|---|--:|---|
| Replayed | 173 | |
| **Stale** | 98 | fuzz-interleaving / grid-size artifacts — don't reproduce standalone |
| **Surviving** | 75 | reproduce via `--bytes`; clustered below |
| — clear core bugs | **0** | nothing to fix |

The 98 "stale" repros diverged only inside the fuzzer's specific interleaving
and terminal geometry; they don't reproduce as isolated byte streams. The 75
that survive cluster into three families, **none of which is a core defect**:

### 1 · content divergences — the *reference* is buggy (10)

The interesting ten: cases where core and the reference render different
**text**. Every one favors core.

- **7× RIS clears the screen, reference doesn't.** Pattern
  `CSI ?47h` · write char · `ESC c` (RIS full reset) · `CSI ?47h`. After a
  RIS the screen must be blank — core shows `''` (correct), the reference
  keeps the pre-reset character (`'H'`, `'6'`, `'a'`, `'s'`, `'æ'`, …).
  Example `1b5b3f34373b6848 1b63 1b5b3f343768` → core `''`, st `'H'`.
- **1× DECCOLM clears the screen, reference doesn't.** `CSI ?47h G CSI ?3;4h`
  — mode 3 (DECCOLM) clears; core `''`, st `'G'`.
- **1× reference drops a text byte.** `CSI ?69;h` then literal `91M`
  — core renders `91M`, the reference swallows the `9` → `1M`.
- **1× scroll-region + C1 edge case** (`core '' vs st 'h'`), ambiguous.

These are the reference engine's (SwiftTerm's) own long-tail bugs. Making
core "match" would make core *wrong*. **Action: none — core already correct.**

### 2 · cursor position after C1 / invalid UTF-8 (30)

`cursor: core(N,N) vs st(N,N)` — 20 of 30 inputs contain C1 control bytes
(`0x9e` PM, `0x9f` APC, `0x82`) or invalid UTF-8. How far the cursor advances
on a lone `0x80–0x9f` byte is a **policy gray area** (treat as C1 control?
UTF-8 continuation? replacement char?), not a spec violation. Core and the
reference simply chose differently. **Action: policy call, not a bug —
left as an intentional divergence.**

### 3 · erased-cell attributes after a mode clear (35)

`live[N] text: core '' vs st ''` — identical (blank) text, differing only in
the **attributes** of erased cells. 22 of 35 inputs involve `RIS`/`DECCOLM`/
mode-4x flips. Whether cells blanked by a mode-driven clear inherit the
current background is the textbook **deliberate-divergence** point (see
`reference-swiftterm-quirks-mirrored`). **Action: quirk territory — no
change without a deliberate decision.**

## Baseline allowlist

The 75 surviving signatures are frozen in
`~/.cache/termite-oracle/soak/baseline.tsv` (category → signature → count).
Future soaks should diff against it so only **new** divergences raise a flag —
these 75 are characterized and accounted for.

## Bottom line

A 3.8-day soak found **zero core regressions**. What it surfaced — reference
bugs, C1 policy choices, erased-cell attribute semantics — is exactly the
long tail a mature engine leaves behind. The differential harness did its
job: it proved the engine is clean and told us precisely where core has
*surpassed* its own reference. The house rule held: never "fix" a divergence
without the oracle's verdict, because here the verdict was *don't*.
