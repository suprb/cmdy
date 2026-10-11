# Public generated-history file export

This is an untimed, clipboard-free transport pilot. It does not admit resize,
memory, startup, input, or throughput results. The explicit post-sample policy uses public
`write_scrollback_file:paste` for primary history and `write_screen_file:paste`
for the alternate screen, identically in both applications. It posts one
Ctrl-Shift-Enter key-down/key-up pair (physical key code 36, modifier flags
0x60000) to the exact owned PID. Enter uses CMDY's layout-independent special
key mapping; shifted digit 2 would instead depend on the event's shifted text.
The export helper uses no Apple Events,
selection, Copy action, app launch, app activation, or clipboard API.

`history_export_build.py --output NEW_DIRECTORY` compiles the helper and records
the exact Swift inputs, including the shared shortcut constants. It never executes the helper, including its
read-only `conditions` mode. `PUBLIC_TOOLING` in that module lists every runtime
dependency that a downstream recorder must freeze. Compile-only qualification
does not establish an event grant, native path transport, or visible pixels.
The headless suite also copies only that inventory into a separate directory,
imports every Python runtime module under `python -I`, runs the inert default
CLI, and completes both generated resize and memory-drain private-PTY paths.
The checkout is absent from the isolated import path, so a missing transitive
runtime dependency cannot be hidden by the full working `Tests` directory.

The caller owns both disposable app lifetimes, the foreground interval, matched
Menlo 14 profile, fixed 120×36 real PTY grid, launch/config/binary receipts,
preexisting permission grants, app/worker reaping, and foreground restoration.
Use the final source-bound CMDY package and the pinned installed Ghostty public
binary. Do not borrow an existing terminal session. Native checks fail if the
owned app is not foreground, its one on-screen window is off the pinned
display, its binary/lifetime changes, or its worker's repeated kernel ancestry,
controlling PTY device, foreground group, or real grid cannot be proved.

The explicit `generated-file-transport-v2` proof establishes ownership for an
untimed file action. It reports `visualVisibilityVerified:false` and has no
`occluded` field. Exact full file content does not prove composed visible
pixels. This scope is selected only by the new history pilot; existing memory
callers retain their default schema-1 strict proof and accounting contracts.
There is no OS-process, cursor-level or NotificationCenter exception. Schema-1
proofs and all `observe`, resize and startup visual readers keep their strict
overlap checks and reject file-scope proofs, even with a forged `occluded:false`.

Occlusion failures retain geometry-only `windowGeometry` evidence from the
query that rejected admission: ordered window IDs, owner PIDs, layers, bounds
and blocker indices. The full outer-window overlap guard remains in force;
titles, application names and unrelated pixels are excluded. The wrapper's
cleanup reader accepts an already absent generated defaults suite only when
an empty exported plist agrees with the exact owned-domain delete diagnostic.

Create separate new mode-0700 directories for app temporary exports and the
short Unix control socket. Override the app's `TMPDIR` with the exact export
directory before launch, including a trailing slash. Keep the socket outside
that directory. `history_export_binding.install_binding` creates CMDY's normal
version-1 `keybindings.json` in the selected `CMDY_CONFIG_DIR`; its preference
config does not import `keybind` lines. Ghostty receives exactly
`keybind = ctrl+shift+enter=write_scrollback_file:paste` in its isolated public
config. Both bind the same physical shortcut to the same public action.
The headless dispatch fixture decodes the generated CMDY document with the
actual public store and executes the production imported event-resolution and
action-selection methods. Preserve the exact store/config bytes and their
joined launch receipt. The controller does not introspect live app mappings.

The native `post-key` receipt reports `intendedAction` and
`actionInvocationVerified:false`: posting events does not acknowledge an app
action. Only the subsequent complete generated-file transfer establishes this
pilot's transport result. Rejected input is never retained or labeled as an
observed filename. In particular, a prefix mismatch does not prove an export
occurred, and cannot establish any unknown external file's cleanup.

On lexical rejection, the worker may also retain `rejected-input-shape.json`:
bounded byte counts, predefined character classes and framing flags, and a
boolean for the exact private-directory prefix. It contains no input bytes,
input hash or filename, opens no file, and never acknowledges the action.
The strict parser receives the original unmodified bytes; this diagnostic
neither strips framing nor admits additional leaf names or path roots.
The preexisting cleanup field `inputBytesRetained:0` concerns unrecognized or
rejected input. A successful `export.json` separately retains the accepted
`pathReceiptASCII` after the confined file and generated content are verified.

A propagated `owned-directory-is-not-private` error may retain one fixed
`directory-rejection.json`. It records only the failed check's phase, root or
ancestor ordinal (0–3), observed type class, permission bits, UID-match and
same-device booleans, plus worker PID, nonce and arm/failure ticks. These values
come from the stat result used by that check. No path, name, inode, actual UID
or device number, input, hash or file contents enter this diagnostic. Root
named revalidation forwards the current phase. The original ValueError object,
type and message survive diagnostic construction or write failure; suppressed
cleanup failures cannot overwrite a primary error. Lexical, identity/newness
and other failures do not produce this record. It is nonqualifying and changes
neither directory admission nor the successful file proof or visual scopes.

Only a `missing-generated-row` rejection may retain a fixed
`missing-generated-row.json`. That guard is reached when a complete matched
prefix exhausts the physical content lines before all expected logical rows
have matched. The nonqualifying record contains only the expected row count,
matched prefix count, zero-based next expected row index, physical content
line count/cursor after outer padding removal, leading/trailing blank counts,
raw byte count, and the owned worker PID/nonce/arm/failure ticks. Strict field,
type and range checks exclude text, paths, input bytes and hashes. Corruption,
unexpected framing, empty-file size failures and other errors do not receive
this diagnostic. A diagnostic construction or write failure preserves the
original ValueError. Partial history remains rejected under the unchanged
schema-2 intake and cleanup rules; counts alone establish no export success,
screen inclusion, retained-memory metric or visible-frame proof.

The paired coordinator controls application launch and shell startup.

The untimed paired pilot explicitly selects a child-only umask of `0077` for
both apps through `subprocess.Popen(umask=0o077)`. Its plan, each app's
`launch.json`, and each `public-history-binding.json` record `childUmask:63`;
missing or unequal values reject the pair. The parent process never changes
its umask, and generic sessions or memory sessions that omit this option keep
their existing launch behavior. A fresh qualification binds the three Python
launch sources as well as the unchanged native helper inputs.

This changes the owned launch condition, not file admission. The registered
root and all descendants still pass the original schema-2 private-directory
checks; the exported leaf remains a new regular single-link `0600` file with
the complete generated contents. Ordinary `0755` mkdir and `0666` file creation
under an inherited `0077` mask produce `0700` and `0600`. Headless Python-child
tests prove that inheritance only; the public native pilot must still establish
whether each app preserves it and produces an accepted schema-2 export. An app
that explicitly resets its mask or changes permissions can still fail.

The controlled shell startup command is:

```text
python3 -B history_export_worker.py --output NEW_FIXTURE_DIRECTORY \
  --temporary-directory REGISTERED_TMPDIR --socket SHORT_PRIVATE_SOCKET \
  --capability 32_LOWERCASE_HEX --nonce 32_LOWERCASE_HEX --case resize
```

The worker owns the only TTY reader. Wait for its `ready.json`, fit the native
120×36 grid, then use
`history_export_controller.control(ready, capability, "prepare")`. Resize keeps
the original 1,000 distinct 145-column logical records, each followed by CRLF:
147,000 history bytes. It then writes the existing 36 separators and unchanged
version-2 full generated-cell viewport at sequence zero. It does not resize the
window or add history erasure. Two applications in one pilot pair must share
the exact nonce and expected generated bytes.

For memory, use `--case primary-1000`, `primary-5000`, or
`alternate-continuous`, plus `--payload EXACT_GENERATED_PAYLOAD`. The nonce's
first 16 hex characters are the existing memory payload marker. Only exact
existing 76-column rows and, for alternate mode, the unchanged 3,000,000-byte
prior burst are accepted. Call `control(ready, capability, "drain",
sequence=ordinal, timeout=seconds)` once. It invokes the unchanged shared DSR
drain on the same fd0 and event loop, without creating another reader or actor.
The response includes the original drain fields at top level. Ready metadata
includes payload count/hash, raw TTY flags, ONLCR/OPOST state, PID, PTY, and
monotonic startup/readiness clocks. The ordinary `prepare` operation is disabled
when a memory payload is supplied.

Legacy callers arm after preparation or drain. With the explicit policy below,
`arm` requires the completed verification phase first. It recursively inventories the exact private
temporary directory and starts one fixed three-second path-receipt interval. It collects
at most 4,096 raw PTY bytes across all reads, including fragmented delivery, and
waits through the full interval. The accepted framing is preregistered as one
unquoted absolute ASCII path with no delimiter. The bounded descendant form
allows one through four relative components below the same registered root;
each component starts with an ASCII letter or digit and contains at most 255
ASCII letters, digits, dots, underscores or hyphens. Quotes, bracketed paste
markers, CR/LF, empty components, traversal, extra input, and paths outside
the exact directory fail; the worker never executes the received text. Native
piloting must establish whether both public actions provide this framing and
respect TMPDIR. A mismatch is evidence of a failed pilot, not authority to try
arbitrary paths or silently add a quoting fallback.


The new `post-sample-public-history-v1` policy is an explicit, separately
versioned verification phase. It leaves the original measured payload and DSR
footer unchanged. After the original drain, an untimed pilot declares the
exact drain completion boundary. A future memory integration must instead
bind all six original samples, including the final post-output five-second
sample, before this phase starts. The independent ordering validator checks
those labels, offsets and monotonic intervals, but cannot grant memory admission.
Existing memory sessions and the full memory reader retain their original
visual scope and reject this new file-only result.

For primary 1,000 and 5,000-row cases, the worker sends only the fixed 81 control
bytes `ESC[36;1H`, exactly 35 CRLF pairs, and `ESC[6n`. It requires the exact
`ESC[36;1R` reply through the existing sole PTY reader. Explicit bottom-row,
column-one positioning makes this independent of the original DSR footer's
cursor position. The fixed scroll moves the last 35 generated rows into history;
it generates no numbered text. The existing maximum 37 outer blank rows and
complete row-by-row byte verification remain unchanged. That expected native
export behavior still requires a fresh paired pilot.

For `alternate-continuous`, verification writes zero bytes, neither scrolls nor
switches screens, and selects `write_screen_file:paste`. All 35 generated rows
must match, with no retained predecessor A row. The same physical shortcut maps
to CMDY's normal `writeScreenPaste` store entry and Ghostty's public screen-file
paste binding. Headless imported-store checks exercise the actual production
mapping and action resolution; no action is executed or acknowledged there.

The worker accepts exactly one original drain, one `verify-history`, one arm
and one finish, with read-only status requests allowed between them. The phase
record binds fixed control bytes/hash, exact reply, worker/nonce, original drain,
sample boundary, unchanged 120×36 grid and both native and monotonic clocks.
Missing, duplicated, reordered or overlapping phases fail. Transfer document
version 3 and history result version 2 carry these joins explicitly; the strict
file-intake proof remains version 2. Historical transfer versions 1 and 2 cannot
borrow new phase records. `actionInvocationVerified` stays false, and the new
records establish no composed pixels or performance result.

The pre-arm inventory visits every directory or fails entirely. It allows at
most 128 total entries and three descendant directory levels, requires private
same-UID directories on the registered root's device, refuses symlinks and
special entries, and checks that each complete listing remained stable. It
records entry metadata and parent identities without directory entry names or
file contents. An existing nested file remains old even if it is later renamed
under a newly created ancestor. An incomplete or flat inventory cannot authorize
a new descendant intake.

The file reader opens every directory component without following symlinks,
retains the root and each relative ancestor descriptor, and anchors the leaf
open to its parent descriptor. It requires a new
device/inode absent from the complete pre-action inventory, current UID, a regular file,
one link, mode 0600, and at most 4 MiB. Descriptor and named-entry identity,
size, mode, ownership, mtime, and ctime must remain exact through open/read and
cleanup. At open, after read and before unlink, each named ancestor must still
match its descriptor, including the canonical registered root name. Ancestor
metadata must remain stable during intake; child creation before intake may
legitimately change directory times after the pre-arm inventory. A changed
file found between stat and open never authorizes failure cleanup.

File proof version 2 carries the recursive inventory graph and all named and
descriptor ancestor checks for independent replay, including parent/path joins
and the leaf's final unlink identity. Historical version-1 flat file proofs
remain valid only for direct-child paths and their original flat inventories;
they cannot borrow version 2 to admit descendants. This file-proof version is
separate from the native ownership/visibility scope above and does not change
any visual reader or performance requirement.

Only after all expected generated rows validate does it retain a
private `generated-export.bin` and record its raw bytes/hash. The source entry
is unlinked only if it still denotes that same unchanged owned inode. Rejected
input/content is never printed, hashed, or copied to an evidence artifact.
Unexpected or changed entries are left for the caller's owned-directory cleanup;
their existence never turns a rejected proof into a pass.

Normalization is limited to CRLF→LF, trailing ASCII spaces, bounded outer empty
rows, and wrap breaks exactly at the actual 120-column boundary. Logical-line
and physical-wrap exports are accepted. Missing, duplicate, reordered, pruned,
corrupted, arbitrarily split, interior-blank, or unrecognized rows fail. The
validator independently reconstructs the complete generated row sequence; a
producer's count/hash alone is not proof of retention. These fixtures contain
ASCII records and generated background cells; they do not claim glyph parity.

The native helper accepts:

```text
history-export-native conditions
history-export-native inspect --spec OWNED_SPEC.json
history-export-native post-key --spec PINNED_SPEC.json
history-export-native observe --spec PINNED_SPEC.json
```

Specs contain `pid`, `workerPID`, `ttyPath`, `executableSHA256`, `nonce`,
`windowID`, and `displayID`. `inspect` returns `owner.identity` and
`owner.workerIdentity`; copy these into `expectedApp` and `expectedWorker`
before `post-key` or subsequent observations. `post-key` requires those pinned
lifetimes. Its receipt contains both repeated ownership proofs, the exact
public action, event count/keycode, and native before/between/after ticks.
`conditions` contains only the requested ProcessInfo values and a converted
Mach monotonic clock. Missing grants fail without requesting permission.
The history-only pilot additionally sets
`proofScope:"generated-file-transport-v2"` in every native spec and uses transfer
schema 2. Missing or unknown scope cannot silently downgrade that proof, and
`observe` rejects the file scope before any capture-permission query. Schema 2
accepts the generated primary/alternate file cases; it cannot authorize the
resize history/viewport pair. Older frozen schema-1 plans remain separate.

Resize's `observe` mode starts a new ScreenCaptureKit stream each time. It
requires a new complete WindowServer display clock after capture start and the
optional `afterTicks`; an idle/cached frame or a host completion timestamp is
not a substitute. It discovers the version-2 generated viewport using the
existing frozen matcher, retains all 4,320 actual pixel-derived cell classes,
and stops the stream before returning. The Python validator independently
checks that stream, its row identity/CRC and right-edge/interior classes, exact
discovery preimage, owned geometry, statuses, and before/after ordering.
Only generated classes and bounded metadata are retained, not full display
images. Fresh-frame availability on a static native viewport remains a pilot
precondition; timeout does not permit reusing the earlier frame.

`history_export_controller.collect_export(native, build_json, request,
new_output)` drives one already prepared resize worker through before-observe,
arm, public key, complete file receipt, after-observe, and worker finish. A
request contains `schemaVersion:1`, `terminal` (`cmdy` or `ghostty`), `case`,
`nonce`, `workerReady`, `workerCapability`, `fixtureDirectory`, and `nativeSpec`.
The CLI accepts the request with `--record`, `--native`, `--native-build`, and
`--output`. No app launch, configuration change, permission request, or
activation is implicit. Memory integrations use `viewport=False` and may use
`finish_worker=False` to retain control of their already owned worker; those
results explicitly make no pixel/viewport claim.

Independent readers use `history_export_evidence.validate_transfer(document,
raw_bytes)`. A document contains `schemaVersion`, `terminal`, `expectation`,
`nativeSpec`, `workerReady`, the inner `workerArm`, native `action`, worker
`export`, `beforeOwner`, and `afterOwner`. The function joins full raw file
validation with repeated kernel ancestry, PID/lifetime/window/TTY identity,
private file UID, exact public event and clock/chunk coverage. Readers must
also bind exact offered payload/config/source/helper bytes, worker final
cleanup, caller-owned app/worker reaping, and their own metric-specific evidence.
`validate_file_proof` is the narrower reusable file-only checker.

`--validate-pair CMDY_RUN GHOSTTY_RUN` independently rechecks the retained resize
documents, generated files, both complete viewport observations, same workload,
and each worker's exact termios/file-flag/socket cleanup. Its result remains an
untimed functional pilot. A downstream resize revision still requires fresh
native calibration and all unchanged 42 transitions, including two warmups and
40 measured events, with its original first-frame endpoint and strict paired
gate. Memory still requires complete joined process-accounting samples. Old
clipboard-backed receipts and failed prototypes remain separate evidence.

`NativePerformance/compare_history.py` prepares a `primary-1000`,
`primary-5000`, or `alternate-continuous` transport pair (`--case`, default
`primary-1000`) for a qualified normal CMDY candidate. It reuses
`PublicHistorySession`, the qualified export/window helpers, and the same outer
supervisor as `compare_memory.py`. Preparation freezes every runtime source,
helper build/qualification receipt, interpreter identity, app/Info.plist hash,
and one private original generated payload. Both fresh app lifetimes receive
those same case-specific rows and the same public shortcut. Their control capabilities
and nonce suffixes are separate; the shared 16-character marker determines the
identical generated content.

The explicit `run --output PREPARED_DIRECTORY` launches CMDY then Ghostty, fits
the real 120×36 grid using the existing public window setup, performs one
generated drain, and validates the public file export and complete cleanup.
It invokes only `inspect` and `post-key` export-helper modes. It does not capture
the screen or run a memory sampler. Existing readiness/drain clocks are retained
as raw lifecycle evidence; no timings are summarized or admitted. An optional
untimed finalizer in the shared supervisor bypasses the timing gate and requires
zero measured samples and explicit false admission/goal flags. Normal output
and memory comparisons retain their original gate behavior.

The revised outer supervisor requires at least 300 seconds on both the
combined-session AnyInput clock and the IOHID hardware clock before launch.
During the pair it uses the session clock to detect resumed input and retains
both clocks. Qualification must establish that this session clock excludes the
owned injected keys; the older IOHID-only preparations remain separate failed
or unrun artifacts. No missing grant triggers a permission prompt. The first
app setup owns activation; subsequent verification checks remain strict, and
foreground is restored only if the session activity guard remained uninterrupted.

After success or failure, `audit-cleanup --output PREPARED_DIRECTORY` checks the
recorded app/worker PIDs, helper reaping, exact three private directory removals,
and only the generated CMDY defaults domain. Incomplete cleanup receipts,
remaining PIDs/paths, a changed domain, or a partial pair cannot establish a
successful paired transport. The source-bound per-attempt `RUN.md` records the
exact frozen command. Preserve failed attempts and prepare a new directory for
any subsequent pilot; do not overwrite their plan or execution records.
