#!/usr/bin/env python3
"""Measure synthetic key to WindowServer-frame latency in isolated terminals.

Uses the same launch/config/geometry helpers as competitive-bench.sh. Requires
existing Screen Recording and event-posting access; never opens a permission
prompt. Four-pane stress is a CMDY-only before/after workload, not a comparison
with a differently configured Ghostty window.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import signal
import shutil
import statistics
import subprocess
import sys
import time
import urllib.request

from competitive_bench import (
    ROOT, BenchOptions, TerminalSession, atomic_json, binary_metadata,
    block_order, command_result, create_helper, is_descendant, power_snapshot, process_identity, sha256,
    window_command,
)
from parity_gate import input_frame_durations, percentile


@contextmanager
def interruption_guard():
    """Unwind owned app/fixture/observer cleanup when the supervisor stops us."""
    previous = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    def interrupted(number, _frame):
        # One interruption starts cleanup; another must not interrupt that cleanup.
        for item in previous:
            signal.signal(item, signal.SIG_IGN)
        raise RuntimeError(f"benchmark interrupted by signal {number}; partial evidence retained")
    try:
        for number in previous:
            signal.signal(number, interrupted)
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def run_observer(command, receipt, timeout=60):
    """Always reap the exact spawned event generator before app cleanup."""
    evidence = {"command": command, "startedMonotonicNS": time.monotonic_ns()}
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    evidence["pid"] = process.pid
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException as error:
        evidence.update(interrupted=True, error=str(error))
        if process.poll() is None:
            process.terminate()
        try:
            stdout, stderr = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            evidence["forcedKill"] = True
            process.kill()
            stdout, stderr = process.communicate(timeout=3)
        evidence.update(stdout=stdout, stderr=stderr)
        raise
    else:
        evidence.update(stdout=stdout, stderr=stderr)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        evidence.update(returncode=process.returncode, reaped=process.poll() is not None,
                        finishedMonotonicNS=time.monotonic_ns())
        atomic_json(receipt, evidence)


def api(session, path, payload=None):
    auth = json.loads((session.directory / "cmdy-config/plugin-api.json").read_text())
    request = urllib.request.Request(
        f"http://127.0.0.1:{auth['port']}/v1/{path}",
        data=None if payload is None else json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + auth["token"], "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def four_panes(session):
    original = api(session, "panes")["panes"]
    if len(original) != 1 or original[0]["pid"] != session.ready["pid"]:
        raise RuntimeError("probe fixture does not own the initial pane")
    probe = original[0]["id"]
    right = api(session, f"panes/{probe}/split", {"direction": "right"})["pane"]
    api(session, f"panes/{probe}/split", {"direction": "down"})
    api(session, f"panes/{right}/split", {"direction": "down"})
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        panes = api(session, "panes")["panes"]
        roles = list((session.directory / "fixture").glob("busy-*.json"))
        if len(panes) == 4 and len(roles) == 3 and all(p["pid"] > 0 for p in panes):
            session.busy_worker_identities = {}
            for path in roles:
                pid = int(json.loads(path.read_text())["pid"])
                identity = process_identity(pid)
                if not identity or not is_descendant(pid, session.app_pid):
                    raise RuntimeError("busy fixture is not an owned application descendant")
                session.busy_worker_identities[pid] = identity
            api(session, f"panes/{probe}/focus", {})
            atomic_json(session.directory / "panes.json", {"probePane": probe, "panes": panes})
            return
        time.sleep(0.1)
    raise RuntimeError("the three busy-pane fixtures did not become ready")


def stop_fixtures(session):
    """Stop recorded, identity-checked descendants; preserve the original error."""
    result = {"complete": False, "outcomes": [], "finalRecords": {}, "errors": []}
    try:
        identities = dict(getattr(session, "busy_worker_identities", {}))
        primary = session.worker_identity[0] if session.worker_identity else None
        if session.worker_identity:
            pid, identity = session.worker_identity
            identities[pid] = identity
        else:
            result["errors"].append("primary fixture ownership was not established")
        for pid, identity in identities.items():
            record = {"pid": pid, "originalIdentity": identity}
            try:
                if process_identity(pid) != identity:
                    record["status"] = "already-exited-or-replaced"
                elif session.process.poll() is not None or not is_descendant(pid, session.app_pid):
                    record["status"] = "ancestry-changed-no-signal"
                else:
                    os.kill(pid, signal.SIGTERM)
                    record["status"] = "terminated-owned-fixture"
            except ProcessLookupError:
                record["status"] = "already-exited"
            except Exception as error:
                record.update(status="cleanup-error", error=str(error))
                result["errors"].append(f"PID {pid}: {error}")
            result["outcomes"].append(record)
        deadline = time.monotonic() + 3
        receipt = session.directory / "fixture/received.json"
        while True:
            pending = []
            for pid, identity in identities.items():
                name = "cleanup.json" if pid == primary else f"busy-{pid}.json"
                path = session.directory / "fixture" / name
                final = None
                try:
                    final = json.loads(path.read_text())
                except (OSError, ValueError):
                    pass
                stopped = isinstance(final, dict) and final.get("pid") == pid and final.get("status") == "stopped"
                exited = process_identity(pid) != identity
                result["finalRecords"][str(pid)] = {
                    "path": str(path), "stopped": stopped, "originalProcessExited": exited,
                    "record": final}
                if not stopped or not exited:
                    pending.append(pid)
            result["receiptExists"] = receipt.is_file()
            result["pendingPIDs"] = pending
            result["complete"] = bool(primary is not None and not result["errors"]
                                      and result["receiptExists"] and not pending)
            if result["complete"] or time.monotonic() >= deadline:
                break
            time.sleep(0.05)
    except Exception as error:
        result["errors"].append(str(error))
    try:
        atomic_json(session.directory / "fixture-stop.json", result)
    except Exception as error:
        result["complete"] = False
        result["errors"].append("could not persist cleanup evidence: " + str(error))
    return result


def busy_load_summary(session, observation):
    identities = getattr(session, "busy_worker_identities", {})
    if len(identities) != 3:
        raise RuntimeError("four-pane qualification requires three owned busy fixtures")
    summaries = []
    for pid in sorted(identities):
        record = json.loads((session.directory / f"fixture/busy-{pid}.json").read_text())
        count, duration = record.get("bytesWritten"), record.get("durationSeconds")
        if (record.get("pid") != pid or record.get("role") != "busy" or record.get("status") != "stopped"
                or type(count) is not int or count <= 0
                or type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0):
            raise RuntimeError(f"busy PID {pid} lacks a stopped record with positive actual bytes and duration")
        ready, stopped = record.get("readyMonotonicNs"), record.get("stoppedMonotonicNs")
        if (type(ready) is not int or type(stopped) is not int
                or ready > observation["startedMonotonicNs"] or stopped < observation["finishedMonotonicNs"]):
            raise RuntimeError(f"busy PID {pid} did not remain active for the entire observation")
        summaries.append({"pid": pid, "bytesWritten": count, "durationSeconds": duration,
                          "requestedBytesPerSecond": record.get("requestedBytesPerSecond"),
                          "achievedBytesPerSecond": count / duration,
                          "rateScope": "whole fixture lifetime, including setup and settling",
                          "stopReason": record.get("stopReason")})
    return summaries


def power_signature(snapshot):
    signature = snapshot.get("signature", {})
    if not all(isinstance(signature.get(key), str) and signature[key].strip() for key in ("source", "settings")):
        raise RuntimeError("power source/settings are unavailable; comparison is not qualified")
    return {key: signature[key] for key in ("source", "settings")}


def observer_conditions(report):
    environment = report.get("environment", {})
    low_power, thermal = environment.get("lowPowerMode"), environment.get("thermalState")
    if type(low_power) is not bool or type(thermal) is not int or thermal not in range(4):
        raise RuntimeError("observer low-power/thermal conditions are unavailable")
    return {"lowPowerMode": low_power, "thermalState": thermal}


class ConditionGuard:
    """A single condition baseline across blocks and optional prior profiles."""
    def __init__(self, initial_power, reference=None):
        self.power = power_signature(initial_power)
        self.observer = None
        if reference is not None:
            if self.power != reference["power"]:
                raise RuntimeError("power source/settings differ from the reference profile")
            self.observer = observer_conditions({"environment": reference["observer"]})

    def check_power(self, snapshot):
        if power_signature(snapshot) != self.power:
            raise RuntimeError("power source/settings changed between or during benchmark blocks")

    def check_observer(self, report):
        current = observer_conditions(report)
        if self.observer is None:
            self.observer = current
        elif current != self.observer:
            raise RuntimeError("observer low-power/thermal conditions differ across blocks or profiles")

    def record(self):
        return {"power": self.power, "observer": self.observer}


def reference_conditions(directory):
    """Read-only validation also supports completed artifacts predating conditions.json."""
    summary = json.loads((directory / "summary.json").read_text())
    if summary.get("valid") is not True or (directory / "failure.json").exists():
        raise RuntimeError("condition reference must be a completed, valid benchmark directory")
    metadata = json.loads((directory / "metadata.json").read_text())
    guard = ConditionGuard(metadata["powerBefore"])
    reports = sorted(directory.glob("[0-9][0-9]-*/latency.json"))
    if not reports or len(reports) != len(summary.get("blocks", [])):
        raise RuntimeError("condition reference is missing completed raw runs")
    for path in reports:
        power = json.loads((path.parent / "power.json").read_text())
        guard.check_power(power["before"])
        guard.check_power(power["after"])
        guard.check_observer(json.loads(path.read_text()))
    return guard.record()


def build_observer(output, existing):
    if existing:
        if not os.access(existing, os.X_OK):
            raise ValueError("observer is not executable")
        return existing.resolve()
    target = output / "bin/input-observer"
    target.parent.mkdir(exist_ok=True)
    command = ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library",
               str(ROOT / "Tests/TerminalInputObserver.swift"), "-o", str(target)]
    result = subprocess.run(command, capture_output=True, text=True)
    atomic_json(output / "observer-build.json", {"command": command, "returncode": result.returncode,
                                               "stdout": result.stdout, "stderr": result.stderr})
    if result.returncode:
        raise RuntimeError("observer compilation failed; see observer-build.json")
    return target


def run(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cmdy-bin", type=Path, default=ROOT / ".build/release/cmdy")
    parser.add_argument("--ghostty-bin", type=Path, default=Path("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--observer", type=Path)
    parser.add_argument("--terminals", choices=("cmdy,ghostty", "cmdy", "ghostty"), default="cmdy,ghostty")
    parser.add_argument("--grid", default="120x36")
    parser.add_argument("--profile", choices=("matched", "cmdy-defaults"), default="matched")
    parser.add_argument("--fixture", choices=("raw-marker", "vim"), default="raw-marker")
    parser.add_argument("--vim", type=Path, default=Path("/usr/bin/vim"))
    parser.add_argument("--vim-runtime", type=Path, default=Path("/usr/share/vim/vim91"))
    parser.add_argument("--marker-mode", choices=("local-row", "full-screen"), default="local-row")
    parser.add_argument("--blocks", type=int, default=3)
    parser.add_argument("--samples", type=int, default=40)
    parser.add_argument("--settle-seconds", type=float, default=3)
    parser.add_argument("--diagnostic-frame-trace", action="store_true",
                        help="enable CMDY phase logging; output is diagnostic, never comparative qualification")
    parser.add_argument("--panes", type=int, choices=(1, 4), default=1)
    parser.add_argument("--load-bytes-per-second", type=int, default=4_000_000)
    parser.add_argument("--conditions-reference", type=Path,
                        help="require the power/low-power/thermal conditions of this prior valid output directory")
    args = parser.parse_args(argv)
    output_created = False
    try:
        grid = tuple(map(int, args.grid.lower().split("x")))
        if len(grid) != 2 or not (40 <= grid[0] <= 300 and 10 <= grid[1] <= 100):
            raise ValueError("grid must be COLUMNSxROWS within 40...300 by 10...100")
        if not 1 <= args.blocks <= 10 or not 5 <= args.samples <= 200:
            raise ValueError("blocks must be 1...10 and samples 5...200")
        if not 0 <= args.settle_seconds <= 30 or not 1 <= args.load_bytes_per_second <= 20_000_000:
            raise ValueError("invalid settling time or busy-pane output rate")
        if args.panes != 1 and args.terminals != "cmdy":
            raise ValueError("four-pane stress requires --terminals cmdy")
        if args.fixture == "vim" and (args.panes != 1 or args.marker_mode != "local-row"):
            raise ValueError("Vim fixture requires one pane and the local-row status marker")
        if args.fixture == "vim" and (not os.access(args.vim, os.X_OK) or not args.vim_runtime.is_dir()):
            raise ValueError("Vim fixture requires the requested installed Vim executable and runtime")
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
        output_created = True
        os.chmod(output, 0o700)
        tooling = output / "tooling"
        tooling.mkdir()
        tooling_hashes = {}
        for name in ("input-latency-bench.py", "input-latency-worker.py", "editor-latency-worker.py",
                     "competitive_bench.py", "terminal_bench_worker.py", "TerminalBenchWindow.swift", "TerminalInputObserver.swift",
                     "parity_gate.py"):
            destination = tooling / name
            shutil.copy2(ROOT / "Tests" / name, destination)
            tooling_hashes[name] = sha256(destination)
        helper = create_helper(output, args.helper)
        observer = build_observer(output, args.observer)
        options = BenchOptions(args.cmdy_bin.resolve(), args.ghostty_bin.resolve(),
                               profile=args.profile, timeout=30, settle_seconds=args.settle_seconds,
                               diagnostic_frame_trace=args.diagnostic_frame_trace,
                               diagnostic_marker_row=(grid[1] - 2 if args.fixture == "vim"
                                   else max(1, grid[1] // 2) - 1)
                               if args.diagnostic_frame_trace and args.marker_mode == "local-row" else None)
        machine = window_command(helper, "probe", 14)
        if not all(machine.get(key) for key in ("accessibilityTrusted", "screenCaptureAuthorized", "postEventAuthorized")):
            raise RuntimeError("existing Accessibility, Screen Recording and event-posting access are required")
        names = args.terminals.split(",")
        initial_power = power_snapshot()
        reference = reference_conditions(args.conditions_reference.resolve()) if args.conditions_reference else None
        atomic_json(output / "conditions-preflight.json", {"power": initial_power, "reference": reference})
        conditions = ConditionGuard(initial_power, reference)
        metadata = {"schemaVersion": 2, "markerMode": args.marker_mode, "metric": "synthetic-key-to-WindowServer-frame",
                    "fixture": args.fixture,
                    "diagnostic": args.diagnostic_frame_trace,
                    "profile": args.profile, "samplesPerBlock": args.samples, "requestedBlocks": args.blocks,
                    "fontSHA256": sha256(Path(machine["font"]["file"])),
                    "hardware": command_result(["/usr/sbin/sysctl", "hw.model", "hw.memsize", "hw.physicalcpu", "hw.logicalcpu", "machdep.cpu.brand_string"]),
                    "requestedGrid": grid, "panes": args.panes,
                    "busyBytesPerSecondPerPane": args.load_bytes_per_second if args.panes == 4 else 0,
                    "machine": machine, "systemLoadBefore": os.getloadavg(), "powerBefore": initial_power,
                    "conditionsReference": str(args.conditions_reference.resolve()) if args.conditions_reference else None,
                    "binaries": {name: binary_metadata(options.cmdy_bin if name == "cmdy" else options.ghostty_bin) for name in names},
                    "observer": {"path": str(observer), "sha256": sha256(observer), "prebuilt": args.observer is not None},
                    "toolingSHA256": tooling_hashes,
                    "sourceCommit": command_result(["git", "rev-parse", "HEAD"], ROOT),
                    "sourceStatus": command_result(["git", "status", "--short"], ROOT)}
        if args.fixture == "vim":
            metadata["editor"] = {"binary": binary_metadata(args.vim),
                                  "version": command_result([str(args.vim), "--version"]),
                                  "runtime": str(args.vim_runtime.resolve()),
                                  "runtimeSHA256": {str(path.relative_to(args.vim_runtime)): sha256(path)
                                      for path in sorted(args.vim_runtime.rglob("*.vim")) if path.is_file()},
                                  "marker": "TextChangedI updates a full-width status-line background; same hook in both terminals"}
        atomic_json(output / "metadata.json", metadata)
        summaries = []
        reference_display = None
        for block in range(args.blocks):
            order = block_order(block) if len(names) == 2 else names
            for terminal in order:
                run = output / f"{block:02d}-{terminal}"
                worker = [sys.executable, str(tooling / ("editor-latency-worker.py" if args.fixture == "vim" else "input-latency-worker.py")),
                          "--output", str(run / "fixture"), "--timeout", "120"]
                if args.fixture == "vim":
                    worker += ["--vim", str(args.vim.resolve()), "--runtime", str(args.vim_runtime.resolve())]
                else:
                    worker += ["--marker-mode", args.marker_mode]
                if args.panes == 4:
                    worker += ["--secondary-load", str(args.load_bytes_per_second)]
                with TerminalSession(options, helper, terminal, run, target_grid=grid,
                                     fixture_command=worker, ready_path=run / "fixture/ready.json") as session:
                    session.launch()
                    try:
                        session.window(activate=True)
                        # Fix both terminals to the same physical display as
                        # well as the same measured PTY grid.
                        session.place_window(120, 120)
                        session.fit_grid(grid, allow_resize=True)
                        if args.panes == 4:
                            four_panes(session)
                        time.sleep(args.settle_seconds)
                        before = session.window(activate=True)
                        atomic_json(run / "window-before.json", before)
                        grid_before = session.grid()
                        atomic_json(run / "grid-before.json", grid_before)
                        display = before["windows"][0]["displayID"]
                        if reference_display is None:
                            reference_display = display
                        elif display != reference_display:
                            raise RuntimeError("benchmark windows moved to a different display between runs")
                        power_before = power_snapshot()
                        atomic_json(run / "power.json", {"before": power_before})
                        conditions.check_power(power_before)
                        atomic_json(run / "load-before.json", {"systemLoad": os.getloadavg()})
                        command = [str(observer), "--pid", str(session.app_pid),
                                   "--window", str(before["windows"][0]["windowID"]),
                                   "--output", str(run / "latency.json"), "--samples", str(args.samples),
                                   "--marker-mode", args.marker_mode]
                        if args.panes == 4:
                            command += ["--region", "0.08,0.16,0.28,0.22"]
                        elif args.fixture == "vim":
                            command += ["--region", "0.08,0.75,0.84,0.23"]
                        observation = {"startedMonotonicNs": time.monotonic_ns()}
                        result = run_observer(command, run / "observer-process.json", timeout=60)
                        observation["finishedMonotonicNs"] = time.monotonic_ns()
                        atomic_json(run / "observation.json", observation)
                        atomic_json(run / "observer-status.json", {"command": command, "returncode": result.returncode,
                                                                 "stdout": result.stdout, "stderr": result.stderr})
                        if result.returncode:
                            atomic_json(run / "window-failed.json",
                                        window_command(helper, "inspect", session.app_pid))
                            raise RuntimeError(f"observer failed for {run.name}: {result.stderr.strip()}")
                        after = session.window()
                        atomic_json(run / "window-after.json", after)
                        grid_after = session.grid()
                        atomic_json(run / "grid-after.json", grid_after)
                        if grid_after != grid_before:
                            raise RuntimeError("measured pane grid changed during observation")
                        if args.panes == 1 and (grid_after["columns"], grid_after["rows"]) != grid:
                            raise RuntimeError("measured pane grid differs from requested grid")
                        power_after = power_snapshot()
                        atomic_json(run / "power.json", {"before": power_before, "after": power_after})
                        conditions.check_power(power_after)
                        if before["windows"] != after["windows"]:
                            raise RuntimeError("window geometry/display changed during observation")
                    finally:
                        stopped = stop_fixtures(session)
                    if not stopped["complete"]:
                        raise RuntimeError("owned fixtures did not exit and publish final evidence within the cleanup deadline")
                    received = json.loads((run / "fixture/received.json").read_text())
                    if [item["sequence"] for item in received] != list(range(1, args.samples + 1)):
                        raise RuntimeError("fixture receipts differ from the synthetic key sequence")
                    if args.fixture == "vim":
                        import hashlib
                        cleanup = json.loads((run / "fixture/cleanup.json").read_text())
                        if (cleanup.get("error") != "" or cleanup.get("insertedCharacters") != args.samples
                                or cleanup.get("lastValidatedTextSHA256") != hashlib.sha256(b"a" * args.samples).hexdigest()
                                or any(item.get("event") != "TextChangedI" for item in received)):
                            raise RuntimeError("Vim did not validate the exact requested edits")
                    report = json.loads((run / "latency.json").read_text())
                    durations = input_frame_durations(report)
                    conditions.check_observer(report)
                    atomic_json(output / "conditions.json", conditions.record())
                    summary = {"block": block, "terminal": terminal, "median": percentile(durations, 0.5),
                               "p95": percentile(durations, 0.95), "max": max(durations)}
                    if args.panes == 4:
                        summary["busyPanes"] = busy_load_summary(session, observation)
                        atomic_json(run / "busy-load.json", {"panes": summary["busyPanes"]})
                    summaries.append(summary)
                    print(json.dumps(summary), flush=True)
        comparison = {name: {"medianOfBlockMediansMs": statistics.median(item["median"] for item in summaries if item["terminal"] == name),
                             "medianOfBlockP95Ms": statistics.median(item["p95"] for item in summaries if item["terminal"] == name)} for name in names}
        atomic_json(output / "summary.json", {"valid": True, "metric": metadata["metric"],
                    "fixture": args.fixture,
                    "diagnostic": args.diagnostic_frame_trace,
                    "profile": args.profile,
                    "conditions": conditions.record(),
                    "panes": args.panes, "markerMode": args.marker_mode, "displayID": reference_display, "blocks": summaries, "terminals": comparison,
                    "limitations": [("Installed Vim edits a generated source buffer; a shared TextChangedI status-line hook marks redraw completion"
                                     if args.fixture == "vim" else "Synthetic input and a color-responder fixture"),
                                     "WindowServer presentation, not physical keyboard-to-photon latency", "Scaled capture observer overhead and display/capture cadence apply", "Four-pane runs are CMDY-only comparisons"]})
        print(json.dumps(comparison, indent=2))
        return 0
    except Exception as error:
        if output_created:
            atomic_json(output / "failure.json", {"valid": False, "error": str(error)})
        print(f"Input latency benchmark failed: {error}", file=sys.stderr)
        return 1


def main(argv=None):
    with interruption_guard():
        return run(argv)


if __name__ == "__main__":
    raise SystemExit(main())
