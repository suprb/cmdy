#!/usr/bin/env python3
"""Native 2x2 input comparison. Requires prebuilt tools and an exclusive GUI slot."""
from __future__ import annotations

import argparse
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
from competitive_bench import (BenchOptions, TerminalSession, atomic_json, binary_metadata,
                               block_order, command_result, is_descendant, power_snapshot, process_identity,
                               sha256, window_command)
from four_pane_evidence import GRID, PAYLOAD_PERIOD, validate_busy, validate_marker, validate_rectangles, validate_latency, validate_response_clocks, validate_settling, validate_exit_barrier
from four_pane_contract import ACTIONS, REQUIRED_TOOLING, expected_bindings, validate_launch

spec = importlib.util.spec_from_file_location("retained_input_bench", HERE / "input-latency-bench.py")
retained = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retained)

def configure(session):
    if session.terminal == "ghostty":
        with session.config_path.open("a") as stream:
            stream.write("unfocused-split-opacity = 1\n")
            for key, (_, action) in ACTIONS.items():
                stream.write(f"keybind = cmd+ctrl+alt+{key}={action}\n")
    else:
        atomic_json(session.directory / "cmdy-config/keybindings.json", expected_bindings())


def control(worker, token, operation, **fields):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2)
        connection.connect(worker["socketPath"])
        connection.sendall(json.dumps({"op": operation, "runToken": token, **fields}).encode() + b"\n")
        raw = bytearray()
        while not raw.endswith(b"\n"):
            data = connection.recv(4096)
            if not data or len(raw) > 64 * 1024:
                raise RuntimeError("invalid fixture control reply")
            raw.extend(data)
    result = json.loads(raw)
    if not result.get("ok") or result.get("pid") != worker["pid"] or result.get("runToken") != token:
        raise RuntimeError("fixture control failed or returned another identity: " + str(result))
    return result


class Layout:
    def __init__(self, session, setup_helper, token):
        self.session, self.setup_helper, self.token = session, setup_helper, token
        self.workers, self.identities, self.steps = {}, {}, []

    def record(self, entry):
        self.steps.append(entry)
        atomic_json(self.session.directory / "setup.json", self.steps)

    def owned(self, worker):
        identity = self.identities.get(worker["pid"])
        if not identity or process_identity(worker["pid"]) != identity or not is_descendant(worker["pid"], self.session.app_pid):
            raise RuntimeError("fixture process ownership/start identity changed")

    def discover(self, count):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            found = [json.loads(path.read_text()) for path in sorted((self.session.directory / "fixture").glob("worker-*.json"))]
            if len(found) > count:
                raise RuntimeError("unexpected extra fixture")
            if len(found) == count:
                if {item.get("slot") for item in found} != set(range(count)) or len({item.get("ttyPath") for item in found}) != count:
                    raise RuntimeError("fixture slots or TTYs are not unique")
                for worker in found:
                    if worker.get("runToken") != self.token:
                        raise RuntimeError("fixture belongs to a different run")
                    if worker.get("workerSourceSHA256") != sha256(HERE / "four_pane_worker.py"):
                        raise RuntimeError("running worker source differs from the registered fixture")
                    pid = worker["pid"]
                    if pid not in self.identities:
                        identity = process_identity(pid)
                        if not identity or not is_descendant(pid, self.session.app_pid):
                            raise RuntimeError("fixture is not an app descendant")
                        self.identities[pid] = identity
                    self.owned(worker)
                    if worker["slot"] in self.workers and self.workers[worker["slot"]] != worker:
                        raise RuntimeError("worker metadata changed")
                    self.workers[worker["slot"]] = worker
                self.record({"event": "workers", "expectedCount": count, "workers": found,
                             "startIdentities": self.identities.copy()})
                return
            time.sleep(.05)
        raise RuntimeError("fixture count did not converge")

    def states(self):
        result = {}
        for slot, worker in self.workers.items():
            self.owned(worker)
            result[slot] = control(worker, self.token, "status")
        return result

    def helper(self, operation, **fields):
        state = self.session.window()
        command = [str(self.setup_helper), operation, "--pid", str(self.session.app_pid),
                   "--window", str(state["windows"][0]["windowID"])]
        for key, value in fields.items():
            command += ["--" + key, str(value)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=8)
        evidence = {"command": command, "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        self.record(evidence)
        if result.returncode:
            raise RuntimeError("owned setup helper failed")
        reply = json.loads(result.stdout)
        if not reply.get("ok"):
            raise RuntimeError("owned setup helper rejected operation")
        return reply

    def key(self, action):
        return self.helper("key", action=action)

    def focused(self):
        before = self.states()
        self.key("probe")
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            after = self.states()
            changes = []
            for slot in before:
                old, new = before[slot]["setupKeys"], after[slot]["setupKeys"]
                if new[:len(old)] != old:
                    raise RuntimeError("setup receipt history changed")
                if new != old:
                    if new[len(old):] != [122]:
                        raise RuntimeError("setup shortcut leaked bytes or focus probe duplicated")
                    changes.append(slot)
            if changes:
                if len(changes) != 1:
                    raise RuntimeError("multiple panes received one focus probe")
                self.record({"event": "focus-probe", "slot": changes[0], "states": after})
                return changes[0]
            time.sleep(.025)
        raise RuntimeError("no pane received the focus probe")

    def ensure_focus(self, slot, direction=None):
        if self.focused() == slot:
            return
        if direction:
            self.key("focus-" + direction)
            if self.focused() == slot:
                return
        raise RuntimeError("documented directional action did not focus expected pane")

    def create(self):
        self.discover(1)
        self.ensure_focus(0)
        self.key("split-right")
        self.discover(2)
        self.ensure_focus(1, "right")
        self.key("focus-left")
        self.ensure_focus(0)
        self.key("split-down")
        self.discover(3)
        self.ensure_focus(2, "down")
        self.key("focus-right")
        self.ensure_focus(1)
        self.key("split-down")
        self.discover(4)
        self.ensure_focus(3, "down")
        self.key("equalize")
        self.key("focus-up")
        self.ensure_focus(1)
        self.key("focus-left")
        self.ensure_focus(0)

    def focus_slot(self, slot):
        current = self.focused()
        if current % 2 != slot % 2:
            self.key("focus-right" if slot % 2 else "focus-left")
        if current // 2 != slot // 2:
            self.key("focus-down" if slot // 2 else "focus-up")
        self.ensure_focus(slot)

    def balance_pair(self, first, second, axis, forward, backward):
        """Calibrate public divider actions against real TTY sizes, untimed."""
        self.focus_slot(first)
        for _ in range(8):
            states = self.states()
            before = abs(states[first]["grid"][axis] - states[second]["grid"][axis])
            if before == 0:
                return
            improved = False
            for action, inverse in ((forward, backward), (backward, forward)):
                used = 0
                for _ in range(6):
                    self.key(action)
                    used += 1
                    time.sleep(.1)
                    after = self.states()
                    difference = abs(after[first]["grid"][axis] - after[second]["grid"][axis])
                    self.record({"event": "divider-grid-adjustment", "action": action,
                        "pair": [first, second], "axis": axis, "beforeDifference": before,
                        "afterDifference": difference, "states": after})
                    if difference != before:
                        improved = difference < before
                        break
                if improved:
                    break
                # Restore a direction that did not improve actual cell balance.
                for _ in range(used):
                    self.key(inverse)
                    time.sleep(.1)
            if not improved:
                raise RuntimeError("public divider actions could not balance terminal grids")
        raise RuntimeError("bounded terminal-grid balancing did not converge")

    def fit(self):
        attempts = []
        for _ in range(18):
            states = self.states()
            grids = [state["grid"] for state in states.values()]
            state = self.session.window()
            attempts.append({"states": states, "window": state})
            atomic_json(self.session.directory / "geometry.json", {"targetPerPane": GRID, "attempts": attempts})
            if all(item == GRID for item in grids):
                time.sleep(.2)
                if all(item["grid"] == GRID for item in self.states().values()):
                    return
            bounds = state["windows"][0]["bounds"]
            columns = statistics.mean(item["columns"] for item in grids)
            rows = statistics.mean(item["rows"] for item in grids)
            dw = (60 - columns) * 2 * bounds["width"] / (columns * 2 + 6)
            dh = (18 - rows) * 2 * (bounds["height"] - 45) / (rows * 2 + 3)
            if dw == 0 and any(item["columns"] != 60 for item in grids):
                self.balance_pair(0, 1, "columns", "resize-right", "resize-left")
                self.focus_slot(0)
                continue
            if dh == 0 and any(item["rows"] != 18 for item in grids):
                self.balance_pair(0, 2, "rows", "resize-up", "resize-down")
                self.balance_pair(1, 3, "rows", "resize-up", "resize-down")
                self.focus_slot(0)
                continue
            attempts[-1]["resize"] = window_command(self.session.helper, "resize", self.session.app_pid,
                                                    bounds["width"] + dw, bounds["height"] + dh, 120, 120)
            atomic_json(self.session.directory / "geometry.json", {"targetPerPane": GRID, "attempts": attempts})
            self.key("equalize")
            time.sleep(.2)
        raise RuntimeError("four exact grids could not converge; no stty override is permitted")

    def cleanup(self):
        evidence = {"workers": {}, "errors": [], "originalProcesses": {}}
        # Capture newly created roles even if setup failed before normal discovery.
        for path in (self.session.directory / "fixture").glob("worker-*.json"):
            try:
                worker = json.loads(path.read_text())
                if worker.get("runToken") == self.token and is_descendant(worker["pid"], self.session.app_pid):
                    if worker["pid"] not in self.identities:
                        identity = process_identity(worker["pid"])
                        if identity:
                            self.identities[worker["pid"]] = identity
                            self.workers[worker["slot"]] = worker
            except Exception as error:
                evidence["errors"].append(str(error))
        for slot, worker in self.workers.items():
            try:
                self.owned(worker)
                try:
                    control(worker, self.token, "stop", holdExit=True)
                except (OSError, RuntimeError):
                    self.owned(worker)
                    os.kill(worker["pid"], signal.SIGTERM)
            except Exception as error:
                evidence["errors"].append(f"slot {slot}: {error}")
        deadline = time.monotonic() + 3
        fixture = self.session.directory / "fixture"
        while time.monotonic() < deadline:
            if all((fixture / f"final-{slot}.json").exists() for slot in self.workers):
                break
            time.sleep(.01)
        # Release only after all final receipts exist and their original PTYs
        # are still alive. This barrier is outside the measured interval.
        try:
            ready = time.monotonic_ns()
            for worker in self.workers.values():
                self.owned(worker)
            release = {"runToken": self.token, "finalRecordsReadyMonotonicNs": ready,
                       "workerPIDs": {slot: worker["pid"] for slot, worker in self.workers.items()},
                       "finalSHA256": {slot: sha256(fixture / f"final-{slot}.json") for slot in self.workers},
                       "releaseMonotonicNs": time.monotonic_ns()}
            atomic_json(fixture / "exit-release.json", release)
        except Exception as error:
            evidence["errors"].append(f"exit barrier: {error}")
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if all((self.session.directory / f"fixture/final-{slot}.json").exists()
                   and process_identity(worker["pid"]) != self.identities.get(worker["pid"])
                   for slot, worker in self.workers.items()):
                break
            time.sleep(.025)
        for slot, worker in self.workers.items():
            original = self.identities.get(worker["pid"])
            exited = original is not None and process_identity(worker["pid"]) != original
            evidence["originalProcesses"][slot] = {"pid": worker["pid"], "startIdentity": original,
                                                   "exited": exited}
            if not exited:
                evidence["errors"].append(f"slot {slot}: original worker did not exit before app cleanup")
            path = self.session.directory / f"fixture/final-{slot}.json"
            if path.exists():
                final = json.loads(path.read_text())
                if any(final.get(key) != worker.get(key) for key in ("pid", "slot", "ttyPath", "runToken", "startedMonotonicNs")):
                    evidence["errors"].append(f"slot {slot}: final receipt identity differs from readiness")
                evidence["workers"][slot] = final
            else:
                evidence["errors"].append(f"slot {slot}: no cleanup receipt before app stop")
        atomic_json(self.session.directory / "worker-cleanup.json", evidence)
        return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cmdy-bin", type=Path, required=True)
    parser.add_argument("--ghostty-bin", type=Path, required=True)
    parser.add_argument("--window-helper", type=Path, required=True)
    parser.add_argument("--setup-helper", type=Path, required=True)
    parser.add_argument("--observer", type=Path, required=True)
    parser.add_argument("--observer-sha256", required=True,
                        help="SHA-256 of the prebuilt schema-3 TerminalInputObserver")
    parser.add_argument("--profile", choices=("matched", "cmdy-defaults"), default="matched")
    parser.add_argument("--blocks", type=int, default=6)
    parser.add_argument("--samples", type=int, default=40)
    parser.add_argument("--settle-seconds", type=float, default=5)
    args = parser.parse_args()
    if not 1 <= args.blocks <= 20 or not 40 <= args.samples <= 200 or args.settle_seconds != 5:
        parser.error("blocks must be 1...20, samples 40...200, settling is preregistered at five seconds")
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for key in ("cmdy_bin", "ghostty_bin", "window_helper", "setup_helper", "observer"):
        path = getattr(args, key).resolve()
        if not path.is_file():
            parser.error("missing explicitly prebuilt input " + str(path))
        setattr(args, key, path)
    if not re.fullmatch("[0-9a-f]{64}", args.observer_sha256) or sha256(args.observer) != args.observer_sha256:
        parser.error("observer differs from the explicitly pinned schema-3 observer binary")
    options = BenchOptions(args.cmdy_bin, args.ghostty_bin, profile=args.profile, font_size=14,
                           timeout=120, settle_seconds=5)
    # This immutable registration is written before any helper or app starts.
    metadata = {"schemaVersion": 2, "metric": "synthetic-key-to-WindowServer-frame", "diagnostic": False,
                "profile": args.profile, "hardware": command_result(["/usr/sbin/sysctl", "hw.model", "hw.memsize", "hw.physicalcpu", "hw.logicalcpu", "machdep.cpu.brand_string"]),
                "adapter": "comparative-four-pane", "targetPerPane": GRID, "panes": 4,
                "pythonExecutable": sys.executable, "workerSourcePath": str(HERE / "four_pane_worker.py"),
                "hostMonotonicClock": vars(time.get_clock_info("monotonic")),
                "hostPerformanceClock": vars(time.get_clock_info("perf_counter")),
                "busyPayloadPeriod": {"hex": PAYLOAD_PERIOD.hex(), "sha256": hashlib.sha256(PAYLOAD_PERIOD).hexdigest()},
                "requestedBlocks": args.blocks, "samplesPerBlock": args.samples, "settleSeconds": 5,
                "busyBytesPerSecondPerPane": 4_000_000, "offeredQuantumBytes": 40_000, "offeredPeriodNs": 10_000_000,
                "loadBounds": {"wholeInterval": [.98, 1.02], "oneSecond": [.9, 1.1], "boundaryBytesMaximum": 80_000},
                "binaries": {name: binary_metadata(getattr(args, name + "_bin")) for name in ("cmdy", "ghostty")},
                "helpers": {name: {"path": str(getattr(args, name)), "sha256": sha256(getattr(args, name))}
                            for name in ("window_helper", "setup_helper", "observer")},
                "toolingSHA256": {name: sha256(HERE / name) for name in sorted(REQUIRED_TOOLING)},
                "bindings": ACTIONS, "status": "preregistered"}
    if any(metadata[key]["implementation"] != "mach_absolute_time()"
           for key in ("hostMonotonicClock", "hostPerformanceClock")):
        raise RuntimeError("host and native event clocks do not share the registered domain")
    # Retain the exact script inputs and inert helper bytes before native work.
    for relative, expected in metadata["toolingSHA256"].items():
        destination = output / "tooling" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / relative, destination)
        if sha256(destination) != expected:
            raise RuntimeError("tooling changed before launch: " + relative)
    for name, helper in metadata["helpers"].items():
        destination = output / "helpers" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(helper["path"], destination)
        if sha256(destination) != helper["sha256"]:
            raise RuntimeError("helper changed before launch: " + name)
    atomic_json(output / "metadata.json", metadata)
    machine = window_command(args.window_helper, "probe", 14)
    if not all(machine.get(key) for key in ("accessibilityTrusted", "screenCaptureAuthorized", "postEventAuthorized")):
        raise RuntimeError("existing native permissions required; no prompt was opened")
    initial_power = power_snapshot()
    conditions = retained.ConditionGuard(initial_power)
    metadata.update(machine=machine, fontSHA256=sha256(Path(machine["font"]["file"])), powerBefore=initial_power)
    atomic_json(output / "metadata.json", metadata)
    atomic_json(output / "machine.json", {"machine": machine, "fontSHA256": metadata["fontSHA256"]})
    summaries, reference_display = [], None
    try:
        for block in range(args.blocks):
            for terminal in block_order(block):
                run = output / f"{block:02d}-{terminal}"
                token = uuid.uuid4().hex
                with tempfile.TemporaryDirectory(prefix="cmdy-4p-", dir="/private/tmp") as socket_directory:
                    command = [sys.executable, str(HERE / "four_pane_worker.py"), "--output", str(run / "fixture"),
                               "--socket-directory", socket_directory, "--run-token", token, "--timeout", "120"]
                    with TerminalSession(options, args.window_helper, terminal, run, target_grid=(120, 36),
                                         fixture_command=command, ready_path=run / "fixture/ready.json") as session:
                        configure(session)
                        atomic_json(run / "config-before-launch.json", {
                            str(path.relative_to(run)): sha256(path) for path in (session.config_path, run / "zsh/.zshenv",
                            *([run / "cmdy-config/keybindings.json"] if terminal == "cmdy" else []))})
                        layout = Layout(session, args.setup_helper, token)
                        session.launch()
                        validate_launch(run, metadata, json.loads((run / "launch.json").read_text()),
                                        lambda path: json.loads(path.read_text()))
                        try:
                            session.window(activate=True)
                            layout.create()
                            layout.fit()
                            layout.ensure_focus(0)
                            landmarks = layout.helper("landmarks", output=run / "layout.png")
                            region = validate_rectangles(landmarks["rectangles"])
                            atomic_json(run / "landmarks.json", {**landmarks, "observerRegion": region,
                                                              "pngSHA256": sha256(run / "layout.png")})
                            before = session.window()
                            display = before["windows"][0]["displayID"]
                            if reference_display is None:
                                reference_display = display
                            if display != reference_display:
                                raise RuntimeError("comparison moved to another display")
                            start = time.monotonic_ns() + 500_000_000
                            arm = [control(worker, token, "arm", startNs=start) for worker in layout.workers.values()]
                            atomic_json(run / "armed.json", arm)
                            until = time.monotonic() + 5
                            while True:
                                starting = layout.states()
                                if all(starting[slot]["mode"] == "active" and starting[slot]["completedBytes"] > 0
                                       for slot in (1, 2, 3)):
                                    atomic_json(run / "load-started.json", {
                                        "confirmedMonotonicNS": time.monotonic_ns(), "states": starting})
                                    break
                                if time.monotonic() >= until:
                                    raise RuntimeError("busy producers did not begin writing before settling")
                                time.sleep(.01)
                            time.sleep(args.settle_seconds)
                            states_before = layout.states()
                            if not all(state["grid"] == GRID and state["mode"] == "active" for state in states_before.values()):
                                raise RuntimeError("four grids or streams not active before observation")
                            before = session.window()
                            atomic_json(run / "window-before.json", before)
                            power_before = power_snapshot()
                            conditions.check_power(power_before)
                            observer_command = [str(args.observer), "--pid", str(session.app_pid),
                                "--window", str(before["windows"][0]["windowID"]), "--output", str(run / "latency.json"),
                                "--samples", str(args.samples), "--fps", "120", "--marker-mode", "local-row",
                                "--region", ",".join(str(region[key]) for key in ("x", "y", "width", "height"))]
                            observation = {"startedMonotonicNs": time.monotonic_ns(), "command": observer_command}
                            result = retained.run_observer(observer_command, run / "observer-process.json", timeout=60)
                            observation.update(finishedMonotonicNs=time.monotonic_ns(), returncode=result.returncode,
                                               stdout=result.stdout, stderr=result.stderr)
                            atomic_json(run / "observation.json", observation)
                            after = session.window()
                            states_after = layout.states()
                            power_after = power_snapshot()
                            atomic_json(run / "power.json", {"before": power_before, "after": power_after})
                            atomic_json(run / "states.json", {"before": states_before, "after": states_after})
                            atomic_json(run / "window-after.json", after)
                            conditions.check_power(power_after)
                            if result.returncode or before["windows"] != after["windows"]:
                                raise RuntimeError("observer failed or owned window changed")
                            latency = json.loads((run / "latency.json").read_text())
                            conditions.check_observer(latency)
                            validate_latency(latency, session.app_pid, before["windows"][0]["windowID"],
                                             region, args.samples)
                        finally:
                            cleanup = layout.cleanup()
                        if cleanup["errors"] or len(cleanup["workers"]) != 4:
                            raise RuntimeError("four-worker cleanup did not complete before app cleanup")
                        final = cleanup["workers"]
                        fixture = run / "fixture"
                        validate_exit_barrier(final, json.loads((fixture / "exit-release.json").read_text()),
                            {str(slot): json.loads((fixture / f"exit-{slot}.json").read_text()) for slot in final},
                            {str(slot): sha256(fixture / f"final-{slot}.json") for slot in final},
                            sha256(fixture / "exit-release.json"))
                        validate_marker(final[0], latency, observation, args.samples)
                        validate_response_clocks(latency, observation, final[0]["received"])
                        for slot in (1, 2, 3):
                            validate_settling(final[slot], observation)
                        load = {slot: validate_busy(final[slot], observation) for slot in (1, 2, 3)}
                        entry = {"block": block, "terminal": terminal, "status": "valid", "summaryMs": latency["summaryMs"],
                                 "gridPerPane": GRID, "load": load, "directory": str(run)}
                        atomic_json(run / "qualification.json", entry)
                        summaries.append(entry)
                        atomic_json(output / "summary.json", {"complete": False, "runs": summaries})
    except BaseException as error:
        atomic_json(output / "summary.json", {"complete": False, "runs": summaries, "error": str(error)})
        raise
    for relative, expected in metadata["toolingSHA256"].items():
        if sha256(HERE / relative) != expected:
            raise RuntimeError("tooling changed during comparison: " + relative)
    for name, helper in metadata["helpers"].items():
        if sha256(Path(helper["path"])) != helper["sha256"]:
            raise RuntimeError("helper changed during comparison: " + name)
    for name in ("cmdy", "ghostty"):
        if sha256(getattr(args, name + "_bin")) != metadata["binaries"][name]["sha256"]:
            raise RuntimeError("app executable changed during comparison: " + name)
    final_power = power_snapshot()
    conditions.check_power(final_power)
    metadata.update(powerAfter=final_power, status="complete")
    atomic_json(output / "metadata.json", metadata)
    atomic_json(output / "summary.json", {"complete": True, "metric": metadata["metric"], "runs": summaries,
                "limitations": ["Synthetic event to scaled ScreenCaptureKit frame; not physical input-to-photon",
                                 "Marker workload under three paced ASCII panes; not Vim, paste, or Unicode parity",
                                 "Paired confidence intervals must be computed separately before any parity claim"]})


if __name__ == "__main__":
    with retained.interruption_guard():
        main()
