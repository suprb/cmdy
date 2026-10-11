#!/usr/bin/env python3
"""Native scroll comparison. Runtime requires an exclusive GUI slot.

One discrete wheel event moves exactly three generated rows, with all 36 row
codes validated. Calibration is unpooled. A full run is six alternating paired
blocks of 40 measured events per app; counts and thresholds are not configurable.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

from competitive_bench import (BenchOptions, TerminalSession, atomic_json, binary_metadata,
    block_order, command_result, is_descendant, native_condition_signature, power_snapshot,
    process_identity, sha256, terminal_config, window_command)
from scroll_protocol import (BLOCKS, GRID, SAMPLES, WheelCalibration, payload,
    profile_overrides, validate_paired_calibration)
from scroll_contract import config_text, registered_configs, validate_launch
from scroll_public_config import SCOPE, discrete_multiplier, selected_values, validate_public_policy

HERE = Path(__file__).resolve().parent
METRIC = "synthetic-wheel-to-first-complete-three-row-viewport-frame"
SOURCES = ("scroll_public_config.py", "scroll_bench.py", "scroll_protocol.py", "scroll_worker.py", "scroll_parity_evidence.py", "scroll_contract.py",
    "BenchKernelAncestry.swift", "bench_ancestry.py",
    "competitive_bench.py", "terminal_bench_worker.py", "TerminalBenchWindow.swift",
    "ScrollNativeObservation.swift", "ScrollRaster.swift", "ScrollWindowGeometry.swift", "ScrollObservationRuntime.swift", "ScrollObserverMain.swift")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(Path(path).read_text())


def hash_bytes(value):
    return hashlib.sha256(value).hexdigest()


def normalized_config_hash(terminal, options):
    return hash_bytes(config_text(terminal, options, Path("<isolated-cwd>")).encode())


def validate_raw_calibration(directory, metadata, terminal):
    """Apply the final raw reader before admitting any measured launch."""
    from scroll_parity_evidence import checked_report
    checked_at = datetime.now(timezone.utc).isoformat()
    # The batch is still running. Bound this raw run by the actual checkpoint
    # time without recording a fictitious batch completion in the manifest.
    checked_report(directory, {**metadata, "finishedUTC": checked_at}, terminal, True)
    return {"status": "valid-unpooled-raw-calibration", "checkedUTC": checked_at,
            "runSHA256": sha256(directory / "run.json"),
            "observationSHA256": sha256(directory / "observation.json")}


def check_power(snapshot, source, reference=None):
    signature = snapshot.get("signature", {})
    require(signature.get("source") == source and isinstance(signature.get("settings"), str)
            and signature["settings"], "wrong or missing selected power source/settings")
    if reference is not None:
        require(signature == reference, "power source/settings changed")
    return signature


def check_source_manifest(path, root):
    manifest = read(path)
    require(isinstance(manifest.get("sources"), dict) and manifest["sources"], "empty app source manifest")
    require(Path(manifest["sourceRoot"]).resolve() == root.resolve(), "app source root differs from frozen manifest")
    for name, expected in manifest["sources"].items():
        relative = Path(name)
        require(not relative.is_absolute() and ".." not in relative.parts, "unsafe source manifest path")
        actual = (root / relative).resolve()
        require(actual.is_relative_to(root.resolve()) and re.fullmatch("[0-9a-f]{64}", expected)
                and sha256(actual) == expected, "app build input drift: " + name)
    return {"manifestSHA256": sha256(path), "sourceCount": len(manifest["sources"]),
            "status": "valid", "sourceRoot": str(root.resolve())}


def control(path, token, command, timeout=35):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(timeout)
        peer.connect(str(path))
        peer.sendall(json.dumps({"command": command, "token": token}).encode() + b"\n")
        data = bytearray()
        while not data.endswith(b"\n") and len(data) < 4096:
            part = peer.recv(4096 - len(data))
            require(bool(part), "fixture control response ended early")
            data.extend(part)
    require(data.endswith(b"\n"), "fixture control response exceeds bound")
    result = json.loads(data)
    require(result.get("ok") is True and result.get("unexpectedInputBytes") == 0,
            "fixture control rejected or received unexpected input")
    return result


def stop_fixture(session, fixture, socket_path, token):
    record = {"complete": False, "requestedMonotonicNS": time.monotonic_ns()}
    try:
        require(session.worker_identity is not None, "no verified owned fixture identity")
        pid, identity = session.worker_identity
        require(process_identity(pid) == identity and is_descendant(pid, session.app_pid), "fixture identity changed before finish")
        record["request"] = control(socket_path, token, "finish")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if (fixture / "final.json").is_file() and process_identity(pid) != identity:
                final = read(fixture / "final.json")
                require(final.get("status") == "stopped" and final.get("stopReason") == "control-finish"
                    and final.get("terminalModeRestored") is True and final.get("fileFlagsRestored") is True
                    and final.get("unexpectedInputBytes") == 0, "fixture final record failed")
                record.update(complete=True, workerExited=True, finalSHA256=sha256(fixture / "final.json"))
                return record
            time.sleep(0.025)
        raise TimeoutError("owned fixture did not publish final evidence and exit")
    finally:
        record["finishedMonotonicNS"] = time.monotonic_ns()
        atomic_json(session.directory / "fixture-stop.json", record)


def ghostty_scroll_policy(session, binary, profile):
    # Two documented CLI actions: installed defaults without user config,
    # and validation of this exact owned file. No live-GUI introspection claim.
    record = {"schemaVersion": 2, "scope": SCOPE,
              "binarySHA256Before": sha256(binary),
              "configSHA256Before": sha256(session.config_path)}
    wanted_config = session.config_path.read_text()
    def query(arguments, default=False):
        started = time.monotonic_ns()
        process = subprocess.run(arguments, env=session.environment, cwd=session.cwd,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        result = {"arguments": arguments, "returncode": process.returncode,
                  "stderr": process.stderr, "startedMonotonicNS": started,
                  "finishedMonotonicNS": time.monotonic_ns()}
        if default:
            result["selectedValues"] = selected_values(process.stdout)
        else:
            result["stdout"] = process.stdout
        return result
    try:
        record["defaultQuery"] = query([str(binary), "+show-config", "--default"], default=True)
        record["configurationValidation"] = query(
            [str(binary), "+validate-config", f"--config-file={session.config_path}"])
        default = discrete_multiplier(record["defaultQuery"]["selectedValues"].get("mouse-scroll-multiplier"))
        configured = selected_values(wanted_config).get("mouse-scroll-multiplier")
        record["policy"] = {"installedDefaultDiscreteMultiplier": default,
            "validatedDiscreteMultiplier": discrete_multiplier(configured) if configured else default,
            "policyOrigin": "validated-explicit-override" if configured else "installed-default"}
        record["binarySHA256After"] = sha256(binary)
        record["configSHA256After"] = sha256(session.config_path)
        validate_public_policy(record, str(binary), record["binarySHA256Before"],
                               str(session.config_path), wanted_config, profile)
        return record
    finally:
        atomic_json(session.directory / "public-config-query.json", record)


def run_owned(options, helper, observer, terminal, directory, token, metadata, mapping=None, *, prepare_window=None):
    fixture = directory / "fixture"
    record = {"status": "invalid", "terminal": terminal, "token": token,
              "mode": "measure" if mapping else "calibrate", "startedUTC": datetime.now(timezone.utc).isoformat()}
    socket_dir = tempfile.TemporaryDirectory(prefix="cmdy-scroll-", dir="/private/tmp")
    socket_path = Path(socket_dir.name) / "control.sock"
    session = None
    original_error = None
    try:
        command = [metadata["runtime"]["python"]["path"], "-S", str(options.tooling_dir / "scroll_worker.py"), "--output", str(fixture),
                   "--socket", str(socket_path), "--token", token, "--timeout", "600"]
        session = TerminalSession(options, helper, terminal, directory, GRID,
                                  fixture_command=command, ready_path=fixture / "ready.json")
        session.config_path.write_text(config_text(terminal, options, session.cwd))
        atomic_json(directory / "config-before-launch.json", {
            name: sha256(directory / name) for name in sorted(registered_configs(terminal))})
        record["configBeforeLaunchSHA256"] = sha256(directory / "config-before-launch.json")
        record["canonicalConfigSHA256"] = normalized_config_hash(terminal, options)
        record["powerBefore"] = power_snapshot()
        record["nativeBefore"] = window_command(helper, "conditions")
        check_power(record["powerBefore"], metadata["powerBefore"]["signature"]["source"], metadata["powerBefore"]["signature"])
        require(native_condition_signature(record["nativeBefore"]) == native_condition_signature(metadata["nativeBefore"]),
                "native conditions differ before launch")
        if terminal == "ghostty":
            policy = ghostty_scroll_policy(session, options.ghostty_bin, options.profile)
            record["publicConfigQuerySHA256"] = sha256(directory / "public-config-query.json")
            record["validatedDiscreteMultiplier"] = policy["policy"]["validatedDiscreteMultiplier"]
            record["discretePolicyOrigin"] = policy["policy"]["policyOrigin"]
            if options.profile == "matched":
                require(record["validatedDiscreteMultiplier"] == 1, "matched discrete multiplier is not one")
        session.launch()
        require(session.worker_identity is not None, "launched fixture identity was not verified")
        session.window(activate=True)  # Bounded setup only; no timed activation.
        session.place_window(120, 120)
        session.fit_grid(GRID, allow_resize=True)
        if prepare_window is not None:
            prepare_window(session)  # Owned setup only, before observation begins.
        window = session.window()
        require(window["windows"][0]["displayID"] == metadata["displayID"], "wrong selected display")
        atomic_json(directory / "window-before.json", window)
        actual = session.grid()
        require([actual["columns"], actual["rows"]] == list(GRID), "final native grid differs")
        atomic_json(directory / "grid-before.json", actual)
        atomic_json(directory / "prepare-control.json", control(socket_path, token, "prepare"))
        prepared = read(fixture / "prepared.json")
        generated = payload(token)
        require(prepared["payloadSHA256"] == hash_bytes(generated) and prepared["payloadBytes"] == len(generated)
                and prepared["dsrReplyHex"] == b"\x1b[36;1R".hex(), "generated setup bytes/DSR differ")
        binary = options.cmdy_bin if terminal == "cmdy" else options.ghostty_bin
        spec = {"mode": record["mode"], "appPID": session.app_pid, "workerPID": session.worker_identity[0],
                "ttyPath": session.ready["ttyPath"], "windowID": window["windows"][0]["windowID"],
                "displayID": metadata["displayID"], "executable": str(binary),
                "executableSHA256": metadata["binaries"][terminal]["sha256"], "socketPath": str(socket_path),
                "token": token, "requestedFPS": 120, "timeoutSeconds": 10,
                "upwardRawDelta": mapping.upward_raw_delta if mapping else None,
                "downwardRawDelta": mapping.downward_raw_delta if mapping else None}
        atomic_json(directory / "observer-spec.json", spec)
        validate_launch(directory, metadata, read(directory / "launch.json"), spec)
        observer_command = [str(observer), "--spec", str(directory / "observer-spec.json"),
                            "--output", str(directory / "observation.json")]
        with (directory / "observer.log").open("xb") as log:
            result = subprocess.run(observer_command, stdin=subprocess.DEVNULL, stdout=log, stderr=log, timeout=540)
        record["observerReturncode"] = result.returncode
        require(result.returncode == 0, "native scroll observer rejected; retained observation failure/log")
        report = read(directory / "observation.json")
        require(report["status"] == ("valid" if mapping else "valid-unpooled-calibration"), "native observer is incomplete")
        validate_launch(directory, metadata, read(directory / "launch.json"), spec)
        atomic_json(directory / "grid-after.json", session.grid())
        atomic_json(directory / "window-after.json", session.window())
        stop_fixture(session, fixture, socket_path, token)
        record.update(status="valid", observationSHA256=sha256(directory / "observation.json"),
                      preparedSHA256=sha256(fixture / "prepared.json"))
        return report, record
    except BaseException as error:
        original_error = error
        record["error"] = str(error)
        raise
    finally:
        # Explicit graceful finish is part of valid evidence. On failure the
        # shared context only signals verified descendants/Popen-owned apps.
        if session is not None:
            try:
                session.close()
            except Exception as cleanup_error:
                record["cleanupError"] = str(cleanup_error)
                if original_error is None:
                    record["status"] = "invalid"
                    original_error = cleanup_error
            try:
                record["powerAfter"] = power_snapshot()
                record["nativeAfter"] = window_command(helper, "conditions")
                check_power(record["powerAfter"], metadata["powerBefore"]["signature"]["source"], metadata["powerBefore"]["signature"])
                require(native_condition_signature(record["nativeAfter"]) == native_condition_signature(metadata["nativeBefore"]),
                        "native conditions changed during owned run")
            except Exception as condition_error:
                record["conditionError"] = str(condition_error)
                record["status"] = "invalid"
                if original_error is None:
                    original_error = condition_error
            record["finishedUTC"] = datetime.now(timezone.utc).isoformat()
            atomic_json(directory / "run.json", record)
        socket_dir.cleanup()
        if original_error is not None and record.get("error") is None:
            raise original_error


def parser():
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--output", type=Path, required=True)
    value.add_argument("--cmdy-bin", type=Path, required=True)
    value.add_argument("--ghostty-bin", type=Path, required=True)
    value.add_argument("--cmdy-sha256", required=True)
    value.add_argument("--ghostty-sha256", required=True)
    value.add_argument("--cmdy-source-manifest", type=Path, required=True)
    value.add_argument("--cmdy-source-root", type=Path, required=True)
    value.add_argument("--observer", type=Path, required=True)
    value.add_argument("--window-helper", type=Path, required=True)
    value.add_argument("--display-id", type=int, required=True)
    value.add_argument("--power-source", choices=("AC Power", "Battery Power"), default="AC Power")
    value.add_argument("--profile", choices=("matched", "cmdy-defaults"), default="matched")
    value.add_argument("--first", choices=("cmdy", "ghostty"), default="cmdy")
    value.add_argument("--calibration-only", action="store_true")
    value.add_argument("--internal-frozen", action="store_true", help=argparse.SUPPRESS)
    return value


def main(argv=None):
    args = parser().parse_args(argv)
    output = args.output.expanduser().resolve()
    if not args.internal_frozen:
        # Run the retained controller as well as the retained worker/helpers.
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
        tooling = output / "tooling"; tooling.mkdir()
        for name in SOURCES:
            shutil.copy2(HERE / name, tooling / name)
        for source, name in ((args.observer, "scroll-observer"), (args.window_helper, "window-helper")):
            shutil.copy2(source, tooling / name)
        shutil.copy2(args.cmdy_source_manifest, output / "app-source-manifest.json")
        atomic_json(output / "tooling-freeze.json", {name: sha256(path) for path in tooling.iterdir()
                                                     if path.is_file() for name in [path.name]})
        os.execv(sys.executable, [sys.executable, "-S", str(tooling / "scroll_bench.py"),
            *(argv if argv is not None else sys.argv[1:]), "--internal-frozen"])
    require(HERE == output / "tooling" and output.is_dir(), "frozen runner can only run from its new evidence tooling directory")
    frozen = read(output / "tooling-freeze.json")
    require(all(sha256(HERE / name) == expected for name, expected in frozen.items()), "frozen tooling drift")
    require(not (output / "manifest.json").exists(), "existing benchmark manifest cannot be overwritten")
    helper, observer = HERE / "window-helper", HERE / "scroll-observer"
    options = BenchOptions(args.cmdy_bin.resolve(), args.ghostty_bin.resolve(), profile=args.profile,
        font_size=14, timeout=60, tooling_dir=HERE)
    metadata = {"schemaVersion": 1, "benchmarkKind": "scroll", "state": "invalid", "metric": METRIC,
        "diagnostic": False, "profile": args.profile, "startedUTC": datetime.now(timezone.utc).isoformat(),
        "controllerPID": os.getpid(),
        "requestedBlocks": BLOCKS, "samplesPerBlock": SAMPLES, "warmupsPerBlock": 2, "grid": list(GRID),
        "displayID": args.display_id, "first": args.first, "calibrationOnly": args.calibration_only,
        "binaries": {}, "toolingSHA256": frozen, "toolingDirectory": str(HERE), "calibrations": {}, "runs": [],
        "runtime": {"pythonVersion": sys.version, "python": binary_metadata(Path(sys.executable)),
                    "shell": binary_metadata(Path("/bin/zsh")), "workerPythonFlags": ["-S"]},
        "hardware": command_result(["/usr/sbin/sysctl", "hw.model", "hw.memsize", "hw.physicalcpu", "hw.logicalcpu", "machdep.cpu.brand_string"])}
    atomic_json(output / "manifest.json", metadata)
    try:
        for terminal, binary, pin in (("cmdy", options.cmdy_bin, args.cmdy_sha256), ("ghostty", options.ghostty_bin, args.ghostty_sha256)):
            require(re.fullmatch("[0-9a-f]{64}", pin) and sha256(binary) == pin, "app binary does not match preregistered pin")
            metadata["binaries"][terminal] = binary_metadata(binary)
        metadata["sourceBefore"] = check_source_manifest(output / "app-source-manifest.json", args.cmdy_source_root)
        metadata["powerBefore"] = power_snapshot()
        check_power(metadata["powerBefore"], args.power_source)
        metadata["nativeBefore"] = window_command(helper, "conditions")
        native_condition_signature(metadata["nativeBefore"])
        probe = window_command(helper, "probe", 14)
        require(probe.get("ok") is True and probe["font"]["postScriptName"] == "Menlo-Regular"
            and probe["font"]["sizePoints"] == 14 and probe["accessibilityTrusted"]
            and probe["screenCaptureAuthorized"] and probe["postEventAuthorized"], "font or existing native permissions unavailable")
        require(any(item["displayID"] == args.display_id for item in probe["displays"]), "requested display absent")
        metadata["machine"] = probe
        metadata["fontSHA256"] = sha256(Path(probe["font"]["file"]))
        metadata["state"] = "running"
        atomic_json(output / "manifest.json", metadata)
        calibration_token = uuid.uuid4().hex
        mappings = {}
        for terminal in (args.first, "ghostty" if args.first == "cmdy" else "cmdy"):
            directory = output / "calibration" / terminal
            report, record = run_owned(options, helper, observer, terminal, directory, calibration_token, metadata)
            raw = report["mapping"]
            mapping = WheelCalibration(terminal, args.profile, raw["upwardRawDelta"], raw["downwardRawDelta"],
                raw["rowsPerEvent"], raw["units"], raw["isContinuous"], frozen["scroll_protocol.py"],
                metadata["binaries"][terminal]["sha256"], record["canonicalConfigSHA256"], sha256(directory / "observation.json"),
                report["status"])
            mapping.validate(); mappings[terminal] = mapping
            metadata["calibrations"][terminal] = asdict(mapping)
            atomic_json(output / "manifest.json", metadata)
            metadata.setdefault("rawCalibrationChecks", {})[terminal] = validate_raw_calibration(directory, metadata, terminal)
            atomic_json(output / "manifest.json", metadata)
        validate_paired_calibration(mappings["cmdy"], mappings["ghostty"])
        if not args.calibration_only:
            for block in range(BLOCKS):
                token = uuid.uuid4().hex
                for terminal in block_order(block, args.first):
                    directory = output / "runs" / f"{block:02d}-{terminal}"
                    print(f"Scroll block {block + 1}/{BLOCKS}: {terminal}, {args.profile}", flush=True)
                    report, record = run_owned(options, helper, observer, terminal, directory, token, metadata, mappings[terminal])
                    metadata["runs"].append({"block": block, "terminal": terminal, "token": token,
                        "path": str(directory.relative_to(output)), "runSHA256": sha256(directory / "run.json"),
                        "observationSHA256": sha256(directory / "observation.json")})
                    atomic_json(output / "manifest.json", metadata)
        metadata["powerAfter"] = power_snapshot(); check_power(metadata["powerAfter"], args.power_source, metadata["powerBefore"]["signature"])
        metadata["nativeAfter"] = window_command(helper, "conditions")
        require(native_condition_signature(metadata["nativeAfter"]) == native_condition_signature(metadata["nativeBefore"]), "final native conditions changed")
        metadata["machineAfter"] = window_command(helper, "probe", 14)
        require(all(metadata["machineAfter"][key] == probe[key] for key in ("font", "displays"))
            and sha256(Path(probe["font"]["file"])) == metadata["fontSHA256"], "font/display changed")
        metadata["sourceAfter"] = check_source_manifest(output / "app-source-manifest.json", args.cmdy_source_root)
        require(metadata["sourceAfter"] == metadata["sourceBefore"], "source binding changed")
        require(all(binary_metadata(Path(value["path"])) == value for value in metadata["binaries"].values()), "binary/plist changed")
        require(all(sha256(HERE / name) == expected for name, expected in frozen.items()), "tooling changed")
        metadata["state"] = "calibrated-unpooled" if args.calibration_only else "complete"
        metadata["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        atomic_json(output / "manifest.json", metadata)
        if not args.calibration_only:
            from scroll_parity_evidence import load_scroll_evidence
            load_scroll_evidence(output, {"cmdy": args.cmdy_sha256, "ghostty": args.ghostty_sha256})
        return 0
    except BaseException as error:
        metadata.update(state="invalid", error=str(error), failedUTC=datetime.now(timezone.utc).isoformat())
        atomic_json(output / "manifest.json", metadata)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
