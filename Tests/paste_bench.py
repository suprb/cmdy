#!/usr/bin/env python3
"""Clipboard-free public paste insertion recorder. Requires an exclusive GUI slot.

This file does not run at import. Native permission preflight never prompts;
only a separately authorized invocation may launch owned terminal applications.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from competitive_bench import (BenchOptions, TerminalSession, atomic_json, binary_metadata,
    block_order, command_result, native_condition_signature, power_snapshot, sha256, window_command)
from paste_protocol import BLOCKS, GRID, INITIAL_SETTLE_NS, METRIC, SAMPLES, WARMUPS, preparation
from paste_contract import config_text, registered_configs, validate_launch
from paste_dictionary import installed_definition, validate_sdef
from paste_build import OBSERVER_SOURCES
from scroll_bench import check_power, check_source_manifest, control, stop_fixture, require, read, hash_bytes

HERE = Path(__file__).resolve().parent
SOURCES = ("paste_bench.py", "paste_protocol.py", "paste_worker.py", "paste_parity_evidence.py", "paste_contract.py",
    "paste_dictionary.py", "paste_build.py", "paste_apple_event.swift", "paste_observer.swift", "paste_raster.swift",
    "paste_observation.swift", "test_paste_native.swift", "BenchKernelAncestry.swift", "bench_ancestry.py",
    "competitive_bench.py", "terminal_bench_worker.py", "TerminalBenchWindow.swift", "ScrollNativeObservation.swift",
    "ScrollRaster.swift", "ScrollWindowGeometry.swift", "ScrollObservationRuntime.swift", "scroll_bench.py",
    "scroll_protocol.py", "scroll_contract.py", "scroll_public_config.py", "scroll_parity_evidence.py")
FROZEN_EXTRAS = {"paste-observer", "window-helper", "observer-build.json", "observer-qualification.json", "cmdy.sdef", "ghostty.sdef"}


def normalized_config_hash(terminal, options):
    return hash_bytes(config_text(terminal, options, Path("<isolated-cwd>")).encode())


def run_owned(options, helper, observer, terminal, directory, token, metadata, *, prepare_window=None):
    fixture = directory / "fixture"
    record = {"status": "invalid", "terminal": terminal, "token": token,
              "startedUTC": datetime.now(timezone.utc).isoformat()}
    socket_dir = tempfile.TemporaryDirectory(prefix="cmdy-paste-", dir="/private/tmp")
    socket_path = Path(socket_dir.name) / "control.sock"
    session = None
    original_error = None
    try:
        command = [metadata["runtime"]["python"]["path"], "-S", str(options.tooling_dir / "paste_worker.py"), "--output", str(fixture),
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
        generated = preparation(token)
        require(prepared["payloadSHA256"] == hash_bytes(generated) and prepared["payloadBytes"] == len(generated)
                and prepared["dsrReplyHex"] == b"\x1b[36;1R".hex(), "generated setup bytes/DSR differ")
        # DSR confirms parser progress, not presentation of the complete grid.
        # Both terminals get the same fixed untimed preparation interval before
        # capture/calibration. Input dispatch and response timestamps are unchanged.
        settling = {"requestedNS": INITIAL_SETTLE_NS, "startedMonotonicNS": time.perf_counter_ns()}
        time.sleep(INITIAL_SETTLE_NS / 1_000_000_000)
        settling["finishedMonotonicNS"] = time.perf_counter_ns()
        atomic_json(directory / "pre-capture-settling.json", settling)
        record["preCaptureSettlingSHA256"] = sha256(directory / "pre-capture-settling.json")
        binary = options.cmdy_bin if terminal == "cmdy" else options.ghostty_bin
        spec = {"appPID": session.app_pid, "workerPID": session.worker_identity[0],
                "ttyPath": session.ready["ttyPath"], "windowID": window["windows"][0]["windowID"],
                "displayID": metadata["displayID"], "executable": str(binary),
                "executableSHA256": metadata["binaries"][terminal]["sha256"], "socketPath": str(socket_path),
                "token": token, "requestedFPS": 120, "timeoutSeconds": 10}
        atomic_json(directory / "observer-spec.json", spec)
        validate_launch(directory, metadata, read(directory / "launch.json"), spec)
        observer_command = [str(observer), "--spec", str(directory / "observer-spec.json"),
                            "--output", str(directory / "observation.json")]
        with (directory / "observer.log").open("xb") as log:
            result = subprocess.run(observer_command, stdin=subprocess.DEVNULL, stdout=log, stderr=log, timeout=540)
        record["observerReturncode"] = result.returncode
        require(result.returncode == 0, "native paste observer rejected; retained observation failure/log")
        report = read(directory / "observation.json")
        require(report["status"] == "valid", "native observer is incomplete")
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
    for flag in ("output", "cmdy-bin", "ghostty-bin", "cmdy-source-manifest", "cmdy-source-root", "observer-build", "window-helper"):
        value.add_argument("--" + flag, type=Path, required=True)
    for flag in ("cmdy-sha256", "ghostty-sha256"):
        value.add_argument("--" + flag, required=True)
    value.add_argument("--display-id", type=int, required=True)
    value.add_argument("--power-source", choices=("AC Power", "Battery Power"), default="AC Power")
    value.add_argument("--profile", choices=("matched", "cmdy-defaults"), default="matched")
    value.add_argument("--first", choices=("cmdy", "ghostty"), default="cmdy")
    value.add_argument("--pilot-only", action="store_true", help="unpooled paired transport/full-frame pilot; never admitted to parity")
    value.add_argument("--internal-frozen", action="store_true", help=argparse.SUPPRESS)
    return value


def validate_observer_build(build, qualification, hashes):
    require(build["nativeObservationRun"] is False and build["binarySHA256"] == hashes["paste-observer"]
            and set(build["sourceSHA256"]) == set(OBSERVER_SOURCES)
            and all(hashes.get(name) == value for name, value in build["sourceSHA256"].items()),
            "observer binary/build receipt is not bound to retained native source")
    command = build["command"]
    require(command[:6] == ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5"]
            and [Path(name).name for name in command[6:-2]] == OBSERVER_SOURCES
            and command[-2] == "-o" and Path(command[-1]).name == "paste-observer", "observer build command differs")
    require(qualification["status"] == "pass" and qualification["sourcesUnchanged"] is True
            and qualification["nativeObservationRun"] is False and qualification["appleEventsSent"] is False
            and qualification["permissionQueriesRun"] is False
            and all(hashes.get(name) == value for name, value in qualification["sourceSHA256"].items())
            and [row["name"] for row in qualification["commands"]]
                == ["build-paste-observer", "build-paste-native-tests", "check-paste-native"]
            and all(row["exitCode"] == 0 and row["exitedAndReaped"] is True for row in qualification["commands"]),
            "observer synthetic headless qualification failed or source changed")


def finish_audit(metadata, args, options, helper, probe, frozen, output):
    metadata["powerAfter"] = power_snapshot(); check_power(metadata["powerAfter"], args.power_source, metadata["powerBefore"]["signature"])
    metadata["nativeAfter"] = window_command(helper, "conditions")
    require(native_condition_signature(metadata["nativeAfter"]) == native_condition_signature(metadata["nativeBefore"]), "native conditions changed")
    metadata["machineAfter"] = window_command(helper, "probe", 14)
    require(all(metadata["machineAfter"][key] == probe[key] for key in ("font", "displays"))
            and sha256(Path(probe["font"]["file"])) == metadata["fontSHA256"], "font/display changed")
    metadata["sourceAfter"] = check_source_manifest(output / "app-source-manifest.json", args.cmdy_source_root)
    require(metadata["sourceAfter"] == metadata["sourceBefore"], "app source binding changed")
    require(all(binary_metadata(Path(value["path"])) == value for value in metadata["binaries"].values()), "binary/plist changed")
    require(all(installed_definition(Path(metadata["binaries"][name]["path"]))[1]
                == validate_sdef((HERE / (name + ".sdef")).read_bytes()) for name in ("cmdy", "ghostty")), "dictionary changed")
    require(all(sha256(HERE / name) == expected for name, expected in frozen.items()), "frozen tooling changed")
    metadata["finishedUTC"] = datetime.now(timezone.utc).isoformat()


def run_registered_blocks(options, helper, observer, output, metadata, expected_binaries):
    # Independent admission is a precondition for every dependent measured run.
    # A producer's status flag cannot start a six-block comparison by itself.
    from paste_parity_evidence import validate_pilot_checkpoint_evidence
    admission = validate_pilot_checkpoint_evidence(output, expected_binaries)
    require(read(output / "pilot-admission.json") == admission,
            "paired pilot checkpoint was not independently admitted")
    for block in range(BLOCKS):
        token = uuid.uuid4().hex
        for terminal in block_order(block, metadata["first"]):
            directory = output / "runs" / f"{block:02d}-{terminal}"
            print(f"Paste insertion block {block + 1}/{BLOCKS}: {terminal}, {options.profile}", flush=True)
            run_owned(options, helper, observer, terminal, directory, token, metadata)
            metadata["runs"].append({"block": block, "terminal": terminal, "token": token,
                "path": str(directory.relative_to(output)), "runSHA256": sha256(directory / "run.json"),
                "observationSHA256": sha256(directory / "observation.json")})
            atomic_json(output / "manifest.json", metadata)


def main(argv=None):
    args = parser().parse_args(argv)
    output = args.output.expanduser().resolve()
    if not args.internal_frozen:
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
        tooling = output / "tooling"; tooling.mkdir()
        for name in SOURCES:
            shutil.copy2(HERE / name, tooling / name)
        for source, name in ((args.observer_build / "paste-observer", "paste-observer"),
                             (args.observer_build / "paste-observer-build.json", "observer-build.json"),
                             (args.observer_build / "results.json", "observer-qualification.json"),
                             (args.window_helper, "window-helper")):
            shutil.copy2(source, tooling / name)
        for name, binary in (("cmdy", args.cmdy_bin), ("ghostty", args.ghostty_bin)):
            path, _ = installed_definition(binary)
            shutil.copy2(path, tooling / (name + ".sdef"))
        shutil.copy2(args.cmdy_source_manifest, output / "app-source-manifest.json")
        hashes = {path.name: sha256(path) for path in tooling.iterdir() if path.is_file()}
        validate_observer_build(read(tooling / "observer-build.json"), read(tooling / "observer-qualification.json"), hashes)
        atomic_json(output / "tooling-freeze.json", hashes)
        os.execv(sys.executable, [sys.executable, "-S", str(tooling / "paste_bench.py"),
            *(argv if argv is not None else sys.argv[1:]), "--internal-frozen"])
    require(HERE == output / "tooling", "frozen recorder must run inside its new evidence tooling directory")
    frozen = read(output / "tooling-freeze.json")
    require(set(frozen) == set(SOURCES) | FROZEN_EXTRAS
            and all(sha256(HERE / name) == expected for name, expected in frozen.items()), "frozen tooling drift")
    require(not (output / "manifest.json").exists(), "existing evidence cannot be overwritten")
    helper, observer = HERE / "window-helper", HERE / "paste-observer"
    options = BenchOptions(args.cmdy_bin.resolve(), args.ghostty_bin.resolve(), profile=args.profile,
                           font_size=14, timeout=60, tooling_dir=HERE)
    metadata = {"schemaVersion": 1, "benchmarkKind": "paste", "state": "invalid", "metric": METRIC,
        "diagnostic": False, "profile": args.profile, "startedUTC": datetime.now(timezone.utc).isoformat(),
        "controllerPID": os.getpid(), "requestedBlocks": BLOCKS, "samplesPerBlock": SAMPLES,
        "warmupsPerBlock": WARMUPS, "grid": list(GRID), "displayID": args.display_id,
        "first": args.first, "pilotOnly": args.pilot_only, "binaries": {}, "dictionaries": {},
        "toolingSHA256": frozen, "toolingDirectory": str(HERE), "pilots": {}, "runs": [],
        "runtime": {"pythonVersion": sys.version, "python": binary_metadata(Path(sys.executable)),
                    "shell": binary_metadata(Path("/bin/zsh")), "workerPythonFlags": ["-S"]},
        "hardware": command_result(["/usr/sbin/sysctl", "hw.model", "hw.memsize", "hw.physicalcpu", "hw.logicalcpu", "machdep.cpu.brand_string"])}
    atomic_json(output / "manifest.json", metadata)
    try:
        for terminal, binary, pin in (("cmdy", options.cmdy_bin, args.cmdy_sha256), ("ghostty", options.ghostty_bin, args.ghostty_sha256)):
            require(re.fullmatch("[0-9a-f]{64}", pin) and sha256(binary) == pin, "app binary differs from preregistered pin")
            metadata["binaries"][terminal] = binary_metadata(binary)
            path, definition = installed_definition(binary)
            require(definition == validate_sdef((HERE / (terminal + ".sdef")).read_bytes()), "bundle dictionary changed")
            metadata["dictionaries"][terminal] = dict(definition, path=str(path))
        metadata["sourceBefore"] = check_source_manifest(output / "app-source-manifest.json", args.cmdy_source_root)
        metadata["powerBefore"] = power_snapshot(); check_power(metadata["powerBefore"], args.power_source)
        metadata["nativeBefore"] = window_command(helper, "conditions"); native_condition_signature(metadata["nativeBefore"])
        probe = window_command(helper, "probe", 14)
        require(probe.get("ok") is True and probe["font"]["postScriptName"] == "Menlo-Regular"
                and probe["font"]["sizePoints"] == 14 and probe["accessibilityTrusted"]
                and probe["screenCaptureAuthorized"], "font or existing setup/capture permissions unavailable")
        require(any(item["displayID"] == args.display_id for item in probe["displays"]), "selected display is missing")
        metadata["machine"] = probe; metadata["fontSHA256"] = sha256(Path(probe["font"]["file"]))
        metadata["state"] = "running"; atomic_json(output / "manifest.json", metadata)
        token = uuid.uuid4().hex
        for terminal in block_order(0, args.first):
            directory = output / "pilot" / terminal
            run_owned(options, helper, observer, terminal, directory, token, metadata)
            metadata["pilots"][terminal] = {"path": str(directory.relative_to(output)), "token": token,
                "runSHA256": sha256(directory / "run.json"), "observationSHA256": sha256(directory / "observation.json")}
            atomic_json(output / "manifest.json", metadata)
        checkpoint = dict(metadata, state="pilot-complete-unpooled", pilotOnly=True, runs=[])
        finish_audit(checkpoint, args, options, helper, probe, frozen, output)
        atomic_json(output / "pilot-checkpoint.json", checkpoint)
        from paste_parity_evidence import validate_pilot_checkpoint_evidence
        admission = validate_pilot_checkpoint_evidence(output, {"cmdy": args.cmdy_sha256, "ghostty": args.ghostty_sha256})
        atomic_json(output / "pilot-admission.json", admission)
        metadata["pilotCheckpointSHA256"] = sha256(output / "pilot-checkpoint.json")
        metadata["pilotAdmissionSHA256"] = sha256(output / "pilot-admission.json")
        atomic_json(output / "manifest.json", metadata)
        if not args.pilot_only:
            run_registered_blocks(options, helper, observer, output, metadata,
                                  {"cmdy": args.cmdy_sha256, "ghostty": args.ghostty_sha256})
        finish_audit(metadata, args, options, helper, probe, frozen, output)
        metadata["state"] = "pilot-complete-unpooled" if args.pilot_only else "complete"
        metadata["finishedUTC"] = datetime.now(timezone.utc).isoformat(); atomic_json(output / "manifest.json", metadata)
        from paste_parity_evidence import load_paste_evidence, validate_pilot_evidence
        if args.pilot_only:
            validate_pilot_evidence(output, {"cmdy": args.cmdy_sha256, "ghostty": args.ghostty_sha256})
        else:
            load_paste_evidence(output, {"cmdy": args.cmdy_sha256, "ghostty": args.ghostty_sha256})
        return 0
    except BaseException as error:
        metadata.update(state="invalid", error=str(error), failedUTC=datetime.now(timezone.utc).isoformat())
        atomic_json(output / "manifest.json", metadata); raise


if __name__ == "__main__":
    # execv resets caught signals. Reinstall this in the frozen recorder so
    # supervisor cancellation unwinds run_owned and preserves cleanup evidence.
    def interrupted(*_):
        raise KeyboardInterrupt("owned paste comparison interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
