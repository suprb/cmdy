# Paired native startup campaign

`startup_campaign.py prepare` freezes a new prospective cohort using a qualified
protocol-v5 observer. This campaign adds admission around fresh raw observations;
the standalone diagnostic, past pilots, and their `--qualify` rejection remain
unchanged. No historical observation can be substituted for a declared launch.

Each scenario has six blocks, 40 measured launches per app per block, and two
separate warmups before each app's block: 504 isolated launches, of which 480
enter the distributions. A fresh recorded random seed selects the initial app;
subsequent blocks alternate, so each app starts three blocks. Each sample pair
has an identical fresh nonce and generated viewport. Every failed launch stops
the cohort, including warmups. There is no successful-sample replacement.

The workload is warm-files startup through a normal app, `/bin/zsh -l`, and the
same generated Python viewport fixture. Target grid is explicit before launch
and identical for both apps within a scenario. Configuration, sanitized launch
environment, source archive, entire app bundles, native observer qualification,
runtime, display, font, hardware, power and native conditions are bound to the
cohort. There is no helper activation, corrective resize, clipboard operation,
or app feature override beyond the existing public comparison profiles.

The native supervisor requires 300 seconds on both session and hardware idle
clocks. It watches session activity during execution, checks conditions for each
launch, and requires the child observer, app and worker to be gone before the
next launch. During the episode, only poll this supervisor; perform no other
builds, analysis, UI work or tool actions. Failed and incomplete cohorts retain
their original files and cannot enter the gate.

`startup_parity_evidence.py` independently checks the frozen schedule, every raw
pixel proof and native clock, exact sole target generation and complete initial/target/signal trace, public launch configuration,
unique process lifetimes and defaults domains, sequential ownership, and cleanup.
Warmup evidence is validated but excluded from measured values. The existing
`parity_gate.py` uses its unchanged input minimum of 40 samples, nearest-rank
block p50/p95, six paired block ratios, and 95% bootstrap interval with an upper
bound of 1.0. This does not change `parity-policy.json` or any other metric.

The v5 generation policy requires exactly one generated target viewport. The
true initial PTY grid is preserved even when different. The first observed target
size starts that sole paint; any later observed size change, second generation,
partial write, missing signal/observation counter or failed cleanup rejects the
launch. No waiting-state JSON is written before paint. Delivered no-op SIGWINCH
notifications can occur before, during or after writing only with their complete
chronology and unchanged target geometry proved through cleanup. The full launch
clock includes target arrival and is never reset. Pixel, native TTY, stability,
foreground and ownership checks remain unchanged.

A v4 worker may have painted its transient grid and repainted the target. Such
records cannot be converted or selectively retained: all v5 scenarios require
fresh complete cohorts. No native/source compatibility exception is accepted by
the v5 contract. Existing v4 raw evidence, source receipts and the historical gate
remain preserved; replay them with their trusted reader at Git commit `42a88d8`,
not by executing arbitrary source from an evidence directory. The last v4 score
was 117 pass, 2 behind, 17 inconclusive and 4 unmeasured. Its four AC startup
metrics (two pass and two inconclusive) do not establish v5 startup coverage.

The endpoint remains the first complete **delivered** ScreenCaptureKit frame.
The one-second content check and 200 ms geometry settling guard corroborate that
first frame; their completion time never becomes the startup metric. Native
display timestamps are used, with callback backlog retained. The cohort does
not claim physical scanout timing or coverage of frames the platform never
delivered. The existing pilot measured 60–71 ms first-grid decode and callback
backlog up to 163 ms while rediscovering Ghostty's opening transform.

Run the generated campaign tests without launching apps:

```sh
python3 -B -m unittest discover -s Tests -p test_startup_campaign.py
```

Preparation and execution are separate explicit CLI actions. Always choose a
fresh output path. `run` spawns the frozen supervisor and writes its reaping
receipt; a completed cohort is then read by `parity_gate.py --evidence PATH`.
Any later source changes require a fresh freeze or a preserved trusted reader,
not bypassing source checks. Final performance and native correctness claims
still require the same exact delivered CMDY executable across all 140 metrics.

Historical v4 schema-repair and resize-routing exceptions are retained in Git
history. They cannot authorize protocol-v5 collection or bypass new source pins.
