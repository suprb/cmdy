#!/usr/bin/env python3
"""Read-only raw memory evidence adapter. Decision thresholds belong to parity_gate.py.

Never executes retained tooling, launches applications, reads the live clipboard,
or modifies evidence. Legacy pilot schema is descriptive and fails this adapter.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shlex
import sys
import termios

from memory_public_history import (MEMORY_TOOLING, TRANSPORT, VISUAL_MEMORY_TOOLING,
    VISUAL_MEMORY_SCOPE, VISUAL_MEMORY_TRANSPORT)
from history_export_phase import POLICY, contract, validate_phase_cleanup
from history_export_binding import validate_binding
from history_export_evidence import validate_transfer
from history_export_files import read_retained_generated
from history_export_protocol import ACTION, SHORTCUT, expectation

TERMINALS = ("cmdy", "ghostty")
CASES = ("primary-1000", "primary-5000", "alternate-continuous")
CASE_IDS = {"primary-1000": "1000-lines", "primary-5000": "5000-lines",
            "alternate-continuous": "alternate-continuous"}
METRICS = {"rss": "residentBytes", "physical-footprint": "physicalFootprintBytes"}
CPU_FIELDS = ("userTimeNS", "systemTimeNS")
IDLE_CPU_METRIC = "owned-app user+system CPU nanoseconds per second after five-second idle settle"
TOOLING = {"competitive_bench.py", "terminal_bench_worker.py", "TerminalBenchWindow.swift",
           "memory_bench.py", "memory_bench_payloads.py", "TerminalHistoryProbe.swift",
           "TerminalMemorySnapshot.c", "memory_parity_evidence.py"}
ROW_COUNTS = {"primary-1000": 1000, "primary-5000": 5000, "alternate-continuous": 35}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hash_value(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def integer(value, positive=False):
    return type(value) is int and value >= (1 if positive else 0)


def grid(value):
    require(type(value) is dict and value.get("columns") == 120 and value.get("rows") == 36,
            "memory evidence needs the actual 120x36 grid")
    return [120, 36]


def window(value, pid):
    require(value.get("ok") is True and value.get("pid") == pid and value.get("frontmostPID") == pid,
            "owned app was not frontmost")
    windows = value.get("windows", [])
    require(len(windows) == 1 and windows[0].get("ownerPID") == pid
            and windows[0].get("onScreen") is True, "one visible owned window required")
    result = windows[0]
    require(integer(result.get("windowID"), True) and integer(result.get("displayID"), True),
            "missing native window/display identity")
    require(all(type(result.get("bounds", {}).get(key)) in (int, float)
                and math.isfinite(result["bounds"][key]) for key in ("x", "y", "width", "height"))
            and result["bounds"]["width"] > 0 and result["bounds"]["height"] > 0,
            "invalid native window bounds")
    return result


def validate_pointer_setup(run, record, metadata, owned):
    """Setup must finish before accounting; it never exempts an occluding window."""
    enabled = metadata["arguments"].get("park_pointer_outside_window", False)
    require(type(enabled) is bool, "invalid pointer setup mode")
    path = run / "pointer-setup.json"
    if not enabled:
        require("pointerSetup" not in record and not path.exists(), "unplanned pointer setup")
        return
    require(metadata["schemaVersion"] == 5, "pointer setup requires visual memory history mode")
    value = record.get("pointerSetup")
    require(type(value) is dict and path.is_file() and read(path) == value,
            "pointer setup receipt missing or changed")
    native = value.get("native", {})
    require(native.get("ok") is True and native.get("schemaVersion") == 1
            and native.get("kind") == "owned-window-pointer-setup"
            and native.get("eventsPosted") is False and native.get("windowMutated") is False
            and type(native.get("warped")) is bool, "invalid pointer setup receipt")
    pid = record["identity"]["appPID"]
    require(native.get("pid") == native.get("foregroundPID") == pid
            and native.get("windowID") == owned["windowID"]
            and native.get("displayID") == owned["displayID"]
            and native.get("windowBounds") == owned["bounds"], "pointer setup owned window changed")
    identity = native.get("identity", {})
    proof = record.get("historyVerification", {}).get("transfer", {}).get("beforeOwner", {}).get("identity", {})
    keys = {"pid", "uid", "startSeconds", "startMicroseconds", "executable"}
    require(type(identity) is dict and set(identity) == keys
            and all(identity[key] == proof.get(key) for key in keys)
            and identity["pid"] == pid and identity["executable"] == metadata["binaries"][record["terminal"]]["path"],
            "pointer setup process identity changed")
    display = native.get("displayBounds", {})
    require(type(display) is dict and set(display) == {"x", "y", "width", "height"}
            and all(type(part) in (int, float) and math.isfinite(part) for part in display.values())
            and display["width"] > 0 and display["height"] > 0, "invalid pointer display geometry")
    displays = metadata["displayFontPermissions"]["displays"]
    require(any(item.get("displayID") == owned["displayID"] and item.get("bounds") == display
                for item in displays), "pointer setup display differs from preregistered display")
    for key in ("cursorBefore", "target", "cursorAfter"):
        point = native.get(key, {})
        require(type(point) is dict and set(point) == {"x", "y"}
                and all(type(part) in (int, float) and math.isfinite(part) for part in point.values()),
                "invalid pointer coordinates")
    clearance = native.get("clearancePoints")
    require(type(clearance) in (int, float) and clearance == 96, "pointer clearance changed")
    x, y = native["target"]["x"], native["target"]["y"]
    bounds = owned["bounds"]
    require(display["x"] <= bounds["x"] and display["y"] <= bounds["y"]
            and bounds["x"] + bounds["width"] <= display["x"] + display["width"]
            and bounds["y"] + bounds["height"] <= display["y"] + display["height"],
            "pointer setup window is not contained on the display")
    require(display["x"] + clearance <= x <= display["x"] + display["width"] - clearance
            and display["y"] + clearance <= y <= display["y"] + display["height"] - clearance
            and (x + clearance <= bounds["x"] or x - clearance >= bounds["x"] + bounds["width"]
                 or y + clearance <= bounds["y"] or y - clearance >= bounds["y"] + bounds["height"]),
            "pointer was not parked clear of the owned window")
    require(abs(native["cursorAfter"]["x"] - x) <= 1 and abs(native["cursorAfter"]["y"] - y) <= 1,
            "pointer did not reach the planned position")
    require(all(integer(native.get(key), True) for key in
                ("timebaseNumer", "timebaseDenom", "beforeTicks", "afterTicks"))
            and integer(value.get("hostStartedMonotonicNS"), True)
            and integer(value.get("hostFinishedMonotonicNS"), True), "invalid pointer setup clocks")
    numer, denom = native["timebaseNumer"], native["timebaseDenom"]
    sample = record["samples"][0]
    require((numer, denom) == (sample["app"]["timebaseNumer"], sample["app"]["timebaseDenom"])
            and value["hostStartedMonotonicNS"] <= native["beforeTicks"] * numer // denom
            <= native["afterTicks"] * numer // denom <= value["hostFinishedMonotonicNS"]
            <= record["setupFinishedMonotonicNS"] <= sample["guardStartedMonotonicNS"],
            "pointer setup overlaps accounting or has inconsistent clocks")


def condition_signature(value):
    native, power = value["native"], value["power"]
    signature = power["signature"]
    require(signature.get("source") in ("AC Power", "Battery Power")
            and isinstance(signature.get("settings"), str) and signature["settings"],
            "missing power source/settings")
    require(native.get("ok") is True and type(native.get("lowPowerMode")) is bool
            and type(native.get("thermalState")) is int and native["thermalState"] == 0
            and isinstance(native.get("os"), str) and native["os"]
            and integer(native.get("physicalMemoryBytes"), True)
            and integer(native.get("processorCount"), True), "invalid native power/thermal/machine evidence")
    require(all(power[key].get("returncode") == 0 for key in ("battery", "settings", "thermal")),
            "power command failed")
    require(len(power.get("loadAverage", [])) == 3 and all(type(part) in (int, float)
            and math.isfinite(part) and part >= 0 for part in power["loadAverage"]), "load evidence missing")
    require(integer(value.get("startedMonotonicNS"), True)
            and value["startedMonotonicNS"] <= native.get("monotonicNS", -1)
                <= value.get("finishedMonotonicNS", -1), "native condition clock ordering failed")
    return {"powerSource": signature["source"], "powerSettings": signature["settings"],
            "lowPowerMode": native["lowPowerMode"], "thermalState": native["thermalState"],
            "physicalMemoryBytes": native["physicalMemoryBytes"], "processorCount": native["processorCount"],
            "os": native["os"]}


def generated_rows(count, marker):
    lines = []
    for index in range(count):
        prefix = f"CMDY_MEMORY_{marker}_ROW_{index:06d}|"
        lines.append((prefix + "A" * (76 - len(prefix))).encode("ascii"))
    return b"\r\n".join(lines) + b"\r\n"


def payload_evidence(directory, manifest):
    metadata = read(directory / "payloads/manifest.json")
    require(metadata == manifest["payloads"] and metadata.get("formatVersion") == 1,
            "payload preregistration differs from retained manifest")
    marker = metadata.get("generatedMarker", "")
    require(re.fullmatch(r"[0-9a-f]{16}", marker) is not None and metadata.get("rowColumns") == 76,
            "invalid unique generated-row marker")
    expected = {"primary-1000.bin": generated_rows(1000, marker),
                "primary-5000.bin": generated_rows(5000, marker),
                "alternate-expected.bin": generated_rows(35, marker)}
    expected["alternate-continuous.bin"] = (b"\x1b[?1049h" + b"A" * 3_000_000
                                           + b"\x1b[2J\x1b[H" + expected["alternate-expected.bin"])
    require(set(metadata["files"]) == set(expected), "unexpected or missing payload files")
    for name, content in expected.items():
        record = metadata["files"][name]
        require((directory / "payloads" / name).read_bytes() == content
                and record.get("bytes") == len(content)
                and record.get("sha256") == hashlib.sha256(content).hexdigest(),
                "payload bytes/hash do not match the generated workload: " + name)
    definitions = metadata["cases"]
    require([item["name"] for item in definitions] == list(CASES), "payload cases changed")
    result = {}
    for definition in definitions:
        name = definition["name"]
        payload_name = name + ".bin"
        expected_name = "alternate-expected.bin" if name == "alternate-continuous" else payload_name
        require(definition == {"name": name, "payload": payload_name, "expected": expected_name,
                "expectedRows": ROW_COUNTS[name],
                "activeScreen": "alternate" if name == "alternate-continuous" else "primary",
                "priorBurstBytes": 3_000_000 if name == "alternate-continuous" else 0},
                "payload case semantics changed")
        result[name] = {**definition, **metadata["files"][payload_name],
                       "expectedHistorySHA256": hashlib.sha256(expected[expected_name].replace(b"\r\n", b"\n")).hexdigest()}
    return result


def expected_order(cases, blocks, first, block_start=0):
    require(first in TERMINALS, "invalid first terminal")
    result = []
    for block in range(block_start, block_start + blocks):
        offset = block % len(cases)
        ordered = cases[offset:] + cases[:offset]
        if block // len(cases) % 2:
            ordered.reverse()
        terminals = [first, "ghostty" if first == "cmdy" else "cmdy"]
        if block % 2:
            terminals.reverse()
        for position, case in enumerate(ordered):
            for terminal in terminals:
                result.append({"block": block, "position": position, "case": case, "terminal": terminal})
    return result


def parse_config(path):
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        require("=" in line, "invalid isolated config syntax")
        key, value = (part.strip() for part in line.split("=", 1))
        require(key not in result, "duplicate isolated config setting")
        result[key] = value
    return result


def check_config(run, launch, terminal, profile, public=False, verification_case=None):
    path = run / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
    require(digest(path) == launch["configSHA256"], "isolated config hash changed")
    config = parse_config(path)
    if terminal == "cmdy":
        expected = {"restore-session": "false", "marketplace-update-checks": "false",
                    "automatic-error-help": "false", "font-family": "Menlo-Regular", "font-size": "14"}
        if profile == "matched":
            expected.update({"shell-integration": "false", "clean-prompt": "false", "sounds": "false",
                "ghost-text": "false", "shader": "None", "smooth-cursor": "false", "smooth-scroll": "false",
                "cursor-style": "block", "cursor-blink": "false", "line-height": "1", "opacity": "1",
                "window-grid": "false", "workspace-navigator": "false", "workspace-inspector": "false"})
    else:
        expected = {"font-family": "Menlo", "font-style": "Regular", "font-size": "14",
            "shell-integration": "none", "background-opacity": "1", "cursor-style": "block",
            "cursor-style-blink": "false", "window-save-state": "never", "window-inherit-font-size": "false",
            "window-inherit-working-directory": "false", "window-padding-x": "10", "window-padding-y": "10",
            "confirm-close-surface": "false", "quit-after-last-window-closed": "true", "auto-update": "off",
            "working-directory": launch["cwd"], "command": "direct:/bin/zsh -l",
            "window-width": "120", "window-height": "36", "scrollback-limit": "100000000"}
    if verification_case is not None:
        if terminal == "ghostty": expected["keybind"] = SHORTCUT + "=" + contract(verification_case)["action"]
    elif public:
        expected["keybind"] = SHORTCUT + "=" + ACTION
    require(config == expected, "terminal config does not match the declared profile/history binding")
    extensions = run / "cmdy-config/extensions"
    require(extensions.is_dir() and not list(extensions.iterdir()), "isolated Extensions directory is not empty")
    require("CMDY_FRAME_TRACE" not in launch["environment"]
            and b"CMDY_FRAME_TRACE " not in (run / "app.log").read_bytes(), "trace present in memory run")


def check_process(sample, pid, start, uid):
    require(sample.get("ok") is True and sample.get("pid") == pid and sample.get("uid") == uid
            and sample.get("processStartTicks") == start and integer(start, True), "process identity changed")
    require(integer(sample.get("hostStartedMonotonicNS"), True)
            and sample["hostStartedMonotonicNS"] <= sample.get("startedMonotonicNS", -1)
            and integer(sample.get("sampleElapsedNS"))
            and sample["startedMonotonicNS"] + sample["sampleElapsedNS"] <= sample.get("hostFinishedMonotonicNS", -1),
            "native process sample clock order failed")
    require(all(integer(sample.get(field), True) for field in METRICS.values()), "missing/nonpositive app memory")
    require(integer(sample.get("timebaseNumer"), True) and integer(sample.get("timebaseDenom"), True),
            "missing native process clock timebase")
    require(start * sample["timebaseNumer"] // sample["timebaseDenom"] <= sample["startedMonotonicNS"],
            "process start identity is later than its sample")


def idle_cpu_rate(before, after):
    """Native cumulative counters, normalized by their actual wall interval.

    Call only after validating the settled phase, same process and native clock.
    An exact zero is valid; no epsilon or pseudocount is added.
    """
    require(all(sample.get('cpuTimeUnit') == 'nanoseconds' for sample in (before, after)),
            'idle CPU requires an explicitly converted nanosecond counter; legacy Mach ticks are not admitted')
    require(all(integer(sample.get(field)) for sample in (before, after) for field in CPU_FIELDS),
            "missing or negative idle CPU counter")
    require(all(after[field] >= before[field] for field in CPU_FIELDS), "idle CPU counter decreased")
    elapsed = after["startedMonotonicNS"] - before["startedMonotonicNS"]
    require(5_000_000_000 <= elapsed <= 6_000_000_000, "idle CPU interval outside fixed 5-to-6-second bounds")
    return sum(after[field] - before[field] for field in CPU_FIELDS) * 1_000_000_000 / elapsed


def check_ancestry(chain, identity, worker_parent):
    require(isinstance(chain, list) and 2 <= len(chain) <= 32, "missing bounded fixture ownership chain")
    require(chain[0].get("pid") == identity["workerPID"] and chain[-1].get("pid") == identity["appPID"]
            and chain[0].get("startIdentity") == identity["workerLaunchIdentity"]
            and chain[0].get("parentPID") == worker_parent, "fixture ancestry/launch identity mismatch")
    require(len({entry["pid"] for entry in chain}) == len(chain)
            and all(integer(entry.get("pid"), True) and isinstance(entry.get("startIdentity"), str)
                    and entry["startIdentity"] for entry in chain), "invalid/repeated ancestry identity")
    require(all(left["parentPID"] == right["pid"] for left, right in zip(chain, chain[1:])),
            "fixture ancestry did not reach the owned app")


def public_number(value, positive=False, maximum=(1 << 63) - 1):
    require(integer(value, positive) and value <= maximum, "invalid public-history integer")
    return value


def check_public_launch(run, metadata, launch, ready, identity, case):
    """Join the isolated shell, exact frozen sole-reader argv, and native binding."""
    phase_enabled = metadata["schemaVersion"] == 5
    binding = read(run / "public-history-binding.json")
    config = Path(launch["config"])
    terminal = launch["terminal"]
    original_run = config.parent.parent if terminal == "cmdy" else config.parent
    original_output = original_run.parent.parent
    require(original_run.is_absolute() and original_run.name == run.name
            and original_run.parent.name == "runs"
            and original_output == Path(metadata["arguments"]["output"]), "public launch belongs to another output")
    relative = "cmdy-config/config" if terminal == "cmdy" else "ghostty.config"
    require(config == original_run / relative and launch["readyPath"] == str(original_run / "fixture/ready.json")
            and launch.get("drainFixtureSource") is None, "public fixture/config path differs")
    argv = [metadata["binaries"][terminal]["path"]]
    if terminal == "ghostty":
        argv += ["--config-default-files=false", "--config-file=" + str(config)]
    require(launch["arguments"] == argv, "public app launch arguments differ")
    nonce, capability = binding["nonce"], binding["capability"]
    require(re.fullmatch("[0-9a-f]{32}", nonce) is not None
            and nonce[:16] == metadata["payloads"]["generatedMarker"]
            and re.fullmatch("[0-9a-f]{32}", capability) is not None, "public nonce/capability differs")
    expected = expectation(case, nonce)
    require(binding.get("schemaVersion") == (3 if phase_enabled else 1)
            and binding.get("transport") == (VISUAL_MEMORY_TRANSPORT if phase_enabled else TRANSPORT)
            and binding["expectation"] == expected, "public expectation/binding differs")
    if phase_enabled:
        require(type(binding["schemaVersion"]) is int and binding.get("verificationPolicy") == POLICY and binding.get("verificationScope") == VISUAL_MEMORY_SCOPE
                and binding.get("verificationContract") == contract(case)
                and type(binding.get("childUmask")) is int and binding["childUmask"] == 0o077
                and type(launch.get("childUmask")) is int and launch["childUmask"] == binding["childUmask"]
                and binding.get("workerExecutable") == metadata["pythonExecutable"],
                "visual memory policy, child umask or worker pin differs")
        receipt = binding["shortcutBinding"]
        original_binding = config.parent / "keybindings.json" if terminal == "cmdy" else config
        require(receipt["configPath"] == str(config) and receipt["bindingPath"] == str(original_binding),
                "visual memory public binding belongs to another launch")
        actual_config = run / relative
        actual_binding = actual_config.parent / "keybindings.json" if terminal == "cmdy" else actual_config
        validate_binding(terminal, actual_config, dict(receipt, configPath=str(actual_config), bindingPath=str(actual_binding)),
                         case=case, policy=POLICY)
    temporary, control = Path(binding["temporaryDirectory"]), Path(binding["socketPath"])
    require(temporary.parent == Path("/private/tmp") and temporary.name.startswith("cmdy-memory-export-")
            and control.name == "control.sock" and control.parent.parent == Path("/private/tmp")
            and control.parent.name.startswith("cmdy-memory-control-") and control.parent != temporary,
            "public export/control directories are not separately owned")
    command = binding["worker"]
    require(isinstance(command, list) and len(command) == (21 if phase_enabled else 19) and isinstance(command[0], str)
            and Path(command[0]).is_absolute() and ".." not in Path(command[0]).parts,
            "public canonical Python command is missing")
    expected_command = [command[0], "-S", str(original_output / "tooling/history_export_worker.py"),
        "--output", str(original_run / "fixture"), "--temporary-directory", str(temporary),
        "--socket", str(control), "--capability", capability, "--nonce", nonce, "--case", case,
        "--payload", str(original_output / "payloads" / (case + ".bin")), "--timeout", "600"]
    if phase_enabled:
        expected_command.extend(("--verification-policy", POLICY))
        require(command[0] == metadata["pythonExecutable"]["path"], "visual memory worker interpreter differs")
    require(command == expected_command == launch["fixtureCommand"]
            and binding["workerSHA256"] == metadata["toolingSHA256"]["history_export_worker.py"],
            "public worker is not the exact frozen sole reader")
    require((run / "zsh/.zshenv").read_text() == "unsetopt RCS\nexec " + shlex.join(command) + "\n",
            "public shell fixture differs from its registered argv")
    cwd, domain = Path(launch["cwd"]), launch["defaultsDomain"]
    require(cwd.name == "work" and cwd.parent.parent == Path("/private/tmp")
            and cwd.parent.name.startswith("cmdy-drain-")
            and re.fullmatch(r"com\.cmdy\.bench\.[0-9a-f]{32}", domain) is not None,
            "public launch working directory/defaults are not isolated")
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": str(temporary) + "/",
        "ZDOTDIR": str(original_run / "zsh"), "XDG_CONFIG_HOME": str(original_run / "xdg-config"),
        "XDG_DATA_HOME": str(original_run / "xdg-data"), "XDG_CACHE_HOME": str(original_run / "xdg-cache"),
        "XDG_STATE_HOME": str(original_run / "xdg-state"), "CMDY_CONFIG_DIR": str(original_run / "cmdy-config"),
        "CMDY_DEFAULTS_DOMAIN": domain}
    require(all(launch["environment"].get(key) == value for key, value in environment.items())
            and set(launch["environment"]) <= set(environment) | {"HOME", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING"},
            "public launch environment or private TMPDIR differs")
    require(ready.get("schemaVersion") == 1 and ready.get("role") == "history-public-export"
            and ready.get("pid") == ready.get("workerPID") == identity["workerPID"]
            and ready.get("nonce") == nonce and ready.get("temporaryDirectory") == str(temporary)
            and ready.get("socketPath") == str(control)
            and re.fullmatch(r"/dev/ttys[0-9]+", ready.get("ttyPath", "")) is not None,
            "public worker readiness identity/binding differs")
    if phase_enabled:
        require(ready.get("verificationPolicy") == POLICY, "visual memory worker policy missing")
    require(launch["startedMonotonicNS"] <= public_number(ready["startedMonotonicNS"], True)
            <= public_number(ready["readyMonotonicNS"], True) <= launch["fixtureReadyObservedMonotonicNS"]
            and launch["fixtureReadyMonotonicNS"] == ready["readyMonotonicNS"], "public readiness clocks differ")
    require(ready["outputPostprocessingEnabled"] is False
            and ready["onlcrEnabled"] is bool(ready["ttyFlagsRaw"][1] & termios.ONLCR),
            "public raw terminal mode differs")
    return binding


def validate_post_sample_history_phase(samples, phase, spec, worker_pid, prepared, timebase):
    """Join the phase to all original samples; ownership is validated separately.

    This helper alone cannot admit file-only transport or any memory metric.
    """
    from history_export_phase import validate_phase
    labels = ["matched-grid-before-settle", "settled-idle-baseline", "settled-idle-cpu-end",
              "post-output-0s", "post-output-1s", "post-output-5s"]
    require(type(samples) is list and len(samples) == 6
        and [sample["label"] for sample in samples] == labels, "verification-requires-all-original-memory-samples")
    previous = 0
    for index, sample in enumerate(samples):
        start = public_number(sample["guardStartedMonotonicNS"], True)
        end = public_number(sample["guardFinishedMonotonicNS"], True)
        require(previous <= start <= end, "verification-memory-sample-order-differs")
        offset = sample["requestedOffsetSeconds"]
        require(offset is None if index < 3 else type(offset) in (int, float) and offset == (0,1,5)[index-3],
                "verification-memory-sample-offset-differs")
        previous = end
    boundary = dict(kind="all-memory-samples", finishedMonotonicNS=previous)
    validate_phase(phase, spec, worker_pid, prepared, boundary=boundary, timebase=timebase)
    return dict(status="valid-post-sample-verification-order", qualifying=False, memoryAdmission=False)


def check_public_history(run, metadata, record, launch, ready, binding, baseline_window, workload, timebase):
    """Rebuild every generated row and join transfer, sample, control and exit clocks."""
    phase_enabled = metadata["schemaVersion"] == 5
    audit = record["historyVerification"]
    require(audit == read(run / "history-verification.json") and audit.get("schemaVersion") == (3 if phase_enabled else 1)
            and audit.get("transport") == (VISUAL_MEMORY_TRANSPORT if phase_enabled else TRANSPORT) and audit.get("ok") is True
            and audit.get("ownedPID") == record["identity"]["appPID"]
            and audit.get("workerPID") == record["identity"]["workerPID"]
            and audit["expectation"] == binding["expectation"]
            and audit.get("retainedRawFile") == "fixture/generated-export.bin", "public history record differs")
    transfer, proof = audit["transfer"], read(run / "fixture/export.json")
    raw = read_retained_generated(run / "fixture/generated-export.bin", binding["expectation"])
    actual = validate_transfer(transfer, raw)
    require(audit["transferValidation"] == actual and audit["proof"] == proof
            and audit["retainedRows"] == audit["expectedRows"] == actual["generatedHistory"]["logicalRows"] == workload["expectedRows"]
            and audit["normalizedSHA256"] == actual["generatedHistory"]["normalizedSHA256"] == workload["expectedHistorySHA256"],
            "public complete generated rows do not reconstruct")
    arm, prepared = read(run / "fixture/arm.json"), read(run / "fixture/prepared.json")
    spec = read(run / "history-action-spec.json")
    inspect_spec = read(run / "history-inspect-spec.json")
    expected_spec = {"pid": audit["ownedPID"], "workerPID": audit["workerPID"], "ttyPath": ready["ttyPath"],
        "executableSHA256": metadata["binaries"][record["terminal"]]["sha256"], "nonce": binding["nonce"],
        "windowID": baseline_window["windowID"], "displayID": baseline_window["displayID"]}
    if phase_enabled:
        expected_spec.update(verificationPolicy=POLICY, exportCase=record["case"], verificationScope=VISUAL_MEMORY_SCOPE)
        phase = read(run / "fixture/verification-phase.json")
        require(type(audit["schemaVersion"]) is int and audit.get("verificationPolicy") == POLICY and audit.get("verificationScope") == VISUAL_MEMORY_SCOPE
                and audit["verificationPhase"] == phase, "visual memory phase record differs")
    require(inspect_spec == expected_spec and spec == {**expected_spec,
            "expectedApp": audit["before"]["owner"]["identity"], "expectedWorker": audit["before"]["owner"]["workerIdentity"]},
            "public native target specification differs")
    expected_transfer = {"schemaVersion": 4 if phase_enabled else 1, "terminal": record["terminal"], "expectation": binding["expectation"],
            "nativeSpec": spec, "workerReady": ready, "workerArm": arm, "action": audit["action"], "export": proof,
            "beforeOwner": audit["before"]["owner"], "afterOwner": audit["after"]["owner"]}
    if phase_enabled: expected_transfer.update(workerPrepared=prepared, verificationPhase=phase)
    require(transfer == expected_transfer, "public transfer is not joined to its retained raw records")
    for value in (audit["before"], audit["after"]):
        require(value.get("ok") is True and value.get("op") == "inspect", "public native inspection failed")
    fields = ("sequence", "elapsedNS", "startedMonotonicNS", "finishedMonotonicNS", "payloadBytes",
              "footerHex", "responseHex", "expectedResponseHex", "gridBefore", "gridAfter")
    raw_drain = {key: record["drain"][key] for key in fields}
    require(prepared == {"expectation": binding["expectation"], "grid": {"columns": 120, "rows": 36},
            "bytes": workload["bytes"], "sha256": workload["sha256"], "drain": raw_drain},
            "public same-reader prepared/drain payload differs")
    def reply(mode, armed, exported):
        value = {"schemaVersion": 1, "ok": True, "pid": audit["workerPID"], "capability": binding["capability"],
            "mode": mode, "grid": {"columns": 120, "rows": 36}, "error": "", "prepared": prepared,
            "arm": armed, "proof": exported, "unexpectedInputBytes": 0}
        if phase_enabled: value["verificationPhase"] = None if mode == "prepared" else phase
        return value
    if phase_enabled:
        require(audit["verificationReply"] == reply("verified", None, None), "visual memory phase control reply differs")
    require({key: value for key, value in record["drain"].items() if key not in ("windowBefore", "windowAfter")}
            == {**reply("prepared", None, None), **raw_drain}
            and audit["arm"] == reply("armed", arm, None)
            and audit["received"] == reply("received", arm, proof), "public raw control replies differ")
    numer, denom = timebase
    public_number(numer, True, (1 << 32) - 1); public_number(denom, True, (1 << 32) - 1)
    require(audit["timebase"] == {"numer": numer, "denom": denom}, "public/native memory clock timebase differs")
    if phase_enabled:
        validate_post_sample_history_phase(record["samples"], phase, binding["expectation"], audit["workerPID"], prepared, timebase)
    def ns(ticks):
        return public_number(ticks, True) * numer // denom
    start, end = public_number(audit["hostStartedMonotonicNS"], True), public_number(audit["hostFinishedMonotonicNS"], True)
    require(record["samples"][-1]["guardFinishedMonotonicNS"] <= start <= end
            and audit["nativeStartedMonotonicNS"] == ns(audit["action"]["beforeTicks"])
            and audit["nativeFinishedMonotonicNS"] == ns(proof["receiveCompletedTicks"]),
            "public history audit clocks do not reconstruct after samples")
    action = audit["action"]
    owners = [audit["before"]["owner"], action["beforeOwner"], action["afterOwner"], audit["after"]["owner"]]
    require(ready.get("parentPID") == owners[0]["workerIdentity"]["parentPID"],
            "public ready parent differs from native worker lifetime")
    spans = []
    for owner in owners:
        first = ns(owner["ancestry"]["startedTicks"]); last = ns(owner["window"]["queriedTicks"])
        require(start <= first <= ns(owner["ancestry"]["finishedTicks"]) <= last <= end
                and owner["window"]["bounds"] == baseline_window["bounds"], "public owner clock/window differs from memory samples")
        spans.append((first, last))
        for role, native in (("app", owner["identity"]), ("worker", owner["workerIdentity"])):
            if phase_enabled:
                from history_executable_identity import same_executable_file
                pin = metadata["binaries"][record["terminal"]] if role == "app" else metadata["pythonExecutable"]
                require(same_executable_file(native["executable"], pin), "visual memory native executable differs from pinned file")
            else:
                require(native["executable"] == (metadata["binaries"][record["terminal"]]["path"] if role == "app" else binding["worker"][0]),
                        "public native executable differs from pinned launch")
            for sample in record["samples"]:
                value = sample[role]
                require(value["pid"] == native["pid"] and value["uid"] == native["uid"]
                        and value["parentPID"] == native["parentPID"]
                        and public_number(value["processStartSeconds"], True) == native["startSeconds"]
                        and public_number(value["processStartMicroseconds"], maximum=999_999) == native["startMicroseconds"],
                        "public native process lifetime differs from sampled BSD identity")
    require(spans[0][1] <= ns(arm["armedTicks"]) <= spans[1][0] <= spans[1][1]
            <= ns(action["beforeTicks"]) <= ns(action["betweenTicks"]) <= ns(action["afterTicks"])
            <= spans[2][0] <= spans[2][1] <= ns(proof["receiveCompletedTicks"])
            <= spans[3][0] <= spans[3][1], "public owner/action/export clock sequence differs")
    for ticks, timestamp in [(arm["armedTicks"], arm["armedMonotonicNS"]),
            (proof["receiveCompletedTicks"], proof["receiveCompletedMonotonicNS"]),
            *[(row["ticks"], row["monotonicNS"]) for row in proof["chunks"]]]:
        require(start <= ns(ticks) <= public_number(timestamp, True) <= end, "public worker clock mapping differs")
    require(ns(ready["startedTicks"]) >= ready["startedMonotonicNS"]
            and ns(ready["startedTicks"]) <= ready["readyMonotonicNS"], "public ready native clock differs")
    finish = read(run / "history-finish.json")
    require(finish["reply"] == read(run / "history-finish-reply.json") == audit["received"], "public finish control reply differs")
    exit_record = finish["workerExit"]
    require(exit_record["pid"] == audit["workerPID"] and exit_record["startIdentity"] == record["identity"]["workerLaunchIdentity"]
            and exit_record["exited"] is True and end <= public_number(exit_record["startedMonotonicNS"], True)
            <= public_number(exit_record["finishedMonotonicNS"], True), "original public worker exit is unproved")
    cleanup = read(run / "fixture/cleanup.json")
    require(cleanup.get("schemaVersion") == 1 and cleanup.get("status") == "pass"
            and cleanup.get("pid") == audit["workerPID"] and cleanup.get("nonce") == binding["nonce"]
            and cleanup.get("reason") == "controller-finish" and cleanup.get("errorCode") == ""
            and cleanup.get("inputBytesRetained") == cleanup.get("unexpectedInputBytes") == 0
            and all(cleanup.get(key) is True for key in ("termiosRestored", "fileFlagsRestored", "terminalRestoreWritten", "controlSocketRemoved"))
            and cleanup["ttyFlagsOriginal"] == cleanup["ttyFlagsAfter"] == ready["ttyFlagsBefore"][:4],
            "public worker terminal/input cleanup differs")
    controls = cleanup["controls"]
    if phase_enabled:
        validate_phase_cleanup(cleanup, phase, arm)
        require(5 <= len(controls) <= 256 and [row["op"] for row in controls[:3]] == ["drain", "verify-history", "arm"]
                and controls[-1]["op"] == "finish" and all(row["op"] == "status" for row in controls[3:-1]),
                "visual memory raw control sequence differs")
    else:
        require(4 <= len(controls) <= 256 and [row["op"] for row in controls[:2]] == ["drain", "arm"]
                and controls[-1]["op"] == "finish" and all(row["op"] == "status" for row in controls[2:-1]),
                "public raw control sequence differs")
    clocks = [ns(row["ticks"]) for row in controls]
    if phase_enabled:
        require(spans[0][1] <= clocks[1] <= ns(phase["startedTicks"])
                <= ns(phase["finishedTicks"]) <= clocks[2], "visual memory phase control/owner clock differs")
        # Apply the unchanged original drain/arm/status/finish clock checks too.
        clocks = [clocks[0], *clocks[2:]]
    require(clocks == sorted(clocks) and ready["readyMonotonicNS"] <= clocks[0] <= record["drain"]["startedMonotonicNS"]
            and spans[0][1] <= clocks[1] <= ns(arm["armedTicks"]) and clocks[2] >= ns(action["afterTicks"])
            and end <= clocks[-1] <= ns(cleanup["finishedTicks"]) <= exit_record["finishedMonotonicNS"],
            "public control/cleanup clocks differ")
    return exit_record["finishedMonotonicNS"]


def load_memory_evidence(directory, expected_binaries):
    """Return memory cases and schema-3/4 settled CPU with common scenario metadata.

    `expected_binaries` must pin both SHA256 values. This adapter validates raw
    completeness and consistency; the caller alone sets minimum blocks/ratios.
    """
    directory = Path(directory).resolve()
    require(set(expected_binaries) == set(TERMINALS)
            and all(hash_value(value) for value in expected_binaries.values()), "both binaries must be pinned")
    require(not list(directory.glob("failed-*.json")) and not (directory / "failure.json").exists(),
            "failed memory case retained")
    metadata, summary = read(directory / "manifest.json"), read(directory / "summary.json")
    require(metadata.get("schemaVersion") in (2, 3, 4, 5) and metadata.get("benchmarkKind") == "memory"
            and metadata.get("status") == "complete" and metadata.get("finalHashesVerified") is True,
            "unsupported/incomplete memory evidence; legacy pilot remains descriptive")
    require(metadata.get("diagnostic") is False and summary.get("diagnostic") is False
            and summary.get("status") == "valid-normalized-history", "diagnostic or incomplete memory summary")
    require(metadata.get("metric") == summary.get("metric"), "memory metric mismatch")
    args = metadata["arguments"]
    profile = metadata["profile"]
    require(profile in ("matched", "cmdy-defaults") and args.get("profile") == profile
            and summary.get("profile") == profile and args.get("diagnostic_frame_trace") is False,
            "memory profile/trace mismatch")
    blocks = args["blocks"]
    require(integer(blocks, True) and blocks <= 20 and summary.get("blocks") == blocks,
            "invalid requested block count")
    block_start = args.get("block_start", 0)
    require(type(block_start) is int and 0 <= block_start <= 20 - blocks
            and summary.get("blockStart", 0) == block_start, "invalid global block offset")
    block_ids = range(block_start, block_start + blocks)
    require(args.get("settle_seconds") == 5 and args.get("after_seconds") == [0, 1, 5],
            "parity memory evidence requires the fixed 5-second baseline and 0/1/5-second sample schedule")
    phase_enabled = metadata["schemaVersion"] == 5
    public = metadata["schemaVersion"] in (4, 5)
    has_idle_cpu = metadata["schemaVersion"] in (3, 4, 5)
    if phase_enabled:
        require(type(metadata["schemaVersion"]) is int and args.get("post_sample_history") is True and metadata.get("historyTransport") == VISUAL_MEMORY_TRANSPORT
                and metadata.get("verificationPolicy") == POLICY and metadata.get("verificationScope") == VISUAL_MEMORY_SCOPE
                and type(metadata.get("childUmask")) is int and metadata["childUmask"] == 0o077,
                "schema-5 explicit visual memory policy missing")
        python = metadata["pythonExecutable"]
        require(type(python) is dict and set(python) == {"path", "bytes", "sha256"}
                and type(python["path"]) is str and Path(python["path"]).is_absolute()
                and integer(python["bytes"], True) and hash_value(python["sha256"]), "visual memory worker pin missing")
    elif public:
        require(metadata.get("historyTransport") == TRANSPORT, "schema-4 public history transport missing")
    if has_idle_cpu:
        require(args.get("idle_cpu_seconds") == 5 and metadata.get("idleCPUMetric") == IDLE_CPU_METRIC,
                "idle CPU requires a separate fixed 5-second settled interval")
    require(grid(metadata["targetGrid"]) == [120, 36] and integer(args.get("display_id"), True),
            "missing matched memory display/grid")
    require(metadata.get("ghosttyScrollbackLimitBytes") == 100_000_000, "history budget changed")
    binaries = {terminal: metadata["binaries"][terminal]["sha256"] for terminal in TERMINALS}
    require(binaries == expected_binaries, "binary differs from pinned candidate/comparator")
    require(all(metadata["binaries"][name].get("version") and metadata["binaries"][name].get("build")
                and hash_value(metadata["binaries"][name].get("infoPlistSHA256")) for name in TERMINALS),
            "binary version/build/package identity missing")
    public_tooling = VISUAL_MEMORY_TOOLING if phase_enabled else MEMORY_TOOLING
    require(set(metadata["toolingSHA256"]) == (set(public_tooling) if public else TOOLING), "frozen memory tooling incomplete")
    if public:
        require({path.name for path in (directory / "tooling").iterdir()} == set(public_tooling)
                and {path.name for path in (directory / "helpers").iterdir()} == {"window_helper", "memory_helper", "history_helper"},
                "public frozen source/helper inventory differs")
    for name, expected in metadata["toolingSHA256"].items():
        require(hash_value(expected) and digest(directory / "tooling" / name) == expected,
                "frozen memory tooling hash mismatch: " + name)
    require(set(metadata["helperSHA256"]) == {"window_helper", "memory_helper", "history_helper"},
            "native helper identities missing")
    for name, expected in metadata["helperSHA256"].items():
        require(hash_value(expected) and digest(directory / "helpers" / name) == expected,
                "frozen native helper hash mismatch")
    require(hash_value(metadata.get("fontSHA256")), "font file hash unavailable")
    machine = metadata["displayFontPermissions"]
    require(machine["font"].get("postScriptName") == "Menlo-Regular"
            and machine["font"].get("sizePoints") == 14 and machine["font"].get("file")
            and machine.get("accessibilityTrusted") is True and machine.get("postEventAuthorized") is True,
            "matching font/native permissions missing")
    require(args["display_id"] in {entry["displayID"] for entry in machine["displays"]},
            "required display missing")
    require(metadata.get("hardware", {}).get("returncode") == 0 and metadata["hardware"].get("stdout")
            and metadata.get("os", {}).get("returncode") == 0 and metadata["os"].get("stdout"),
            "machine/OS identity missing")
    clock = metadata["clock"]
    require("mach_absolute_time" in clock.get("implementation", "")
            and clock.get("monotonic") is True and clock.get("adjustable") is False, "unsupported sample clock")
    reference = condition_signature(metadata["initialConditions"])
    require(condition_signature(metadata["finalConditions"]) == reference
            and read(directory / "conditions-reference.json")["signature"] == reference,
            "final/reference power, thermal or machine state changed")
    payloads = payload_evidence(directory, metadata)
    require(args.get("payload_marker") is None
            or args["payload_marker"] == metadata["payloads"]["generatedMarker"],
            "preregistered content marker changed")
    cases = metadata["preregisteredCases"]
    require(cases and cases == [name for name in CASES if name in cases] and len(cases) == len(set(cases)),
            "missing/duplicate/noncanonical preregistered cases")
    require(args.get("cases") is None and cases == list(CASES) or set(args.get("cases") or []) == set(cases),
            "requested and preregistered cases differ")
    order = expected_order(cases, blocks, args["first"], block_start)
    require(metadata["plannedRunOrder"] == order, "preregistered run order is not counterbalanced")
    records = read(directory / "records.json")
    require(isinstance(records, list) and len(records) == len(order), "missing/extra paired raw records")
    names = {f"{entry['block']:02d}-{entry['position']:02d}-{entry['case']}-{entry['terminal']}" for entry in order}
    require({path.name for path in (directory / "runs").iterdir()} == names, "missing/extra raw run directories")
    common_display = None
    seen_apps, seen_workers, actual_order = set(), set(), []
    collected = {name: {block: {terminal: [] for terminal in TERMINALS} for block in block_ids}
                 for name in ["idle", *cases]}
    cpu = {block: {terminal: [] for terminal in TERMINALS} for block in block_ids}
    identity_timebase = None
    public_bindings, public_lifetimes = set(), []
    for record, entry in zip(records, order):
        require(all(record.get(key) == value for key, value in entry.items()), "raw record order changed")
        require(record.get("status") == "valid" and record.get("profile") == profile
                and not any(key in record for key in ("error", "cleanupError", "failureEvidence")), "invalid raw case")
        block, position, name, terminal = (entry[key] for key in ("block", "position", "case", "terminal"))
        run = directory / "runs" / f"{block:02d}-{position:02d}-{name}-{terminal}"
        require(read(run / "memory.json") == record, "case aggregate differs from retained raw case")
        launch, ready, cleanup = read(run / "launch.json"), read(run / ("fixture/ready.json" if public else "ready.json")), read(run / "cleanup.json")
        identity = record["identity"]
        app_pid, worker_pid = identity["appPID"], identity["workerPID"]
        require(integer(app_pid, True) and integer(worker_pid, True) and app_pid != worker_pid
                and launch.get("appPID") == app_pid and launch.get("workerPID") == worker_pid
                and ready.get("workerPID") == worker_pid
                and launch.get("terminal") == terminal and launch.get("profile") == profile,
                "launch/fixture process identity mismatch")
        require(cleanup.get("appPID") == app_pid and (public or cleanup.get("fixtureQuit") is True)
                and not cleanup.get("forcedKill") and not cleanup.get("fixtureQuitError")
                and cleanup.get("returncode") in (0, -15), "owned cleanup failed/incomplete")
        if public:
            binding = check_public_launch(run, metadata, launch, ready, identity, name)
            for key in ("capability", "nonce", "temporaryDirectory", "socketPath"):
                pair = (key, binding[key])
                require(pair not in public_bindings, "public run capability/directory/nonce was reused")
                public_bindings.add(pair)
        else:
            require(launch["drainFixtureSource"]["sha256"] == metadata["toolingSHA256"]["terminal_bench_worker.py"]
                    and Path(launch["fixtureCommand"][1]).name == "terminal_bench_worker.py"
                    and launch["fixtureCommand"][1] == launch["drainFixtureSource"]["path"],
                    "launched worker is not the frozen drain fixture")
        check_config(run, launch, terminal, profile, public, name if phase_enabled else None)
        actual_order.append((launch["startedMonotonicNS"], entry))
        require(record["launchProxyNS"] == launch["processLaunchToFixtureReadyNS"]
                == ready["readyMonotonicNS"] - launch["startedMonotonicNS"] > 0,
                "launch/worker clocks changed")
        workload = payloads[name]
        require(all(record.get(key) == workload[value] for key, value in
                (("payloadBytes", "bytes"), ("payloadSHA256", "sha256"),
                 ("expectedHistorySHA256", "expectedHistorySHA256"), ("expectedRows", "expectedRows"),
                 ("activeScreen", "activeScreen"), ("priorBurstBytes", "priorBurstBytes")))
                and ready.get("payloadSHA256") == workload["sha256"] and ready.get("payloadBytes") == workload["bytes"],
                "fixture payload/retention semantics differ")
        require(record["tty"]["rawFlags"] == ready["ttyFlagsRaw"]
                and record["tty"].get("effectiveOPOST") is False and not ready["ttyFlagsRaw"][1] & termios.OPOST
                and record["tty"].get("inactiveONLCRBit") is bool(ready["ttyFlagsRaw"][1] & termios.ONLCR),
                "effective raw output processing changed")
        baseline_window = window(record["window"], app_pid)
        validate_pointer_setup(run, record, metadata, baseline_window)
        if common_display is None:
            common_display = baseline_window["displayID"]
        require(baseline_window["displayID"] == common_display == args["display_id"], "display changed between apps/blocks")
        checks = [read(path) for path in sorted((run / "window-checks").glob("*.json"))]
        require(checks and [item["check"] for item in checks] == list(range(len(checks))), "window guards missing")
        for check in checks:
            if check["monotonicNS"] >= record["setupFinishedMonotonicNS"]:
                require(check.get("status") == "valid" and check.get("requestedActivation") is False
                        and check.get("appPID") == app_pid and check.get("processReturncode") is None
                        and window(check["response"], app_pid) == baseline_window,
                        "invalid or activating measured window guard")
        conditions = record["conditions"]
        samples = record["samples"]
        require(len(samples) == (6 if has_idle_cpu else 5)
                and len(conditions) == len(samples) + 1, "memory schedule/condition samples incomplete")
        require(all(condition_signature(value) == reference for value in conditions),
                "power/thermal/machine changed within or between cases")
        require(conditions[0]["finishedMonotonicNS"] <= launch["startedMonotonicNS"],
                "pre-launch conditions were sampled too late")
        app_start, worker_start = samples[0]["app"]["processStartTicks"], samples[0]["worker"]["processStartTicks"]
        uid = samples[0]["app"]["uid"]
        require(integer(uid) and (app_pid, app_start) not in seen_apps and (worker_pid, worker_start) not in seen_workers,
                "reused app/fixture instead of a fresh process")
        seen_apps.add((app_pid, app_start))
        seen_workers.add((worker_pid, worker_start))
        labels = ["matched-grid-before-settle", "settled-idle-baseline"]
        if has_idle_cpu:
            labels.append("settled-idle-cpu-end")
        pre_output_count = len(labels)
        labels += ["post-output-0s", "post-output-1s", "post-output-5s"]
        for index, sample in enumerate(samples):
            require(sample.get("label") == labels[index] and sample.get("requestedOffsetSeconds")
                    == (None if index < pre_output_count else [0, 1, 5][index - pre_output_count]),
                    "memory phase ordering changed")
            require(window(sample["windowBefore"], app_pid) == baseline_window
                    and window(sample["windowAfter"], app_pid) == baseline_window
                    and grid(sample["gridBefore"]) == grid(sample["gridAfter"]), "sample focus/geometry failed")
            check_process(sample["app"], app_pid, app_start, uid)
            check_process(sample["worker"], worker_pid, worker_start, uid)
            timebase = (sample["app"]["timebaseNumer"], sample["app"]["timebaseDenom"])
            identity_timebase = identity_timebase or timebase
            require(timebase == identity_timebase == (sample["worker"]["timebaseNumer"], sample["worker"]["timebaseDenom"]),
                    "native process clock timebase changed")
            check_ancestry(sample["ownershipChain"], identity, sample["worker"]["parentPID"])
            require(sample.get("conditionsIndex") == index + 1
                    and sample["guardStartedMonotonicNS"] <= sample["app"]["hostStartedMonotonicNS"]
                    <= sample["app"]["hostFinishedMonotonicNS"] <= sample["worker"]["hostStartedMonotonicNS"]
                    <= sample["worker"]["hostFinishedMonotonicNS"] <= conditions[index + 1]["startedMonotonicNS"]
                    <= conditions[index + 1]["finishedMonotonicNS"] <= sample["guardFinishedMonotonicNS"],
                    "sample/condition guard clock ordering failed")
            require(sample["guardStartedMonotonicNS"] >= (record["setupFinishedMonotonicNS"] if index == 0
                    else samples[index - 1]["guardFinishedMonotonicNS"]), "overlapping/reordered memory phases")
        require(samples[1]["guardStartedMonotonicNS"] - samples[0]["guardFinishedMonotonicNS"] >= 5_000_000_000,
                "idle settle was shorter than the fixed schedule")
        if has_idle_cpu:
            require(samples[2]["guardStartedMonotonicNS"] - samples[1]["guardFinishedMonotonicNS"] >= 5_000_000_000,
                    "idle CPU interval started before the settled baseline completed")
            cpu[block][terminal].append(idle_cpu_rate(samples[1]["app"], samples[2]["app"]))
        drain = record["drain"]
        row, column = 2 + block % 35, 2 + (block // 35) % 119
        response, footer = f"\x1b[{row};{column}R".encode(), f"\x1b[{row};{column}H\x1b[6n".encode()
        require(drain.get("ok") is True and drain.get("sequence") == block
                and drain.get("responseHex") == drain.get("expectedResponseHex") == response.hex()
                and drain.get("footerHex") == footer.hex() and drain.get("payloadBytes") == workload["bytes"]
                and grid(drain["gridBefore"]) == grid(drain["gridAfter"])
                and drain["gridBefore"] == drain["gridAfter"], "exact drain/DSR bytes or grid failed")
        require(drain["startedMonotonicNS"] >= samples[pre_output_count - 1]["guardFinishedMonotonicNS"]
                and integer(drain["elapsedNS"], True)
                and drain["finishedMonotonicNS"] - drain["startedMonotonicNS"] == drain["elapsedNS"]
                and window(drain["windowBefore"], app_pid) == baseline_window
                and window(drain["windowAfter"], app_pid) == baseline_window, "drain clocks/window failed")
        for offset, sample in zip((0, 1, 5), samples[pre_output_count:]):
            require(sample["actualOffsetNS"] == sample["app"]["startedMonotonicNS"] - drain["finishedMonotonicNS"]
                    and sample["guardStartedMonotonicNS"] >= drain["finishedMonotonicNS"] + offset * 1_000_000_000,
                    "post-output sample happened before its declared phase")
        audit = record["historyVerification"]
        if public:
            finished = check_public_history(run, metadata, record, launch, ready, binding, baseline_window, workload, identity_timebase)
            public_lifetimes.append((launch["startedMonotonicNS"], finished))
        else:
            require(all(audit.get(key) is True for key in ("ok", "matchesExpectedRows", "clipboardRestored",
                    "frontmostOwnedAfter", "ownedExecutableVerified")) and audit.get("ownedPID") == app_pid
                and audit.get("expectedRows") == audit.get("retainedRows") == workload["expectedRows"]
                and audit.get("normalizedSHA256") == audit.get("expectedNormalizedSHA256") == workload["expectedHistorySHA256"],
                    "native exact retained-history/clipboard verification failed")
        require(samples[-1]["guardFinishedMonotonicNS"] <= audit["hostStartedMonotonicNS"]
                <= audit["nativeStartedMonotonicNS"] <= audit["nativeFinishedMonotonicNS"]
                <= audit["hostFinishedMonotonicNS"], "native history audit did not follow every memory sample")
        collected["idle"][block][terminal].append(samples[1]["app"])
        collected[name][block][terminal].append(samples[-1]["app"])
    require([entry for _, entry in sorted(actual_order, key=lambda item: item[0])] == order,
            "actual launches were not in the preregistered counterbalanced order")
    require(metadata["finalConditions"]["startedMonotonicNS"] >= max(record["historyVerification"]["hostFinishedMonotonicNS"]
            for record in records), "final conditions preceded the completed observations")
    if public:
        require(all(previous[1] < current[0] for previous, current in zip(public_lifetimes, public_lifetimes[1:]))
                and metadata["finalConditions"]["startedMonotonicNS"] >= max(end for _, end in public_lifetimes),
                "public worker lifetimes overlap or final conditions preceded cleanup")
    common = {"path": str(directory), "kind": "memory", "metric": "bytes", "profile": profile,
        "power": metadata["initialConditions"]["power"]["signature"], "binaries": binaries,
        "grid": [120, 36], "display": common_display, "font": machine["font"],
        "fontSHA256": metadata["fontSHA256"], "displays": machine["displays"],
        "observerEnvironment": {key: metadata["initialConditions"]["native"][key]
                                for key in ("lowPowerMode", "thermalState", "os")},
        "hardware": metadata["hardware"]["stdout"],
        "memoryProtocol": {"idleSeconds": 5, "postOutputSeconds": 5, "allIdleBaselinesIncluded": True,
                           "preregisteredCases": cases, "historyAuditAfterSamples": True}}
    result = []
    for name, groups in collected.items():
        for metric, field in METRICS.items():
            result.append({**common, "case": "memory/" + CASE_IDS.get(name, name) + "/" + metric,
                "memoryMetric": field, "blocks": {block: {terminal: [sample[field] for sample in groups[block][terminal]]
                    for terminal in TERMINALS} for block in block_ids}})
    # A one-case smoke cannot choose a favorable fresh idle process. Historical
    # schema 2 has no settled CPU interval and remains memory-only.
    if has_idle_cpu and cases == list(CASES):
        result.append({**common, "kind": "cpu", "metric": "cpuTime", "case": "idle-cpu",
                       "unit": "CPU nanoseconds per wall second", "blocks": cpu,
                       "cpuProtocol": {"settleSeconds": 5, "idleSeconds": 5,
                           "maximumActualIntervalSeconds": 6, "allIdleBaselinesIncluded": True,
                           "metric": IDLE_CPU_METRIC}})
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--cmdy-sha256", required=True)
    parser.add_argument("--ghostty-sha256", required=True)
    parser.add_argument("--output", type=Path, help="new adapter JSON; never overwrites an existing file")
    args = parser.parse_args(argv)
    try:
        result = load_memory_evidence(args.evidence, {"cmdy": args.cmdy_sha256, "ghostty": args.ghostty_sha256})
        if args.output:
            with args.output.open("x") as stream:
                stream.write(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
        print(json.dumps({"valid": True, "cases": [item["case"] for item in result],
                          "blocks": len(result[0]["blocks"]), "decisionPolicy": "caller/parity_gate.py"}))
        return 0
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print("Memory evidence invalid: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
