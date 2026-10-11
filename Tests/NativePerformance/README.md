# Normal native app performance inputs

`prepare.py` freezes a completed, qualified normal macOS app for a later
comparison. It does not use the old partial-core experiment's rewritten Swift
graph, `libcmdy_zig_rows.a`, hardcoded symbol counts, or inherited admission.
Those experiments and their receipts remain unchanged.

Preparation copies the exact qualified source archive, completed app link
objects and SwiftPM description, resource bundles, immutable native archive,
headers, compiler receipt, and existing headless correctness evidence. It checks
the app's native implementation symbols, links and runs a small C identity probe
against the actual compiled bridge, and verifies the source/archive/key binding.
The probe only prints the native source key and build mode.

The resulting lean app and its component helper both come from the qualified
raw executable. They receive local ad-hoc signatures. Every file-backed Mach-O
code and data section must remain identical after signing. The resource template
supplies the explicitly enumerated documentation and icon; its two resource
bundles must match the completed build exactly. Its executable and helper are
never reused.

The five existing headless app suites are reused only when their logs, app hash,
source archive, and native archive match. Preparation does not launch the app or
helper, activate a window, read the clipboard, install anything, or run timed
benchmarks. Bundle resource discovery is checked statically; preparation does
not claim a new runtime launch test. The native library and normal app's runtime
correctness evidence comes from the supplied qualification.

## Prepare an isolated baseline

Use absolute paths to completed build inputs and an existing lean resource
template. The output must not exist and must be outside the repository:

```sh
python3 Tests/NativePerformance/prepare.py prepare \
  --build-products /absolute/completed-build/arm64-apple-macosx/release \
  --artifact /absolute/Core/.zig-build/artifacts/NATIVE_SOURCE_KEY \
  --qualification /absolute/qualified-results/qualification.json \
  --resource-template /absolute/resource-template/cmdy.app \
  --packaging-source /absolute/packaging-source \
  --output /private/tmp/cmdy-native-candidate-01
```

`--packaging-source` defaults to the repository and supplies `package.sh`,
`Cmdy.entitlements`, `VERSION`, and the product identity/resource policy scripts.
It can point to a frozen copy when normal packaging is being changed in parallel.
`--build-products` can also be a relocated copy: the recorded original object
paths are mapped into this directory, and the object inventory must be complete.

The current qualification adapter consumes the normal app port receipt layout
(`schedule-active-source-manifest-final-01.json`, the final source archive, and
`app-integration-final-01/completion.json`). It supports the qualified arm64,
Zig 0.15.2, ReleaseFast native build and lean app. Browser templates fail explicitly.
Paste scripting is enabled only when the qualified source archive binds all of
`App/CmdyPasteAutomation.swift`, `App/CmdyPasteAutomationBridge.swift`, and
`App/Resources/Cmdy.sdef`. The frozen dictionary supplies the packaged resource;
the runner then adds `NSAppleScriptEnabled` and `OSAScriptingDefinition`. An
existing template dictionary must match those exact bytes. Old qualifications
without that complete implementation remain scripting disabled. A new app cannot
inherit the old baseline's binary or correctness claims.

New edits in the working tree do not change an existing baseline's source. The
runner extracts `final/` source entries from the qualification's hash-bound
archive and records differences in previously inventoried working-tree files.
That difference list is informational, not a complete current-tree review. Source
review remains explicitly `unreviewed`; this tool grants no review approval.

## Verify and use the prepared inputs

```sh
python3 Tests/NativePerformance/prepare.py verify \
  /private/tmp/cmdy-native-candidate-01
python3 Tests/NativePerformance/test_prepare.py
```

`candidate.json` identifies the isolated bundle and executable, raw and signed
hashes, helper, native key/archive, source inventory, correctness evidence and
every frozen file. Verification rejects missing, added or changed files,
signature failures, modified source/native identities, changed code sections,
and changes to the existing locked `Tests/parity-policy.json`.

The `comparison_inputs` fields supply the app and tooling paths for the existing
terminal benchmark runners. Current top-level `Tests` runner dependencies and
the locked policy are frozen under `tooling/Tests`. This does not supply comparator
evidence, choose new thresholds, copy previous samples, or claim admission.
Actual paired measurements still require the existing harnesses, their complete
comparison inputs, and a quiet machine after builds and profiling have stopped.

Keep measurement output outside the candidate directory so verification remains
valid. Failed preparation directories retain partial inputs and never receive a
successful `candidate.json`; use a new output path after fixing the cause.

## Profile the current native engine without opening windows

`prepare_engine_probe.py` builds a separate Swift PTY host against a frozen Core
package and the exact qualified native archive. It preserves the normal serial
PTY reader and supports a probe-specific 1 ms immutable snapshot timer. That
timer does not model the normal app's `SnapshotPublicationScheduler`, rendering,
or first-visible endpoint. The explicit
corpus directory must contain the eight retained 3 MB `.bin` workloads.

```sh
python3 Tests/NativePerformance/prepare_engine_probe.py \
  --corpus /absolute/retained-core-corpora \
  --output /private/tmp/cmdy-engine-probe-01
python3 Tests/NativePerformance/profile_engine.py \
  --probe /private/tmp/cmdy-engine-probe-01 \
  --workloads unicode source styled --seconds 5 \
  --output /private/tmp/cmdy-engine-profiles-01
```

The driver verifies a complete stream checksum in a separate validation drain,
then checks byte counts, changing DSR replies, grid, cursor, notifications and
PTY cleanup throughout profiling. The source, archive, payload and executable
hashes are checked before and after each workload. Every sample record is
explicitly diagnostic and nonqualifying. `/usr/bin/sample` perturbs execution;
there is no rendering, first-visible measurement or Ghostty comparison here.
Profile durations cannot enter the parity gate.

For continuous ASCII decomposition, run the same frozen probe with
`--workloads continuous --snapshots on` and `--workloads continuous --snapshots off`
in separate new output directories, only after other agents/builds stop. `on`
remains the default, including direct driver invocations that omit the optional
last argument. The runner binds the selected mode to the driver hello and every
drain's counters. Off mode requires zero snapshot captures. On mode with no
actual captures cannot establish snapshot cost. Use sample stacks to distinguish
PTY/read callbacks, terminal feed and immutable snapshot publication; changes in
whole-probe drain duration are diagnostic and cannot prove a normal-app cause.
