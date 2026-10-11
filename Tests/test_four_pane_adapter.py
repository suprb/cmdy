"""Synthetic adversarial records; these tests are never performance evidence."""
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import shlex
import tempfile
import termios
import tty
import unittest

from four_pane_evidence import GRID, PAYLOAD_PERIOD, validate_busy, validate_latency, validate_rectangles, descriptor_flags_match
from four_pane_parity_evidence import load_four_pane_evidence
from four_pane_contract import ACTIONS, REQUIRED_TOOLING, expected_config, expected_bindings
from competitive_bench import launch_environment
from test_four_pane import ideal_record
from four_pane_worker import restore_terminal
from terminal_bench_pacing import PACING_POLICY


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def latency_fixture(pid=100, window=500):
    region = {"x": .074, "y": .1204, "width": .342, "height": .3192}
    samples = []
    for sequence in range(1, 41):
        before = 2_000_000_000 + sequence * 100_000_000
        samples.append({"sequence": sequence, "postBeforeTicks": before,
            "postAfterTicks": before + 10_000, "validationFinishedTicks": before + 2_300_000,
            "frame": {"displayTicks": before + 2_000_000, "callbackTicks": before + 1_900_000,
                      "matchingPixels": 128}, "eventToFrameMs": 2.0, "captureCallbackLagMs": -.1})
    return {"schemaVersion": 3, "metric": "synthetic-key-to-WindowServer-frame", "markerMode": "local-row",
            "pid": pid, "windowID": window,
            "clockSource": "mach_absolute_time",
            "timebase": {"numer": 1, "denom": 1}, "samples": samples,
            "summaryMs": {"median": 2.0, "p95": 2.0, "max": 2.0},
            "capture": {"width": 1280, "height": 900, "requestedFPS": 120,
                        "completeFrames": 800, "region": region},
            "environment": {"thermalState": 0, "lowPowerMode": False, "os": "synthetic"}}


def complete_fixture(root, profile="matched", blocks=2):
    # By default two pairs exercise raw acceptance; gate tests can supply all six.
    power = {"signature": {"source": "AC Power", "settings": "synthetic stable settings"}}
    machine = {"accessibilityTrusted": True, "screenCaptureAuthorized": True, "postEventAuthorized": True,
               "font": {"name": "synthetic Menlo"}, "displays": [{"id": 1}]}
    metadata = {"schemaVersion": 2, "adapter": "comparative-four-pane", "status": "complete",
        "metric": "synthetic-key-to-WindowServer-frame", "diagnostic": False, "profile": profile,
        "panes": 4, "targetPerPane": GRID, "settleSeconds": 5, "busyBytesPerSecondPerPane": 4_000_000,
        "offeredQuantumBytes": 40_000, "offeredPeriodNs": 10_000_000,
        "loadBounds": {"wholeInterval": [.98, 1.02], "oneSecond": [.9, 1.1], "boundaryBytesMaximum": 80_000},
        "samplesPerBlock": 40, "requestedBlocks": blocks,
        "binaries": {"cmdy": {"sha256": "a" * 64, "path": "/synthetic/cmdy"}, "ghostty": {"sha256": "b" * 64, "path": "/synthetic/ghostty"}},
        "pythonExecutable": "/synthetic/python3", "workerSourcePath": "/synthetic/four_pane_worker.py",
        "bindings": ACTIONS,
        "toolingSHA256": {}, "helpers": {}, "powerBefore": power, "powerAfter": power,
        "hostMonotonicClock": {"implementation": "mach_absolute_time()"},
        "hostPerformanceClock": {"implementation": "mach_absolute_time()"},
        "busyPayloadPeriod": {"hex": PAYLOAD_PERIOD.hex(), "sha256": hashlib.sha256(PAYLOAD_PERIOD).hexdigest()},
        "machine": machine, "fontSHA256": "c" * 64, "hardware": {"stdout": "synthetic machine"}}
    for name in ("window_helper", "setup_helper", "observer"):
        path = root / "helpers" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"synthetic inert helper")
        metadata["helpers"][name] = {"path": "unused", "sha256": sha(path)}
    for relative in REQUIRED_TOOLING:
        path = root / "tooling" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"synthetic inert source")
        metadata["toolingSHA256"][relative] = sha(path)
    save(root / "metadata.json", metadata)
    save(root / "machine.json", {"machine": machine, "fontSHA256": metadata["fontSHA256"]})
    entries = []
    rectangles = [{"slot": i, "x": .02 + (i % 2) * .5, "y": .07 + (i // 2) * .46,
                   "width": .45, "height": .42, "fillFraction": .999} for i in range(4)]
    region = validate_rectangles(rectangles)
    observation = {"startedMonotonicNs": 7_005_000_000, "finishedMonotonicNs": 12_005_000_000, "returncode": 0}
    for block in range(blocks):
        order = ("cmdy", "ghostty") if block % 2 == 0 else ("ghostty", "cmdy")
        for position, terminal in enumerate(order):
            run = root / f"{block:02d}-{terminal}"
            run.mkdir()
            pid, window_id = 100 + block * 20 + position * 5, 500 + block * 2 + position
            config = run / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
            config.parent.mkdir(exist_ok=True)
            cwd = Path(f"/private/tmp/cmdy-drain-synthetic-{pid}/work")
            domain, token = f"com.cmdy.bench.{pid:032x}", f"{pid:032x}"
            config.write_text(expected_config(terminal, profile, cwd))
            command = [metadata["pythonExecutable"], metadata["workerSourcePath"], "--output", str(run / "fixture"),
                       "--socket-directory", f"/private/tmp/cmdy-4p-synthetic-{pid}", "--run-token", token, "--timeout", "120"]
            zsh = run / "zsh/.zshenv"
            zsh.parent.mkdir()
            zsh.write_text("unsetopt RCS\nexec " + shlex.join(command) + "\n")
            inputs = {str(config.relative_to(run)): sha(config), "zsh/.zshenv": sha(zsh)}
            if terminal == "cmdy":
                bindings = run / "cmdy-config/keybindings.json"
                save(bindings, expected_bindings())
                inputs["cmdy-config/keybindings.json"] = sha(bindings)
            argv = [metadata["binaries"][terminal]["path"]]
            if terminal == "ghostty":
                argv += ["--config-default-files=false", f"--config-file={config}"]
            save(run / "launch.json", {"appPID": pid, "profile": profile, "terminal": terminal,
                 "config": str(config), "cwd": str(cwd), "defaultsDomain": domain, "fixtureCommand": command,
                 "arguments": argv, "environment": launch_environment({}, run, cwd, domain),
                 "configSHA256": sha(config), "startedMonotonicNS": 100_000_000})
            save(run / "config-before-launch.json", inputs)
            save(run / "power.json", {"before": power, "after": power})
            window = {"windowID": window_id, "ownerPID": pid, "onScreen": True, "displayID": 1,
                      "bounds": {"x": 0, "y": 0, "width": 1200, "height": 800}}
            state = {"ok": True, "pid": pid, "frontmostPID": pid, "windows": [window]}
            save(run / "window-before.json", state)
            save(run / "window-after.json", state)
            (run / "layout.png").write_bytes(b"synthetic inert raster identity; not a native screenshot")
            save(run / "landmarks.json", {"rectangles": rectangles, "observerRegion": region,
                                          "pngSHA256": sha(run / "layout.png")})
            latency = latency_fixture(pid, window_id)
            latency["capture"]["region"] = region
            for sample in latency["samples"]:
                for key in ("postBeforeTicks", "postAfterTicks", "validationFinishedTicks"):
                    sample[key] += 5_000_000_000
                for key in ("displayTicks", "callbackTicks"):
                    sample["frame"][key] += 5_000_000_000
            save(run / "latency.json", latency)
            save(run / "observation.json", observation)
            workers, readiness, starts, original_processes = {}, [], {}, {}
            for slot in range(4):
                worker = ideal_record(count=1400)
                worker.update(pid=pid * 10 + slot, slot=slot, ttyPath=f"/dev/synthetic-{slot}",
                              runToken=token, startedMonotonicNs=500_000_000,
                              pacingSourceSHA256=metadata["toolingSHA256"]["terminal_bench_pacing.py"],
                              pacingPolicy=PACING_POLICY, pacingTimerClosed=True, exitBarrierRequested=True,
                              workerSourceSHA256=metadata["toolingSHA256"]["four_pane_worker.py"])
                worker["cleanup"].update(stdinRestored=True, unexpectedInputBytes=0, modeDifferenceIndices=[],
                    ttyFlagsOriginal=[1, 2, 3, 4], ttyFlagsRestored=[1, 2, 3, 4],
                    descriptorFlagsOriginal={"0": 2, "1": 2}, descriptorFlagsRestored={"0": 2, "1": 2})
                if slot == 0:
                    worker["received"] = [{"sequence": s["sequence"], "byte": 97,
                        "receivedMonotonicNs": s["postBeforeTicks"] + 500_000,
                        "repliedMonotonicNs": s["postBeforeTicks"] + 700_000, "replied": True}
                        for s in latency["samples"]]
                workers[str(slot)] = worker
                ready = {k: worker[k] for k in
                        ("pid", "slot", "ttyPath", "runToken", "startedMonotonicNs", "workerSourceSHA256",
                         "pacingSourceSHA256", "pacingPolicy")}
                save(run / f"fixture/worker-{slot}.json", ready)
                save(run / f"fixture/final-{slot}.json", worker)
                readiness.append(ready)
                starts[str(worker["pid"])] = f"synthetic start {worker['pid']}"
                original_processes[str(slot)] = {"pid": worker["pid"], "startIdentity": starts[str(worker["pid"])], "exited": True}
            save(run / "setup.json", [{"event": "workers", "expectedCount": 4, "workers": readiness, "startIdentities": starts}])
            save(run / "worker-cleanup.json", {"errors": [], "workers": workers, "originalProcesses": original_processes})
            states = {str(slot): {"grid": GRID, "mode": "active"} for slot in range(4)}
            save(run / "states.json", {"before": states, "after": states})
            entry = {"status": "valid", "block": block, "terminal": terminal, "gridPerPane": GRID,
                     "summaryMs": latency["summaryMs"], "directory": str(run),
                     "load": {slot: validate_busy(workers[slot], observation) for slot in ("1", "2", "3")}}
            save(run / "qualification.json", entry)
            save(run / "cleanup.json", {"appPID": pid, "returncode": -15})
            entries.append(entry)
            offset = (block * 2 + position) * 20_000_000_000
            def shifted(value, key=""):
                if isinstance(value, dict):
                    return {k: shifted(v, k) for k, v in value.items()}
                if isinstance(value, list):
                    if key == "offers":
                        return [[v[0], v[1] + offset, v[2] + offset, *v[3:]] for v in value]
                    if key == "writes":
                        return [[*v[:3], v[3] + offset, v[4] + offset] for v in value]
                    return [shifted(v) for v in value]
                if type(value) is int and (key.endswith("MonotonicNs") or key.endswith("MonotonicNS")
                        or key.endswith("Ticks") or key in ("activeStartNs", "startNs", "finishNs")):
                    return value + offset
                return value
            for path in run.rglob("*.json"):
                record = json.loads(path.read_text())
                if path.name == "launch.json":
                    # This clock is named startedMonotonicNS and is shifted above.
                    pass
                save(path, shifted(record))
            final_workers = {str(slot): json.loads((run / f"fixture/final-{slot}.json").read_text())
                             for slot in range(4)}
            released = max(w["stoppedMonotonicNs"] for w in final_workers.values()) + 10_000_000
            release = {"runToken": token, "finalRecordsReadyMonotonicNs": released - 1_000_000,
                       "releaseMonotonicNs": released,
                       "workerPIDs": {slot: w["pid"] for slot, w in final_workers.items()},
                       "finalSHA256": {slot: sha(run / f"fixture/final-{slot}.json") for slot in final_workers}}
            save(run / "fixture/exit-release.json", release)
            for slot, w in final_workers.items():
                save(run / f"fixture/exit-{slot}.json", {
                    "pid": w["pid"], "slot": int(slot), "runToken": token, "status": "released",
                    "releaseMonotonicNs": released, "exitingMonotonicNs": released + 1_000_000,
                    "releaseSHA256": sha(run / "fixture/exit-release.json")})
            entries[-1] = json.loads((run / "qualification.json").read_text())
    save(root / "summary.json", {"complete": True, "metric": metadata["metric"], "runs": entries})


class ClockEvidenceTests(unittest.TestCase):
    def test_native_integer_bounds_and_boolean_clocks_fail_closed(self):
        for mutation in (
            lambda r: r["timebase"].__setitem__("numer", 2**32),
            lambda r: r["timebase"].__setitem__("denom", True),
            lambda r: r["samples"][0].__setitem__("validationFinishedTicks", 2**64),
            lambda r: r["samples"][0].__setitem__("postBeforeTicks", True),
            lambda r: r.__setitem__("clockSource", "wall-clock"),
            lambda r: r.__setitem__("schemaVersion", 2),
        ):
            report = latency_fixture()
            mutation(report)
            with self.assertRaises(ValueError):
                validate_latency(report, 100, 500, report["capture"]["region"], 40)

    def test_summary_and_sample_count_must_reconcile(self):
        for mutation in (
            lambda r: r["samples"].pop(),
            lambda r: r["summaryMs"].__setitem__("median", float("nan")),
            lambda r: r["summaryMs"].__setitem__("p95", 1.0),
        ):
            report = latency_fixture()
            mutation(report)
            with self.assertRaises(ValueError):
                validate_latency(report, 100, 500, report["capture"]["region"], 40)

    def test_future_display_relative_to_callback_keeps_first_frame(self):
        report = latency_fixture()
        self.assertEqual(validate_latency(report, 100, 500, report["capture"]["region"], 40), [2.] * 40)

    def test_outside_interval_or_changed_endpoint_fails(self):
        for mutation in (
            lambda s: s.__setitem__("validationFinishedTicks", s["frame"]["displayTicks"] - 1),
            lambda s: s["frame"].__setitem__("callbackTicks", s["postBeforeTicks"] - 1),
            lambda s: s.__setitem__("eventToFrameMs", 1.5),
            lambda s: s.__setitem__("captureCallbackLagMs", .1),
            lambda s: s["frame"].__setitem__("matchingPixels", 1),
        ):
            report = latency_fixture()
            mutation(report["samples"][7])
            with self.assertRaises(ValueError):
                validate_latency(report, 100, 500, report["capture"]["region"], 40)


class RestorationTests(unittest.TestCase):
    def test_kernel_write_status_does_not_hide_changed_descriptor_options(self):
        self.assertTrue(descriptor_flags_match(2, 65538, "darwin"))
        self.assertFalse(descriptor_flags_match(2, 65538))
        self.assertFalse(descriptor_flags_match(65538, 2, "darwin"))
        self.assertFalse(descriptor_flags_match(2, 65538 | os.O_NONBLOCK, "darwin"))
        self.assertFalse(descriptor_flags_match(2 | os.O_NONBLOCK, 65538, "darwin"))
        self.assertFalse(descriptor_flags_match(2, 65538 | os.O_APPEND, "darwin"))
        self.assertFalse(descriptor_flags_match(2, None, "darwin"))

    def test_independent_descriptor_flags_and_complete_terminal_mode_restore(self):
        master, slave = pty.openpty()
        output = os.open(os.ttyname(slave), os.O_WRONLY | os.O_NONBLOCK)
        try:
            original = termios.tcgetattr(slave)
            flags = {str(fd): fcntl.fcntl(fd, fcntl.F_GETFL) for fd in (slave, output)}
            tty.setraw(slave)
            os.set_blocking(slave, False)
            os.set_blocking(output, True)
            os.write(output, b"fixture output")
            self.assertEqual(os.read(master, 14), b"fixture output")
            result = restore_terminal(slave, output, original, flags)
            self.assertTrue(result["termiosRestored"], result)
            self.assertTrue(result["stdinRestored"] and result["stdoutRestored"], result)
            self.assertEqual(termios.tcgetattr(slave), original)
            for fd in (slave, output):
                actual = fcntl.fcntl(fd, fcntl.F_GETFL)
                self.assertEqual(actual, result["descriptorFlagsRestored"][str(fd)])
                self.assertTrue(descriptor_flags_match(flags[str(fd)], actual, result["descriptorStatusPlatform"]))
            self.assertEqual(result["unexpectedInputBytes"], 0)
        finally:
            os.close(output)
            os.close(slave)
            os.close(master)


class RawAdapterTests(unittest.TestCase):
    def test_profile_isolation_and_required_manifests_are_enforced(self):
        for mutation in ("font-with-rehashed-config", "ghostty-default-config", "empty-environment",
                         "empty-tooling", "empty-helpers", "empty-config-manifest"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(prefix="cmdy-4p-raw-test-") as directory:
                root = Path(directory)
                complete_fixture(root)
                run = root / "00-cmdy"
                if mutation == "font-with-rehashed-config":
                    config = run / "cmdy-config/config"
                    config.write_text(config.read_text().replace("font-size = 14", "font-size = 12"))
                    launch = json.loads((run / "launch.json").read_text())
                    launch["configSHA256"] = sha(config)
                    save(run / "launch.json", launch)
                    inputs = json.loads((run / "config-before-launch.json").read_text())
                    inputs["cmdy-config/config"] = sha(config)
                    save(run / "config-before-launch.json", inputs)
                elif mutation == "ghostty-default-config":
                    path = root / "00-ghostty/launch.json"
                    launch = json.loads(path.read_text())
                    launch["arguments"].remove("--config-default-files=false")
                    save(path, launch)
                elif mutation == "empty-environment":
                    path = run / "launch.json"
                    launch = json.loads(path.read_text())
                    launch["environment"] = {}
                    save(path, launch)
                elif mutation == "empty-config-manifest":
                    save(run / "config-before-launch.json", {})
                else:
                    path = root / "metadata.json"
                    metadata = json.loads(path.read_text())
                    metadata["toolingSHA256" if mutation == "empty-tooling" else "helpers"] = {}
                    save(path, metadata)
                with self.assertRaises(ValueError):
                    load_four_pane_evidence(root)

    def test_ticks_payload_and_actual_settling_cannot_escape_the_load_interval(self):
        for mutation in ("shift-native-clocks", "wrong-payload", "late-first-offer"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(prefix="cmdy-4p-raw-test-") as directory:
                root = Path(directory)
                complete_fixture(root)
                run = root / "00-cmdy"
                if mutation == "shift-native-clocks":
                    path = run / "latency.json"
                    report = json.loads(path.read_text())
                    for sample in report["samples"]:
                        for key in ("postBeforeTicks", "postAfterTicks", "validationFinishedTicks"):
                            sample[key] += 100_000_000_000
                        for key in ("displayTicks", "callbackTicks"):
                            sample["frame"][key] += 100_000_000_000
                    save(path, report)
                else:
                    path = run / "worker-cleanup.json"
                    cleanup = json.loads(path.read_text())
                    worker = cleanup["workers"]["1"]
                    if mutation == "wrong-payload":
                        worker["payloadPeriodHex"] = b"different payload".hex()
                        worker["payloadPeriodSHA256"] = hashlib.sha256(b"different payload").hexdigest()
                    else:
                        for offer in worker["offers"]:
                            offer[2] += 2_000_000_000
                        for write in worker["writes"]:
                            write[3] += 2_000_000_000
                            write[4] += 2_000_000_000
                        worker["stoppedMonotonicNs"] += 2_000_000_000
                    save(path, cleanup)
                    save(run / "fixture/final-1.json", worker)
                with self.assertRaises(ValueError):
                    load_four_pane_evidence(root)

    def test_both_profiles_reconstruct_and_policy_keeps_minimum_blocks(self):
        import parity_gate
        policy = json.loads(Path(__file__).with_name('parity-policy.json').read_text())
        for profile in ("matched", "cmdy-defaults"):
            with tempfile.TemporaryDirectory(prefix="cmdy-4p-raw-test-") as directory:
                root = Path(directory)
                complete_fixture(root, profile)
                result = load_four_pane_evidence(root)
                self.assertEqual(result["case"], "input/four-pane")
                self.assertEqual(result["profile"], profile)
                self.assertEqual(len(result["blocks"]), 2)
                self.assertEqual(parity_gate.assess_ratios([.8, .8], policy)["status"], "insufficient-samples")
                gate = parity_gate.evaluate([root], policy, {"cmdy": "a" * 64, "ghostty": "b" * 64})
                self.assertEqual(gate["invalidEvidence"], [])
                self.assertFalse(gate["passed"])
                counts = {status: sum(r["status"] == status for r in gate["results"])
                          for status in ("insufficient-samples", "not-measured")}
                self.assertEqual(counts, {"insufficient-samples": 2, "not-measured": 138})

    def test_altered_load_clock_power_source_or_geometry_cannot_pass(self):
        cases = [
            ("00-cmdy/latency.json", lambda r: r["samples"][3].__setitem__("eventToFrameMs", .001)),
            ("00-cmdy/qualification.json", lambda r: r["load"]["1"]["wholeInterval"].__setitem__("lowerBytes", 0)),
            ("00-cmdy/power.json", lambda r: r["after"]["signature"].__setitem__("source", "Battery Power")),
            ("00-cmdy/window-after.json", lambda r: r["windows"][0]["bounds"].__setitem__("width", 1199)),
            ("00-cmdy/worker-cleanup.json", lambda r: r["workers"]["2"]["cleanup"].__setitem__("termiosRestored", False)),
            ("metadata.json", lambda r: r.__setitem__("busyBytesPerSecondPerPane", 1_000_000)),
            ("00-cmdy/worker-cleanup.json", lambda r: r["originalProcesses"]["1"].__setitem__("exited", False)),
            ("00-cmdy/setup.json", lambda r: r[0]["startIdentities"].__setitem__("1000", "another process")),
            ("00-cmdy/fixture/exit-1.json", lambda r: r.__setitem__("status", "release-timeout")),
            ("00-cmdy/fixture/exit-release.json", lambda r: r.__setitem__("releaseMonotonicNs", 0)),
            ("00-cmdy/fixture/exit-release.json", lambda r: r["finalSHA256"].__setitem__("2", "0" * 64)),
        ]
        for relative, mutation in cases:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory(prefix="cmdy-4p-raw-test-") as directory:
                root = Path(directory)
                complete_fixture(root)
                path = root / relative
                record = json.loads(path.read_text())
                mutation(record)
                save(path, record)
                with self.assertRaises(ValueError):
                    load_four_pane_evidence(root)

    def test_source_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="cmdy-4p-raw-test-") as directory:
            root = Path(directory)
            complete_fixture(root)
            (root / "tooling/four_pane_bench.py").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "tooling"):
                load_four_pane_evidence(root)


if __name__ == '__main__':
    unittest.main()
