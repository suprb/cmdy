# CmdyPTY behavioral contract

Status: compatibility specification for an independent PTY implementation

Reference behavior: the active cmdy PTY API and tests immediately before lineage replacement

Scope: public API, byte transport, process lifecycle, failure behavior, resource bounds, and stress acceptance

## 1. Purpose

CmdyPTY connects one local child process to one native pseudo-terminal. This document defines behavior only. A conforming replacement may use any original design built from documented Darwin/POSIX facilities.

The module is transport, not a terminal parser. It must preserve every byte in each direction and must not decode, normalize, combine, or otherwise interpret terminal data.

## 2. Public API

### 2.1 `LocalProcessDelegate`

The class-bound delegate provides three operations:

- `processTerminated(_:exitCode:)` receives the owning `LocalProcess` and a decoded exit result;
- `dataReceived(slice:)` receives an ordered, nonempty byte slice from the PTY; and
- `getWindowSize()` returns the initial terminal `winsize`.

Callbacks run on the queue supplied to `LocalProcess`. The default is the main queue. Callbacks from one process generation are ordered. No delegate callback may occur synchronously inside `startProcess`, `send`, or `terminate`.

### 2.2 `LocalProcess`

The source-compatible surface is:

- `init(delegate:dispatchQueue:)`, where the queue argument accepts `nil` and defaults to `DispatchQueue.main`;
- read-only-to-callers `childfd`, initially and when inactive `-1`;
- read-only-to-callers `shellPid`, initially and when inactive `0`;
- read-only-to-callers `running`, initially and when inactive `false`;
- `startProcess(executable:args:environment:execName:currentDirectory:)`, retaining its defaults of `/bin/bash`, no extra arguments, inherited/default environment selection, no argv-zero override, and no directory override;
- `send(data:)`;
- `terminate()`;
- `defaultEnvironment(termName:)`; and
- `setHostLogging(directory:)`.

Starting while `running == true` is an observed compatibility no-op. Callers that want a different process terminate the active generation first. Any future replace-in-place behavior requires a separate API or an explicit compatibility decision; it must not silently change this method.

`LocalProcess` is reusable after natural exit or explicit termination. A new generation starts from clean read, write, descriptor, callback, and termination state.

### 2.3 `PseudoTerminalHelpers`

The legacy public helper surface remains source-compatible until a deliberate API-removal release:

- create a PTY, fork, optionally change the child's working directory, and execute with an explicit argument/environment vector, returning child PID and master descriptor or `nil`;
- update the window size of a master descriptor and return the raw `ioctl` status; and
- query readable bytes, returning raw status and byte count.

Invalid descriptors fail through ordinary POSIX status/`errno`; they do not trap. The higher-level `LocalProcess` may use a different private spawn mechanism, but that does not by itself remove these public functions.

The helper's returned master descriptor preserves its compatibility flags: it is blocking and is not close-on-exec. `LocalProcess` configures its own descriptor for nonblocking, close-on-exec transport after the helper returns. Supplying an empty argument array is valid; a normal executable such as `/usr/bin/true` launches, returns a parent `(pid, fd)` tuple, and exits successfully.

## 3. Spawn contract

- The initial `winsize` is obtained from the delegate before child launch and is visible to the child from its first command.
- The child has a controlling terminal and is the leader of its own process group/session for job control.
- Standard input, output, and error all refer to the slave terminal.
- The parent retains only the master terminal descriptor. At the `LocalProcess` layer it is configured nonblocking and close-on-exec; the public low-level helper itself returns the descriptor with blocking and inherited-on-exec compatibility flags.
- The child's argument vector begins with `execName` when supplied and otherwise with `executable`; `args` follow unchanged.
- A non-`nil` environment is passed exactly as supplied, including an empty array. A `nil` environment uses `LocalProcess.defaultEnvironment(termName: "xterm-256color")`.
- A valid supplied current directory becomes the child's working directory before exec. For compatibility, an invalid or inaccessible directory is ignored rather than treated as a launch error; the child executes in the inherited directory. Without an override, the child also inherits the parent's directory.
- Child signal disposition and mask do not accidentally inherit application-only handlers or blocked signals.
- Unrelated parent descriptors are not leaked into the exec'd child.
- A missing executable exits using the conventional command-not-found status 127. Another pre-exec or exec failure uses a conventional nonzero launch status and eventually reports termination rather than hanging.
- A parent-side spawn or descriptor-configuration failure leaves `running == false`, `shellPid == 0`, and `childfd == -1`. It reports one `processTerminated(..., exitCode: nil)` on the callback queue. No partial child, descriptor, or monitor remains.

The default child environment contains:

- `TERM=<requested termName>`;
- `COLORTERM=truecolor`;
- `LANG=en_US.UTF-8`; and
- any present host values for `LOGNAME`, `USER`, `DISPLAY`, `LC_TYPE`, `USERNAME`, `HOME`, and `PATH`.

Duplicate names in a caller-supplied environment retain caller semantics; CmdyPTY does not reinterpret them.

## 4. Byte transport

### 4.1 Child to delegate

- Bytes are delivered in PTY order with no loss, duplication, decoding, newline conversion, or NUL termination. UTF-8, malformed UTF-8, NUL, and all 256 byte values are valid.
- Delivered chunks may have any positive size. Callers must not depend on chunk boundaries.
- Exactly one generation owns delivery. Bytes already read or queued from a retired generation are discarded and never reach a later generation's delegate.
- EOF and Darwin's PTY-close error form are both normal read completion. The descriptor closes exactly once.
- A blocked callback queue creates backpressure instead of unbounded user-space accumulation. A 12,000,000-byte stream survives a 350 ms main-queue stall byte-for-byte.
- Draining a large output stream yields regularly to its callback queue; terminal output cannot monopolize the main queue indefinitely.

### 4.2 Caller to child

- `send(data:)` copies the supplied bytes before returning; the caller may mutate or release its storage immediately.
- Empty data and sends while inactive are safe no-ops.
- Concurrent callers are serialized without interleaving bytes within an individual `send` payload, loss, or duplication.
- A partial nonblocking write resumes at the first unwritten byte when the descriptor becomes writable.
- Pending writes are bounded by the data callers explicitly submit and are discarded when their process generation retires.
- Write failure closes or retires the applicable write path without crashing, spinning, or corrupting a later generation.

## 5. Resize contract

- `setWinSize` applies rows and columns to the PTY master with `TIOCSWINSZ` semantics.
- When the kernel accepts a changed size, the foreground process group observes the corresponding window-change behavior.
- Resize calls may occur rapidly and concurrently with output. They cannot reorder terminal bytes, close the descriptor, or deadlock lifecycle calls.
- The surface may read `childfd` and call resize only while it is nonnegative. Racing a close is still safe: the operation returns an ordinary POSIX failure rather than affecting an unrelated reused descriptor.
- The helper accepts all values representable by `winsize`; grid-level minimums are enforced by the App surface, not by CmdyPTY.

## 6. Natural completion

- The child is reaped exactly once. CmdyPTY is the sole owner of `waitpid` for a launched PID.
- Reaping retries interrupted waits and never leaves a zombie.
- PTY EOF may precede process exit and process exit may precede EOF. Termination is complete only after read delivery is finished/retired and the child has been reaped.
- Output preceding EOF is delivered before the matching termination callback.
- A normal exit reports its 8-bit status.
- A signal exit reports `128 + signal`, matching shell convention.
- An unavailable, stopped, or otherwise undecodable wait result reports `nil`.
- The active generation receives exactly one termination callback. A stale generation cannot clear or report termination for a newer process, even if the operating system later reuses its PID.
- After completion, `running == false`, `shellPid == 0`, and `childfd == -1` before or by the time the termination callback is observed.

The reaper's ownership outlives `LocalProcess` long enough to collect a naturally exiting child. Deallocating the Swift owner must never strand a zombie.

## 7. Explicit termination

- `terminate()` is idempotent and returns promptly; it does not synchronously wait for process exit. The defended return budget is under 100 ms.
- It immediately prevents further data delivery for that generation, abandons pending writes, closes the master descriptor, and makes the object reusable.
- Termination targets the child's process group so foreground/background descendants attached to the session do not survive their terminal.
- Cooperative children receive graceful termination. Children that ignore hangup/termination are escalated to an uncatchable kill within a bounded interval; the full group is gone and the leader reaped within four seconds under the lifecycle test.
- Scheduled escalation checks that the original child is still unreaped before signalling. It must not signal a PID or process group reused by a later unrelated process.
- A missing group may fall back to the child PID. `ESRCH` is successful already-gone behavior.
- Explicitly retired/superseded generations do not emit a termination callback intended for the active generation.

`deinit` must at minimum close transport, disable callbacks, and preserve reaper ownership. The product's pane lifecycle calls `terminate()` before releasing an active process. If `deinit` also initiates bounded group termination, that stronger cleanup is allowed, but it must not block and must retain the no-zombie/PID-reuse protections.

## 8. Reuse and race behavior

- Calls to public lifecycle state, `send`, `startProcess`, and `terminate` are thread-safe.
- Delegate callbacks may call state accessors without deadlock.
- A process may start again from inside or immediately after a termination callback.
- Terminate followed immediately by start cannot deliver stale output, stale exit status, or delayed escalation into the new session.
- Late read/write/exit events carry their generation and become no-ops after retirement.
- Closing a read source while it is suspended is balanced safely; no libdispatch over-resume, suspended-source deallocation, or vanished-event crash occurs.
- PID, descriptor, dispatch-source, buffer, and callback ownership have one clear terminal transition. Repeated close/terminate/deinit paths are harmless.

## 9. Host logging

- `setHostLogging(directory:)` enables raw child-output logging to the selected directory; `nil` disables it.
- Logging never changes delivered bytes or callback ordering.
- A log write failure is nonfatal and cannot stop PTY drainage.
- Logging is diagnostic and must not expose data unless explicitly enabled. File creation remains bounded to received chunks and honors the selected directory.

## 10. Resource and responsiveness acceptance

The replacement must satisfy all of these on macOS:

| Scenario | Requirement |
| --- | --- |
| main queue blocked for 350 ms during 12 MB output | child remains backpressured, all bytes arrive, one exit callback |
| process emits UTF-8, malformed byte, NUL, ASCII | exact byte sequence arrives |
| process exits 7 | callback reports 7 |
| process terminates itself with `SIGTERM` | callback reports `128 + SIGTERM` |
| complete then start again | both outputs and callbacks are correct; no stale state |
| terminate busy stream then start | only new output arrives; old child is reaped |
| eight concurrent writers, 80 sends each, 257 bytes/send | every submitted byte returns through `cat` |
| child and descendant ignore HUP/TERM | terminate returns under 100 ms; group dies and leader is reaped within 4 seconds |
| 40+ sequential short sessions | open-descriptor count does not grow above post-warm-up baseline |
| repeated pane open/close under output | process, process-group, descriptor, source, and memory counts return to baseline |
| resize storm during sustained output | final size reaches child; no byte loss, deadlock, or stale descriptor use |

Bulk output through the full app also remains within the existing performance gate: a 3 MiB PTY-to-terminal-to-GPU stream exposes its tail marker within 6000 ms, and two panes concurrently draining 1 MiB each expose both markers within 6000 ms.

## 11. Verification

Run from repository root:

```sh
swift test --package-path Core --filter LocalProcessFlowControlTests
swift test --package-path Core --filter LocalProcessLifecycleTests
swift test --package-path Core
./package.sh
Tests/perf-gate.sh
```

Before independence is declared, add or retain black-box tests for:

- the full public helper signatures and invalid-descriptor results;
- starting while already running;
- failed spawn, missing executable, invalid-working-directory fallback, empty arguments, and empty environment;
- the distinction between low-level helper descriptor flags and `LocalProcess` transport flags;
- callback queue identity and callback ordering;
- EOF-before-exit and exit-before-EOF;
- repeated EINTR and partial-write behavior;
- resize/close descriptor-reuse races;
- immediate terminate/start for hundreds of generations;
- owner deallocation before natural exit and before forced termination; and
- a many-pane stress run with process, zombie, descriptor, source, thread, and memory baselines.

## 12. Allowed implementation freedom

Conformance does not require the former dispatch types, chunk sizes, queue count, buffering thresholds, reaper representation, timer representation, spawn wrapper, or signal order. It requires the API, byte order, queue behavior, lifecycle states, child/job-control semantics, failure behavior, bounded resources, and acceptance results above.
