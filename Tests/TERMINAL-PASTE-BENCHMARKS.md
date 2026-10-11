# Paste insertion through the public scripting interface

The clipboard-free paste adapter measures a 65,536-byte Unicode insertion
through each app's public `input text` command, followed by a complete generated
response viewport. Its metric is
`public-apple-event-paste-insertion-to-first-complete-response-viewport`, for
`input/paste`. It does not measure the Command-V shortcut or clipboard retrieval.

**Native comparison remains unqualified.** The observer compiles and its
generated pixel, descriptor and permission tests run without contacting either
terminal app. Owned PTY tests verify the complete payload and bracket framing.
Those checks do not establish real Apple Event delivery, display calibration or
CMDY/Ghostty performance. No actual Apple Events, permission queries, native
capture sessions or foreground activation have run for this adapter's initial
qualification. A fresh paired native pilot is required before comparison data
can be used, and pilot samples never enter the statistical gate.

The subsequent native pilot on September 11 reached CMDY's observer but stopped
at the existing-authorization preflight with status `-1744`. It sent no Apple
Event, started no capture and recorded zero samples; Ghostty was not launched.
Owned processes exited and the original foreground app was restored. A prior
attempt exposed a Python alias/pinned-path mismatch before observer launch. That
generator bug and a separately found undefined audit-path variable now have
focused regression tests. Both failed attempts remain preserved. See
the native preparation report (`2026-09-11-native-benchmark-preparation.md` in the private performance notes).

## Public application behavior

The normal packaged CMDY app exposes existing terminal panes by stable UUID:

```applescript
tell application "cmdy"
    set paneID to id of terminal 1
    input text "hello" to terminal id paneID
end tell
```

This is a product interface, also documented in [AUTOMATION.md](../docs/AUTOMATION.md).
It follows the normal pane paste policy, cancels composition for accepted input,
and uses the terminal's actual bracketed-paste mode. It does not add Return or
activate the pane. A closed or rejected target fails instead of redirecting text
to the currently focused terminal. The app and benchmark never need the system
clipboard for this command.

The benchmark freezes and validates both installed scripting dictionaries. Both
must declare the same `Ghst`/`InTx` event, `GItT` target parameter and `Gtrm`
terminal object. The recorder addresses the exact owned application PID, queries
exactly one terminal ID, and encodes a unique-ID object specifier. There is no
bundle-ID lookup, arbitrary focused-pane fallback or synthetic keyboard path.

Before either the query or insertion, the recorder checks existing Automation
authorization with `AEDeterminePermissionToAutomateTarget` and
`askUserIfNeeded=false`. Missing authorization rejects the run; it does not open
a permission dialog. Event dispatch uses the same
`waitForReply | neverInteract | dontRecord` options and timeouts for both apps.
The generated tests inject permission and send implementations; they do not
query or change real macOS permissions.

## Fixed input and complete visible response

`paste_protocol.py` fixes a 120×36 native terminal grid, two explicit warmups,
forty measured insertions per process and six counterbalanced process pairs.
Each UTF-8 payload contains a fresh 128-bit run token, sequence number and the
same repeated ASCII, Greek, CJK and emoji text, with ASCII padding to exactly
65,536 bytes. Python and Swift generate these bytes independently.

Before timing, the worker disables bracketed paste and requires one exact,
unframed token probe. It then enables bracketed paste. Every subsequent payload
must arrive between exactly `ESC[200~` and `ESC[201~`. The receiver checks every
byte, rejecting wrong prefixes, extra data, missing framing and partial input.
A successful API reply cannot substitute for this PTY receipt.

Only after complete input validation does the worker paint the response. It
uses explicit row addressing and solid background-colored spaces across every
cell. Each row includes the run token, response row ordinal, checksum, repeated
color code and distinct left and right sentinels. There is no unobserved text
tail, glyph-rendering claim, alternate-screen switch or synchronized-output
shortcut in the response.

Calibration discovers the entire generated viewport in an untimed frame. The
matcher samples three interior horizontal positions in each cell over every
vertical pixel of the cell. All 4,320 cells must agree with the frozen geometry
and palette. Retained sentinel spans and row discovery let the independent
validator reconstruct the full 120-column pitch, samples and all 36 contiguous
row bands; a self-declared calibration hash cannot replace that proof.
The first match retains actual pixel-derived class bytes; the
independent validator checks those bytes against its own generator. A recorded
success flag or producer-supplied expected hash is insufficient.

## Timing and validation

The start is the native Mach clock before arming observation and dispatching
the prebuilt Apple Event. The observer's brief arming lock and actual command
dispatch are included. Descriptor construction, permission checks, terminal lookup,
geometry preparation and worker arming are outside the interval. The worker's
input, paint and write-return clocks and the event
reply clock are diagnostic evidence only.

The endpoint is the earliest complete matching response viewport's
`SCStreamFrameInfo.displayTime` after the dispatch start. Callback time, API
return, receipt acknowledgement and first partial response are not endpoints.
The native observer retains frame status and matching evidence so an independent
reader can reconstruct the first match and clock conversion. It must not replace
an early matching frame with a later convenient frame.

A 250 ms post-match guard rejects subsequent incorrect, blank, suspended or
otherwise invalid capture frames. Idle status is permitted for unchanged
content and cannot invent another complete frame. Guard time is validation
overhead; it is not added to the insertion latency. Ownership, native bounds,
display mode, actual PTY dimensions and repeated kernel ancestry bind the
generated worker to the exact measured application throughout observation.

Runs pin exact app binary/plist identities and retain the observer binary,
source manifest, SDEFs, launch arguments, isolated config files, runtime identity,
font, display, power and thermal state. The complete fixed run must pass; an individual failed event
cannot be dropped or retried inside a passing block. Failure and owned-process
cleanup receipts remain available.

## Build, validate and run

The following build runs generated native tests and compiles the observer. It
does not execute the observer or contact a terminal application:

```sh
python3 -B Tests/paste_build.py --output /private/tmp/cmdy-paste-headless-NEW
python3 -B -m unittest discover -s Tests -p 'test_paste_*.py' -v
```

Output directories must be new. The native generated suite passes 281 checks;
see the source-bound build receipt for the count belonging to any later
revision. The Python suites separately cover command routing, exact protocol
bytes, owned PTY cleanup and retained-evidence validation.

`paste_bench.py` is the separate native entry point. It requires an
`--observer-build` directory, `--window-helper`, both `--cmdy-bin` and
`--ghostty-bin` paths with their `--cmdy-sha256` and `--ghostty-sha256` pins,
`--cmdy-source-manifest`, `--cmdy-source-root`, a native `--display-id` and a new
`--output` directory. The declared `--profile` is `matched` or `cmdy-defaults`;
`--power-source` must match the actual AC or battery state. Its native runs need
a quiet machine and exclusive use of the measured windows.

Every invocation first runs a fresh, unpooled paired transport and full-frame
pilot. It independently validates a retained pilot checkpoint before launching
the first measured process. `--pilot-only` stops there and cannot produce qualifying parity samples.
After a successful pilot, the full run uses all six counterbalanced pairs,
retains warmups explicitly and validates all forty samples in each process.
Source, binary, configuration or environmental drift rejects the comparison.
The unchanged parity policy determines the statistical result; completing this
adapter or its synthetic tests supplies no performance admission by itself.
