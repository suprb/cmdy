"""Read-only four-pane evidence adapter. Never launches apps or retained programs."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import re

from four_pane_evidence import (GRID, PAYLOAD_PERIOD, require, validate_busy, validate_latency,
                                validate_marker, validate_rectangles, validate_response_clocks, validate_settling,
                                descriptor_flags_match, validate_exit_barrier)
from four_pane_contract import ACTIONS, REQUIRED_TOOLING, validate_launch
from terminal_bench_pacing import PACING_POLICY


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def power_signature(record):
    signature = record.get("signature", {})
    require(signature.get("source") in ("AC Power", "Battery Power")
            and isinstance(signature.get("settings"), str) and signature["settings"],
            "missing power source or settings")
    return signature


def owned_window(record):
    require(record.get("ok") is True and record.get("pid") == record.get("frontmostPID"),
            "owned app was not frontmost")
    windows = record.get("windows", [])
    require(len(windows) == 1 and windows[0].get("onScreen") is True
            and windows[0].get("ownerPID") == record["pid"], "owned window unavailable")
    return windows[0]


def load_four_pane_evidence(directory, expected_binaries=None):
    directory = Path(directory).resolve()
    metadata, summary = read(directory / "metadata.json"), read(directory / "summary.json")
    require(not (directory / "failure.json").exists() and metadata.get("status") == "complete"
            and summary.get("complete") is True and "error" not in summary,
            "incomplete four-pane comparison")
    require(metadata.get("schemaVersion") == 2 and metadata.get("adapter") == "comparative-four-pane"
            and metadata.get("metric") == summary.get("metric") == "synthetic-key-to-WindowServer-frame"
            and metadata.get("diagnostic") is False, "wrong comparative adapter or metric")
    require(metadata.get("panes") == 4 and metadata.get("targetPerPane") == GRID
            and metadata.get("settleSeconds") == 5
            and metadata.get("busyBytesPerSecondPerPane") == 4_000_000
            and metadata.get("offeredQuantumBytes") == 40_000
            and metadata.get("offeredPeriodNs") == 10_000_000
            and metadata.get("loadBounds") == {"wholeInterval": [.98, 1.02],
                "oneSecond": [.9, 1.1], "boundaryBytesMaximum": 80_000}, "workload contract changed")
    profile = metadata.get("profile")
    require(profile in ("matched", "cmdy-defaults"), "unknown profile")
    require(metadata.get("hostMonotonicClock", {}).get("implementation") == "mach_absolute_time()",
            "host and native event clocks are not established in the same domain")
    require(metadata.get("hostPerformanceClock", {}).get("implementation") == "mach_absolute_time()",
            "process launch and observation clocks do not share the registered domain")
    require(metadata.get("busyPayloadPeriod") == {"hex": PAYLOAD_PERIOD.hex(),
            "sha256": hashlib.sha256(PAYLOAD_PERIOD).hexdigest()}, "unregistered payload period")
    count, pairs = metadata.get("samplesPerBlock"), metadata.get("requestedBlocks")
    require(type(count) is int and count >= 40 and type(pairs) is int
            and pairs > 0 and pairs % 2 == 0, "unequal or incomplete paired design")
    binaries = {name: metadata["binaries"][name]["sha256"] for name in ("cmdy", "ghostty")}
    require(all(re.fullmatch("[0-9a-f]{64}", value) for value in binaries.values()), "missing binary hashes")
    if expected_binaries is not None:
        require(binaries == expected_binaries, "binary version differs from pinned candidate/comparator")
    require(REQUIRED_TOOLING <= set(metadata.get("toolingSHA256", {})), "missing required source identities")
    require(set(metadata.get("helpers", {})) == {"window_helper", "setup_helper", "observer"},
            "missing helper identities")
    require(metadata.get("bindings") == {key: list(value) for key, value in ACTIONS.items()}, "binding contract changed")
    for relative, expected in metadata["toolingSHA256"].items():
        parts = PurePosixPath(relative)
        require(not parts.is_absolute() and ".." not in parts.parts
                and digest(directory / "tooling" / relative) == expected, "frozen tooling differs")
    for name, helper in metadata["helpers"].items():
        require(name in ("window_helper", "setup_helper", "observer")
                and digest(directory / "helpers" / name) == helper["sha256"], "frozen helper differs")
    power = power_signature(metadata["powerBefore"])
    require(power_signature(metadata["powerAfter"]) == power, "final power changed")
    machine = metadata["machine"]
    require(read(directory / "machine.json") == {"machine": machine, "fontSHA256": metadata["fontSHA256"]},
            "machine or font record differs")
    require(all(machine.get(key) is True for key in
                ("accessibilityTrusted", "screenCaptureAuthorized", "postEventAuthorized")),
            "native permissions were unavailable")
    require(re.fullmatch("[0-9a-f]{64}", metadata.get("fontSHA256", "")) is not None,
            "font bytes unidentified")
    paths = sorted(p for p in directory.iterdir() if p.is_dir() and re.fullmatch(r"\d{2}-(cmdy|ghostty)", p.name))
    require(len(paths) == pairs * 2 and len(summary.get("runs", [])) == pairs * 2, "missing raw paired runs")
    blocks, orders, display, environment, timebase = {}, {}, None, None, None
    domains, working_directories = set(), set()
    lifetimes = []
    for run in paths:
        block_text, terminal = run.name.split("-")
        block = int(block_text)
        launch = read(run / "launch.json")
        require(launch.get("terminal") == terminal and launch.get("profile") == profile
                and "CMDY_FRAME_TRACE" not in launch["environment"], "launch identity or trace mismatch")
        isolated = validate_launch(run, metadata, launch, read)
        require(isolated["domain"] not in domains and isolated["cwd"] not in working_directories,
                "owned session isolation was reused")
        domains.add(isolated["domain"])
        working_directories.add(isolated["cwd"])
        configuration = run / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
        require(digest(configuration) == launch["configSHA256"], "launch configuration changed")
        for relative, expected in read(run / "config-before-launch.json").items():
            parts = PurePosixPath(relative)
            require(not parts.is_absolute() and ".." not in parts.parts
                    and digest(run / relative) == expected, "fixture configuration changed")
        conditions = read(run / "power.json")
        require(all(power_signature(conditions[phase]) == power for phase in ("before", "after")),
                "power changed during paired run")
        before, after = owned_window(read(run / "window-before.json")), owned_window(read(run / "window-after.json"))
        require(before == after and before["ownerPID"] == launch["appPID"], "owned geometry changed")
        if display is None:
            display = before["displayID"]
        require(before["displayID"] == display, "comparison moved displays")
        landmarks = read(run / "landmarks.json")
        require(digest(run / "layout.png") == landmarks["pngSHA256"], "layout pixels changed")
        region = validate_rectangles(landmarks["rectangles"])
        require(landmarks["observerRegion"] == region, "capture region is not derived from pane layout")
        latency = read(run / "latency.json")
        values = validate_latency(latency, launch["appPID"], before["windowID"], region, count)
        current_environment = latency.get("environment", {})
        require(type(current_environment.get("lowPowerMode")) is bool
                and current_environment.get("thermalState") == 0, "thermal or power condition unavailable")
        dimensions = (latency["capture"]["width"], latency["capture"]["height"])
        if environment is None:
            environment, timebase = current_environment, latency["timebase"]
        require(current_environment == environment and latency["timebase"] == timebase,
                "native clock or OS/power environment changed")
        # Different app chrome can change total window height; each derived pane
        # must still satisfy identical TTY geometry and the same marker decoder.
        require(all(type(x) is int and x > 0 for x in dimensions), "invalid capture extent")
        observation = read(run / "observation.json")
        require(observation.get("returncode") == 0, "observer failed")
        cleanup = read(run / "worker-cleanup.json")
        require(cleanup.get("errors") == [] and set(cleanup.get("workers", {})) == {"0", "1", "2", "3"},
                "four workers did not clean up")
        workers = {int(slot): worker for slot, worker in cleanup["workers"].items()}
        validate_exit_barrier(workers, read(run / "fixture/exit-release.json"),
            {str(slot): read(run / f"fixture/exit-{slot}.json") for slot in workers},
            {str(slot): digest(run / f"fixture/final-{slot}.json") for slot in workers},
            digest(run / "fixture/exit-release.json"))
        require(len({w["pid"] for w in workers.values()}) == 4
                and len({w["ttyPath"] for w in workers.values()}) == 4
                and {w["runToken"] for w in workers.values()} == {isolated["token"]}, "worker identities collide")
        discoveries = [step for step in read(run / "setup.json")
                       if step.get("event") == "workers" and step.get("expectedCount") == 4]
        require(len(discoveries) == 1, "complete owned-worker discovery was not retained")
        discovered = {worker["slot"]: worker for worker in discoveries[0]["workers"]}
        starts = discoveries[0]["startIdentities"]
        require(set(discovered) == {0, 1, 2, 3} and set(starts) == {str(w["pid"]) for w in workers.values()}
                and set(cleanup.get("originalProcesses", {})) == {"0", "1", "2", "3"},
                "missing original worker process identities")
        for slot, worker in workers.items():
            ready = read(run / f"fixture/worker-{slot}.json")
            require(ready == discovered[slot], "fixture readiness differs from owned discovery")
            require(worker == read(run / f"fixture/final-{slot}.json"), "final worker record differs")
            require(all(worker[key] == ready[key] for key in
                        ("pid", "slot", "ttyPath", "runToken", "startedMonotonicNs", "workerSourceSHA256")),
                    "worker identity changed")
            require(launch["startedMonotonicNS"] <= worker["startedMonotonicNs"]
                    <= worker["activeStartNs"] <= observation["startedMonotonicNs"],
                    "fixture or observation predates its owned app launch")
            require(worker["workerSourceSHA256"] == metadata["toolingSHA256"]["four_pane_worker.py"],
                    "running worker source differs from the frozen source")
            require(worker.get("pacingSourceSHA256") == ready.get("pacingSourceSHA256")
                    == metadata["toolingSHA256"]["terminal_bench_pacing.py"]
                    and worker.get("pacingPolicy") == ready.get("pacingPolicy") == PACING_POLICY
                    and worker.get("pacingTimerClosed") is True, "producer pacing provenance or cleanup differs")
            original = cleanup["originalProcesses"][str(slot)]
            require(original == {"pid": worker["pid"], "startIdentity": starts[str(worker["pid"])], "exited": True}
                    and isinstance(original["startIdentity"], str) and bool(original["startIdentity"]),
                    "an original worker did not exit before app cleanup")
            restored = worker.get("cleanup", {})
            require(restored.get("stdinRestored") is True and restored.get("stdoutRestored") is True
                    and restored.get("unexpectedInputBytes") == 0 and restored.get("modeDifferenceIndices") == []
                    and restored.get("ttyFlagsOriginal") == restored.get("ttyFlagsRestored")
                    and restored.get("descriptorStatusPlatform") in (None, "darwin")
                    and set(restored.get("descriptorFlagsOriginal", {})) == {"0", "1"}
                    and set(restored.get("descriptorFlagsRestored", {})) == {"0", "1"}
                    and all(descriptor_flags_match(restored["descriptorFlagsOriginal"][fd],
                        restored["descriptorFlagsRestored"][fd], restored.get("descriptorStatusPlatform")) for fd in ("0", "1"))
                    and not restored.get("descriptorErrors"), "exact TTY or descriptor restoration failed")
        states = read(run / "states.json")
        require(all(set(states[phase]) == {"0", "1", "2", "3"} and all(
                    state["grid"] == GRID and state["mode"] == "active" for state in states[phase].values())
                    for phase in ("before", "after")), "four panes did not retain their exact grids")
        validate_marker(workers[0], latency, observation, count)
        validate_response_clocks(latency, observation, workers[0]["received"])
        for slot in (1, 2, 3):
            validate_settling(workers[slot], observation)
        loads = {str(slot): validate_busy(workers[slot], observation) for slot in (1, 2, 3)}
        qualification = read(run / "qualification.json")
        require(qualification["status"] == "valid" and qualification["block"] == block
                and qualification["terminal"] == terminal and qualification["gridPerPane"] == GRID
                and qualification["load"] == loads and qualification["summaryMs"] == latency["summaryMs"],
                "qualification does not reconstruct from raw records")
        require(qualification in summary["runs"], "summary omitted or changed a raw run")
        app_cleanup = read(run / "cleanup.json")
        require(app_cleanup.get("appPID") == launch["appPID"] and not app_cleanup.get("forcedKill")
                and app_cleanup.get("returncode") in (0, -15), "app cleanup failed")
        orders.setdefault(block, []).append((launch["startedMonotonicNS"], terminal))
        lifetimes.append((launch["startedMonotonicNS"], max(w["stoppedMonotonicNs"] for w in workers.values())))
        require(terminal not in blocks.setdefault(block, {}), "duplicate block/app")
        blocks[block][terminal] = values
    require(sorted(blocks) == list(range(pairs)) and all(set(pair) == {"cmdy", "ghostty"}
                for pair in blocks.values()), "unpaired or nonconsecutive blocks")
    firsts = [sorted(orders[block])[0][1] for block in range(pairs)]
    lifetimes.sort()
    require(all(lifetimes[i - 1][1] < lifetimes[i][0] for i in range(1, len(lifetimes))),
            "paired app runs overlapped or reused observation clocks")
    require(all(firsts[i] != firsts[i - 1] for i in range(1, pairs))
            and firsts.count("cmdy") == firsts.count("ghostty"), "order was not counterbalanced")
    return {"path": str(directory), "case": "input/four-pane", "kind": "input", "profile": profile,
            "power": power, "binaries": binaries, "grid": [60, 18], "blocks": blocks,
            "display": display, "font": machine["font"], "fontSHA256": metadata["fontSHA256"],
            "displays": machine["displays"], "observerEnvironment": environment,
            "hardware": metadata["hardware"]["stdout"]}
