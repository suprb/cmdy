# Native IME checks with explicit focus transfer

`korean_ime_focus.py` checks the normal CMDY executable against an owned native
text view, using real Korean and Japanese input services and tagged HID events.
After each input-source selection, an owned temporary app takes focus and returns
it to the exact target executable. No warm-up key is discarded. The existing
commit, cancellation, preedit, dead-key, and control-byte assertions remain.

This setup addresses the observed macOS source-selection readiness failure.
It does not qualify source switching without the focus transfer. Historical
`korean_ime.py` and its receipts remain unchanged. The controlled reference
comparison and four full baseline/candidate runs are recorded in
`2026-09-19-competitive-phase.md` in the private performance
notes.

Later September 27 diagnostics reproduce intermittent Korean failures despite
the focus transfer and pre-key source/current-context reads. This procedure is
not an unconditional fix or qualification of the current executable. The
four-mode comparison (`results/2026-09-27-ime-api-matrix/` in the private performance notes)
retains the failures and passes; no getter workaround was promoted. The reference
selects its source inside its process, while CMDY uses the external selector and
focus transfer. That fixture difference remains an unresolved hypothesis.

Build the fixtures into a new directory:

```sh
python3 -B Tests/CMDYFinishing/build_ime_focus_tools.py --output .build/ime-focus-tools-01
```

This command compiles and verifies signatures; it does not launch GUI apps or
select input sources. Its `build.json` records the executable arguments and hashes.
Run the controller from the repository, not the archived source copy in the build
directory. Supply `--app`, `--window`, `--regression-input`, and a new `--output`,
plus `--helper`, `--reference-executable`, and `--focus-bridge` from that receipt.

Native execution belongs inside the campaign supervisor: require 300 seconds
of both hardware and session idle, fixed power/thermal conditions, exact binary
pins, and a running event-origin monitor supplying `CMDY_NATIVE_EVENT_TAG`.
Only poll that supervisor while it waits or runs. Keep every outcome, verify
fresh input-source restoration, and audit all recorded app, worker, bridge,
reference, and controller PIDs after completion. These checks add no performance
gate passes; final qualification must identify the delivered CMDY executable.
