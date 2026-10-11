# App model regressions

Run from the repository root:

```sh
python3 Tests/test-app-model.py --configuration release
```

`./test.sh` invokes the same runner using `CMDY_TEST_CONFIGURATION` (debug by
default). `--keep` retains successful staged sources, commands and logs; failed
runs always retain their temporary workspace and print its path.

The runner copies the current `TerminalModel`, snapshot mailbox/scheduler and
performance-trace sources into a temporary SwiftPM target, then appends the
already-qualified same-file test seams there. Four unchanged XCTest files run
28 cases: nine mailbox, ten scheduler, six model publication and three model
scheduler cases. They cover merged damage, snapshot lifetime, geometry and
observer replacement, callback reentry, cancellation, first-response credit,
clock evaluation and bounded scheduling. No live App source is edited, no
app executable is imported, and no test starts a PTY or shell.

A separate ordinary Swift executable compiles the current
`InitialShellLaunches.swift` with the unchanged seven-case test. It preserves
eager ordering, both no-shell modes, layout-before-grid, deduplication,
idempotence/reentry and ownership loss. Its preconditions remain enabled;
the runner uses `swiftc -parse-as-library` with `-O` for release and `-Onone`
for debug. Neither configuration uses unchecked optimization.

The root Package.swift and shipped App target are unchanged. Test-only seams
and XCTest remain outside App/, so `cmdy --selftest` keeps its existing check
count. SwiftPM dependency/build caching is isolated under
`.build/app-model-tests`; the dependencies are the current local Core and Kit.
There are no downloaded test dependencies or performance measurements.
