# Untimed first-visible startup pilot

`NativePerformance/compare_startup.py` prepares one CMDY/Ghostty pair using the
already qualified [startup recorder](TERMINAL-STARTUP-BENCHMARKS.md). Preparation
copies and checks its exact observer, source files and headless qualification.
It does not launch an app, query permissions, activate a window or start capture.

The `run` action uses the reviewed `compare_output.py` supervisor. Both the
combined-session input clock and hardware idle clock must initially exceed
300 seconds. During the run, the combined-session clock stops the owned
controller when session input resumes; both clocks are retained. The child
checks the session clock again immediately before each observer invocation.
No permission request or clipboard operation is available in this adapter.

The native slot obtains fresh display mode, refresh rate, rotation, bounds and
power metadata through the frozen observer's read-only `--probe-display` mode.
The existing recorder then freezes the private configuration and generated
worker inputs. Its ScreenCaptureKit display stream must deliver a complete
prelaunch frame before the native `posix_spawn` boundary. It observes full
generated viewport pixels, Mach presentation clocks, process start identities,
window ownership and the visibility perimeter. The first complete viewport
must remain stable for one second.

This pair additionally requires the **initial** PTY grid to be 98×29 and the
observed generated viewport to be generation 1. The public configuration uses
CMDY's default initial size and Ghostty's 96×28 request with 10-point padding.
That mapping is still unvalidated for the current apps. A wrong initial grid
fails the trial. There is no AX resize, postlaunch activation helper, DSR
readiness proxy or replacement with a corrected later frame. The raw failure
and initial grid/generation are preserved, including an explicitly unverified
self-report if the worker exited before its identity could be established.

Prepare a new private directory with the exact candidate and qualification
receipts:

```sh
python3 -B Tests/NativePerformance/compare_startup.py prepare \
  --candidate /absolute/verified-candidate \
  --startup-qualification /absolute/startup-qualification \
  --window-qualification /absolute/window-qualification.json \
  --activity-review /absolute/activity-review.json \
  --ghostty-sha256 EXPECTED_SHA256 \
  --power-source 'Battery Power' --display-id 1 \
  --output /absolute/new-startup-pilot
```

Run the frozen `tooling/Tests/NativePerformance/compare_startup.py` with the
plan's pinned Python interpreter, action `run` and the same `--output` only in
the reserved native observation slot. Reusing that directory cannot overwrite
an existing execution. `audit-cleanup --output …` is read-only: it requires
retained reaping records and checks that every recorded owned PID is absent.
The existing recorder exports/deletes only the exact generated CMDY defaults
domain, after proving app and worker cleanup. Missing ownership evidence leaves
cleanup unproved and authorizes no process signal or defaults deletion.
Private generated files and raw evidence remain inside the pilot directory.

The independent reader reconstructs both raw observations and joins them to
the frozen binary, observer, worker, public configuration, shared generated
payload and actual display metadata. An untimed finalizer keeps measured
samples at zero and cannot enter the performance gate. Raw diagnostic clock
differences remain in the recorder receipts; this pilot produces no latency
distribution or CMDY-versus-Ghostty speed claim. The recorder's documented
capture-delivery and non-atomic visibility limitations remain unchanged.
