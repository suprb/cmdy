"""Full raw-adapter path using explicitly synthetic temporary records only.

These records are not retained as performance evidence and no process/native
API is called. The test exercises complete six-block admission, then reseals a
damaged record to prove count/endpoint checks go beyond file-hash validation.
"""
from copy import deepcopy
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
from datetime import datetime, timedelta
import shutil
import shlex
import tempfile
import unittest

from competitive_bench import BenchOptions
from scroll_bench import SOURCES, config_text, normalized_config_hash, validate_raw_calibration
from scroll_protocol import WheelCalibration, payload, sample_plan, viewport_sha256
from scroll_parity_evidence import load_scroll_evidence, checked_stability, geometry
from scroll_contract import expected_environment
from test_bench_ancestry import ancestry_fixture

HERE = Path(__file__).resolve().parent


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_records(root):
    tooling = root / "tooling"; tooling.mkdir()
    for name in SOURCES:
        shutil.copy2(HERE / name, tooling / name)
    for name in ("scroll-observer", "window-helper"):
        (tooling / name).write_text("SYNTHETIC UNIT TEST: NOT AN EXECUTABLE\n")
    frozen = {path.name: digest(path) for path in tooling.iterdir()}
    power = {"signature": {"source": "AC Power", "settings": "synthetic settings"}}
    environment = {"lowPowerMode": False, "thermalState": 0, "os": "synthetic test OS"}
    native = {"ok": True, **environment}
    machine = {"font": {"postScriptName": "Menlo-Regular", "sizePoints": 14}, "displays": [{"displayID": 1}]}
    write(root / "app-source-manifest.json", {"sources": {"App/test.swift": "a" * 64}})
    source = {"status": "valid", "sourceCount": 1, "manifestSHA256": digest(root / "app-source-manifest.json")}
    metadata = {"schemaVersion": 1, "benchmarkKind": "scroll", "state": "complete", "diagnostic": False,
        "calibrationOnly": False, "profile": "matched", "metric": "synthetic-wheel-to-first-complete-three-row-viewport-frame",
        "requestedBlocks": 6, "samplesPerBlock": 40, "warmupsPerBlock": 2, "grid": [120, 36], "displayID": 1,
        "controllerPID": 10, "first": "cmdy", "startedUTC": "2026-09-09T00:00:00+00:00", "finishedUTC": "2026-09-09T01:00:00+00:00",
        "binaries": {name: {"sha256": letter * 64, "path": "/synthetic/" + name} for name, letter in (("cmdy", "a"), ("ghostty", "b"))},
        "runtime": {"pythonVersion": "synthetic Python", "python": {"path": "/synthetic/python", "sha256": "c" * 64},
                    "shell": {"path": "/bin/zsh", "sha256": "d" * 64}, "workerPythonFlags": ["-S"]},
        "toolingSHA256": frozen, "toolingDirectory": str(tooling), "sourceBefore": source, "sourceAfter": source,
        "powerBefore": power, "powerAfter": power, "nativeBefore": native, "nativeAfter": native,
        "machine": machine, "machineAfter": machine, "fontSHA256": "e" * 64,
        "hardware": {"stdout": "synthetic unit-test machine"}, "calibrations": {}, "runs": []}
    options = BenchOptions(Path("/synthetic/cmdy"), Path("/synthetic/ghostty"))
    raster = {"width": 252, "height": 240, "columnSamples": [[6 * col + n for n in (1, 2, 4)] for col in range(42)],
              "rowBands": [{"lower": 12 + 6 * row, "upper": 12 + 6 * (row + 1)} for row in range(36)]}
    raster["calibrationSHA256"] = hashlib.sha256(json.dumps(raster, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def run(folder, terminal, token, ordinal, calibration):
        pid = 100 + ordinal * 2
        offset = ordinal * 30_000_000_000
        proof = {"appPID": pid, "windowID": pid, "frontmostPID": pid, "displayID": 1,
                 "processStartSeconds": 1, "processStartMicroseconds": 2, "x": 120, "y": 120, "width": 1000, "height": 750}
        spec = {"appPID": pid, "workerPID": pid + 1, "windowID": pid, "displayID": 1, "token": token,
                "socketPath": f"/private/tmp/cmdy-scroll-synthetic-{ordinal}/control.sock",
                "ttyPath": "/dev/ttys999", "executable": "/synthetic/" + terminal,
                "executableSHA256": metadata["binaries"][terminal]["sha256"], "requestedFPS": 120}
        write(folder / "observer-spec.json", spec)
        app_identity = {"pid": pid, "parentPID": 10, "uid": 501, "startSeconds": 1,
                        "startMicroseconds": 2, "executable": spec["executable"]}
        worker_identity = {"pid": pid + 1, "parentPID": pid if terminal == "cmdy" else pid + 1000,
                           "uid": 501, "startSeconds": 1, "startMicroseconds": 3, "executable": "/synthetic/python"}
        def tty(start):
            return {"status": "valid", "appPID": pid, "workerPID": pid + 1, "ttyPath": spec["ttyPath"],
                "processIdentityValid": True, "workerIsDescendant": True, "columns": 120, "rows": 36,
                "openResult": 0, "windowSizeResult": 0, "fstatResult": 0, "openedDeviceIsCharacter": True,
                "openedDeviceID": 1, "workerControllingDeviceID": 1, "processInfoExpectedBytes": 100,
                "processInfoResult": 100, "workerUID": 501, "observerUID": 501, "workerProcessGroupID": pid + 1,
                "workerForegroundProcessGroupID": pid + 1, "externalTCGetPGRP": -1, "externalTCGetPGRPErrno": 25,
                "startedTicks": offset + start, "finishedTicks": offset + start + 1,
                "ancestry": ancestry_fixture(app_identity, worker_identity, start=offset + start, step=0)[0]}
        probe = {"ok": True, "status": "prepared", "unexpectedInputBytes": 0, "grid": {"columns": 120, "rows": 36}}
        def stable(base, row):
            frames = [{"displayTicks": offset + base + elapsed, "callbackTicks": offset + base + elapsed - 100,
                "windowQueryFinishedTicks": offset + base + elapsed + 100, "window": proof, "firstRow": row,
                "checkedPixels": 27216, "canonicalRowsSHA256": viewport_sha256(token, row)}
                for elapsed in (1_000_000, 2_000_000, 260_000_000)]
            return {"status": "valid", "frames": frames, "stability": {"first": frames[0],
                "lastCorrectDisplayTicks": frames[-1]["displayTicks"], "laterCorrectDistinctFrames": 2,
                "validationFinishedTicks": offset + base + 270_000_000}}
        def action(index, before, after, delta, measured):
            base = (index + 1) * 300_000_000
            value = stable(base, after)
            value.update(status="valid" if measured else "valid-unpooled-mapping", beforeFirstRow=before,
                afterFirstRow=after, rowsMoved=abs(after - before), ttyBefore=tty(base - 2), ttyAfter=tty(base + 270_000_001),
                fixtureBefore=probe, fixtureAfter=probe, windowBefore=proof, windowAfter=proof,
                event={"rawDelta": delta, "units": "line", "isContinuous": False, "sourceUserData": index + 1,
                       "eventTimestamp": offset + base, "eventBeforeTicks": offset + base, "eventAfterTicks": offset + base + 10, "x": 200, "y": 200})
            return value
        # Fixed native clock interval, wholly inside the synthetic UTC audit.
        wall = 1788912000 * 1_000_000_000  # 2026-09-09T00:00:00Z
        report = {"schemaVersion": 2, "benchmarkKind": "scroll", "mode": "calibrate" if calibration else "measure",
            "status": "valid-unpooled-calibration" if calibration else "valid", "metric": metadata["metric"], "grid": [120, 36],
            "specSHA256": digest(folder / "observer-spec.json"), "token": token, "windowGuardFailures": [], "controllerPID": 10,
            "appIdentity": app_identity, "workerIdentity": worker_identity,
            "initialAncestry": ancestry_fixture(app_identity, worker_identity, start=offset + 1)[0],
            "executableSHA256": spec["executableSHA256"], "windowBefore": proof, "windowAfter": proof,
            "environmentBefore": environment, "environmentAfter": environment,
            "clockBefore": {"wallNS": wall + offset + 100, "absoluteTicks": offset + 100, "continuousTicks": offset + 100},
            "clockAfter": {"wallNS": wall + offset + 20_000_000_000, "absoluteTicks": offset + 20_000_000_000, "continuousTicks": offset + 20_000_000_000},
            "timebase": {"numer": 1, "denom": 1}, "geometry": raster, "captureStartTicks": offset + 1000,
            "capture": {"kind": "owned-window", "requestedFPS": 120, "width": 252, "height": 240},
            "ownedChromeGeometrySchema": 1, "ownedChromeGeometryLimit": 4096,
            "ownedChromeGeometry": [
                {"checkedTicks": offset + 500, "rasterDerivedViewportTop": None, "windows": []},
                {"checkedTicks": offset + 1_000_000, "rasterDerivedViewportTop": 157.5, "windows": []}],
            "stabilityNS": 250_000_000, "ttyBefore": tty(100), "ttyAfter": tty(19_000_000_000),
            "fixtureBefore": probe, "fixtureAfter": probe, "initial": stable(0, 964), "samples": [], "warmups": [], "mappingAttempts": [],
            "mapping": {"rowsPerEvent": 3, "units": "line", "isContinuous": False, "upwardRawDelta": 3, "downwardRawDelta": -3}}
        if calibration:
            for delta in (1, 2, 3):
                report["mappingAttempts"].append(action((delta - 1) * 2, 964, 964 - delta, delta, False))
                report["mappingAttempts"].append(action((delta - 1) * 2 + 1, 964 - delta, 964, -delta, False))
        else:
            for index in range(2):
                value = action(index, 964 - index * 3, 961 - index * 3, 3, True)
                value.update(warmup=True, sequence=index); report["warmups"].append(value)
            for plan in sample_plan():
                value = action(plan["sequence"] + 2, plan["beforeFirstRow"], plan["afterFirstRow"], 3 if plan["direction"] < 0 else -3, True)
                value.update(warmup=False, sequence=plan["sequence"]); report["samples"].append(value)
        groups = [report["initial"], *report["warmups"], *report["samples"], *report["mappingAttempts"]]
        report.update(captureStatusSchema=1, captureStatusLimit=65536,
            captureStatuses=[{"callbackTicks": frame["callbackTicks"], "displayTicks": frame["displayTicks"],
                "statusRaw": 0, "sampleIsValid": True, "hasImageBuffer": True, "generation": generation,
                "armedAfterTicks": group.get("event", {}).get("eventBeforeTicks", report["captureStartTicks"])}
                for generation, group in enumerate(groups, start=1) for frame in group["frames"]])
        write(folder / "observation.json", report)
        cwd = Path(f"/private/tmp/cmdy-drain-synthetic-{ordinal}/work")
        domain = f"com.cmdy.bench.{ordinal:032x}"
        config = folder / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
        config.parent.mkdir(parents=True, exist_ok=True); config.write_text(config_text(terminal, options, cwd))
        launch = {"appPID": pid, "workerPID": pid + 1, "terminal": terminal, "profile": "matched",
            "environment": expected_environment(folder, cwd, domain), "cwd": str(cwd), "defaultsDomain": domain,
            "config": str(config), "readyPath": str(folder / "fixture/ready.json"),
            "arguments": [metadata["binaries"][terminal]["path"]] + (["--config-default-files=false", f"--config-file={config}"] if terminal == "ghostty" else []),
            "startedMonotonicNS": ordinal * 30_000_000_000, "configSHA256": digest(config),
            "fixtureCommand": ["/synthetic/python", "-S", str(tooling / "scroll_worker.py"), "--output", str(folder / "fixture"),
                               "--socket", spec["socketPath"], "--token", token, "--timeout", "600"]}
        (folder / "zsh").mkdir()
        (folder / "zsh/.zshenv").write_text("unsetopt RCS\nexec " + shlex.join(launch["fixtureCommand"]) + "\n")
        write(folder / "config-before-launch.json", {
            str(path.relative_to(folder)): digest(path) for path in [config, folder / "zsh/.zshenv"]})
        write(folder / "launch.json", launch)
        shared_window = {"ok": True, "pid": pid, "frontmostPID": pid, "windows": [{"onScreen": True, "ownerPID": pid,
            "windowID": pid, "displayID": 1, "bounds": {key: proof[key] for key in ("x", "y", "width", "height")}}]}
        for phase in ("before", "after"):
            write(folder / f"window-{phase}.json", shared_window)
            write(folder / f"grid-{phase}.json", {"columns": 120, "rows": 36})
        generated = payload(token)
        worker = {"pid": pid + 1, "token": token, "ttyPath": spec["ttyPath"], "unexpectedInputBytes": 0,
            "payloadBytes": len(generated), "payloadSHA256": hashlib.sha256(generated).hexdigest(), "historyRows": 1000,
            "dsrReplyHex": b"\x1b[36;1R".hex(), "dsrQueryHex": b"\x1b[36;1H\x1b[6n".hex(),
            "ttyFlagsRaw": [0, 0, 0, 0], "ttyFlagsOriginal": [1, 2, 3, 4], "ttyFlagsRestored": [1, 2, 3, 4],
            "modeDifferenceIndices": [], "status": "stopped", "stopReason": "control-finish", "terminalModeRestored": True, "fileFlagsRestored": True,
            "workerSourceSHA256": frozen["scroll_worker.py"], "protocolSourceSHA256": frozen["scroll_protocol.py"],
            "transportSourceSHA256": frozen["terminal_bench_worker.py"]}
        for name in ("ready", "prepared", "final"):
            write(folder / f"fixture/{name}.json", {**worker, "status": {"ready": "ready", "prepared": "prepared", "final": "stopped"}[name]})
        write(folder / "fixture-stop.json", {"complete": True, "workerExited": True, "finalSHA256": digest(folder / "fixture/final.json")})
        write(folder / "cleanup.json", {"appPID": pid, "returncode": 0})
        raw = {"status": "valid", "terminal": terminal, "token": token, "mode": report["mode"],
            "startedUTC": (datetime.fromisoformat(metadata["startedUTC"]) + timedelta(seconds=ordinal * 30)).isoformat(),
            "finishedUTC": (datetime.fromisoformat(metadata["startedUTC"]) + timedelta(seconds=ordinal * 30 + 29)).isoformat(),
            "observerReturncode": 0, "observationSHA256": digest(folder / "observation.json"),
            "configBeforeLaunchSHA256": digest(folder / "config-before-launch.json"),
            "powerBefore": power, "powerAfter": power, "nativeBefore": native, "nativeAfter": native,
            "canonicalConfigSHA256": normalized_config_hash(terminal, options), "preparedSHA256": digest(folder / "fixture/prepared.json")}
        if terminal == "ghostty":
            from scroll_public_config import SCOPE
            write(folder / "public-config-query.json", {"schemaVersion": 2, "scope": SCOPE,
                "binarySHA256Before": metadata["binaries"][terminal]["sha256"],
                "binarySHA256After": metadata["binaries"][terminal]["sha256"],
                "configSHA256Before": digest(folder / "ghostty.config"),
                "configSHA256After": digest(folder / "ghostty.config"),
                "defaultQuery": {"returncode": 0, "stderr": "",
                    "selectedValues": {"mouse-scroll-multiplier": ["precision:1,discrete:3"]},
                    "arguments": [metadata["binaries"][terminal]["path"], "+show-config", "--default"]},
                "configurationValidation": {"returncode": 0, "stdout": "", "stderr": "",
                    "arguments": [metadata["binaries"][terminal]["path"], "+validate-config", f"--config-file={config}"]},
                "policy": {"installedDefaultDiscreteMultiplier": 3, "validatedDiscreteMultiplier": 1,
                    "policyOrigin": "validated-explicit-override"}})
            raw.update(publicConfigQuerySHA256=digest(folder / "public-config-query.json"),
                       validatedDiscreteMultiplier=1, discretePolicyOrigin="validated-explicit-override")
        write(folder / "run.json", raw)
        return report, raw

    for ordinal, terminal in enumerate(("cmdy", "ghostty")):
        folder = root / "calibration" / terminal
        report, raw = run(folder, terminal, "a" * 32, ordinal, True)
        metadata["calibrations"][terminal] = asdict(WheelCalibration(terminal, "matched", 3, -3, 3, "line", False,
            frozen["scroll_protocol.py"], metadata["binaries"][terminal]["sha256"], raw["canonicalConfigSHA256"],
            digest(folder / "observation.json"), "valid-unpooled-calibration"))
    ordinal = 2
    for block in range(6):
        for terminal in (("cmdy", "ghostty") if block % 2 == 0 else ("ghostty", "cmdy")):
            relative = f"runs/{block:02d}-{terminal}"; folder = root / relative
            token = f"{block + 1:032x}"
            run(folder, terminal, token, ordinal, False); ordinal += 1
            metadata["runs"].append({"block": block, "terminal": terminal, "token": token, "path": relative,
                "runSHA256": digest(folder / "run.json"), "observationSHA256": digest(folder / "observation.json")})
    write(root / "manifest.json", metadata)
    return metadata


class CompleteEvidenceTests(unittest.TestCase):
    def test_omitted_optional_row_before_target_is_allowed_but_after_target_rejects(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build_records(root)
            folder = root / "calibration/cmdy"
            report = json.loads((folder / "observation.json").read_text())
            spec = json.loads((folder / "observer-spec.json").read_text())
            value = report["mappingAttempts"][0]
            target = value["afterFirstRow"]
            pixels = geometry(report["geometry"])
            for measured in (True, False):
                for after in (False, True):
                    with self.subTest(measured=measured, after=after):
                        changed = deepcopy(value)
                        undecoded = deepcopy(value["stability"]["first"])
                        undecoded.pop("firstRow")
                        undecoded.pop("canonicalRowsSHA256")
                        undecoded["checkedPixels"] = 0
                        for key in ("displayTicks", "callbackTicks", "windowQueryFinishedTicks"):
                            undecoded[key] += 1000 if after else -1000
                        changed["frames"].append(undecoded)
                        if after:
                            with self.assertRaisesRegex(ValueError, "viewport changed after first complete target"):
                                checked_stability(changed, report, spec, pixels, target, measured)
                        else:
                            self.assertEqual(checked_stability(changed, report, spec, pixels, target, measured),
                                             value["stability"]["first"])

    def test_raw_calibration_checkpoint_rejects_zero_or_repeated_event_timestamps(self):
        for damaged in ("zero", "repeat"):
            with self.subTest(damaged=damaged), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                build_records(root)
                metadata = json.loads((root / "manifest.json").read_text())
                metadata.pop("finishedUTC")
                folder = root / "calibration/cmdy"
                self.assertEqual(validate_raw_calibration(folder, metadata, "cmdy")["status"],
                                 "valid-unpooled-raw-calibration")
                report = json.loads((folder / "observation.json").read_text())
                events = report["mappingAttempts"]
                if damaged == "zero":
                    events[0]["event"]["eventTimestamp"] = 0
                else:
                    events[1]["event"]["eventTimestamp"] = events[0]["event"]["eventTimestamp"]
                write(folder / "observation.json", report)
                run = json.loads((folder / "run.json").read_text())
                run["observationSHA256"] = digest(folder / "observation.json")
                write(folder / "run.json", run)
                with self.assertRaisesRegex(ValueError, "creation timestamps"):
                    validate_raw_calibration(folder, metadata, "cmdy")
                self.assertNotIn("finishedUTC", metadata)

    def test_resealed_missing_and_changed_ancestry_reject_complete_pair(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-ancestry-") as name:
            root = Path(name)
            metadata = build_records(root)
            folder = root / "runs/00-ghostty"
            original_report = json.loads((folder / "observation.json").read_text())
            original_raw = json.loads((folder / "run.json").read_text())
            for mutation in ("missing-initial", "changed-root-parent", "replayed-tty"):
                with self.subTest(mutation=mutation):
                    report = deepcopy(original_report)
                    if mutation == "missing-initial":
                        del report["initialAncestry"]
                    elif mutation == "changed-root-parent":
                        record = report["initialAncestry"]["secondWalkReverse"][1]
                        record["parentPID"] += 1
                        record["link"]["parentPID"] += 1
                    else:
                        report["samples"][0]["ttyAfter"]["ancestry"] = deepcopy(report["initialAncestry"])
                    write(folder / "observation.json", report)
                    raw = deepcopy(original_raw)
                    raw["observationSHA256"] = digest(folder / "observation.json")
                    write(folder / "run.json", raw)
                    altered = deepcopy(metadata)
                    item = next(value for value in altered["runs"] if value["path"] == "runs/00-ghostty")
                    item.update(runSHA256=digest(folder / "run.json"),
                                observationSHA256=digest(folder / "observation.json"))
                    write(root / "manifest.json", altered)
                    with self.assertRaises((KeyError, ValueError)):
                        load_scroll_evidence(root)

    def test_complete_synthetic_pair_is_read_and_resealed_missing_sample_rejects(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-evidence-") as name:
            root = Path(name)
            metadata = build_records(root)
            item = load_scroll_evidence(root, {"cmdy": "a" * 64, "ghostty": "b" * 64})
            self.assertEqual((item["case"], item["kind"], item["grid"]), ("scroll", "input", [120, 36]))
            self.assertEqual(len(item["blocks"]), 6)
            self.assertTrue(all(len(values) == 40 for pair in item["blocks"].values() for values in pair.values()))
            folder = root / "runs/00-cmdy"
            report = json.loads((folder / "observation.json").read_text())
            report["samples"].pop()
            write(folder / "observation.json", report)
            raw = json.loads((folder / "run.json").read_text())
            raw["observationSHA256"] = digest(folder / "observation.json"); write(folder / "run.json", raw)
            metadata["runs"][0].update(runSHA256=digest(folder / "run.json"), observationSHA256=digest(folder / "observation.json"))
            write(root / "manifest.json", metadata)
            with self.assertRaisesRegex(ValueError, "missing/excess measured"):
                load_scroll_evidence(root)

    def test_launch_metadata_cannot_omit_isolation_even_with_valid_raw_frames(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-launch-") as name:
            root = Path(name)
            metadata = build_records(root)
            cases = [
                ("cmdy", lambda x: x.update(environment={}), "environment"),
                ("cmdy", lambda x: x["environment"].update(DYLD_INSERT_LIBRARIES="synthetic"), "environment"),
                ("ghostty", lambda x: x["arguments"].remove("--config-default-files=false"), "isolation arguments"),
                ("cmdy", lambda x: x.update(defaultsDomain="com.cmdy.app"), "defaults domain"),
                ("cmdy", lambda x: x.update(config="/synthetic/unrelated-config"), "config/readiness"),
                ("cmdy", lambda x: x["fixtureCommand"].__setitem__(4, "/synthetic/unrelated-output"), "output/socket/command"),
                ("cmdy", lambda x: x["fixtureCommand"].__setitem__(6, "/synthetic/unrelated-socket"), "output/socket/command"),
            ]
            for terminal, mutation, error in cases:
                with self.subTest(terminal=terminal, error=error):
                    path = root / "runs" / ("00-" + terminal) / "launch.json"
                    original = path.read_bytes()
                    value = json.loads(original); mutation(value); write(path, value)
                    try:
                        with self.assertRaisesRegex(ValueError, error):
                            load_scroll_evidence(root)
                    finally:
                        path.write_bytes(original)

    def test_resealed_uncontrolled_shell_and_missing_config_manifest_reject(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-shell-") as name:
            root = Path(name)
            metadata = build_records(root)
            folder = root / "runs/00-cmdy"
            for mutation, error in [("shell", "controlled shell"), ("manifest", "registered launch configuration")]:
                with self.subTest(mutation=mutation):
                    paths = [folder / "zsh/.zshenv", folder / "config-before-launch.json", folder / "run.json", root / "manifest.json"]
                    originals = {path: path.read_bytes() for path in paths}
                    config = json.loads(paths[1].read_text())
                    if mutation == "shell":
                        paths[0].write_text(paths[0].read_text() + "# unexpected shell bytes\n")
                        config["zsh/.zshenv"] = digest(paths[0])
                    else:
                        config = {}
                    write(paths[1], config)
                    raw = json.loads(paths[2].read_text()); raw["configBeforeLaunchSHA256"] = digest(paths[1]); write(paths[2], raw)
                    altered = deepcopy(metadata); altered["runs"][0]["runSHA256"] = digest(paths[2]); write(paths[3], altered)
                    try:
                        with self.assertRaisesRegex(ValueError, error):
                            load_scroll_evidence(root)
                    finally:
                        for path, data in originals.items():
                            path.write_bytes(data)

    def test_reused_domain_rejects_even_when_each_launch_environment_agrees(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-domain-") as name:
            root = Path(name)
            build_records(root)
            first = json.loads((root / "calibration/cmdy/launch.json").read_text())
            path = root / "runs/00-cmdy/launch.json"
            value = json.loads(path.read_text()); value["defaultsDomain"] = first["defaultsDomain"]
            value["environment"]["CMDY_DEFAULTS_DOMAIN"] = first["defaultsDomain"]; write(path, value)
            with self.assertRaisesRegex(ValueError, "domain was reused"):
                load_scroll_evidence(root)

    def test_idle_status_cannot_acknowledge_a_complete_viewport(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-status-") as name:
            root = Path(name)
            metadata = build_records(root)
            folder = root / "runs/00-cmdy"
            report = json.loads((folder / "observation.json").read_text())
            report["captureStatuses"][0]["statusRaw"] = 1
            write(folder / "observation.json", report)
            raw = json.loads((folder / "run.json").read_text())
            raw["observationSHA256"] = digest(folder / "observation.json"); write(folder / "run.json", raw)
            metadata["runs"][0].update(runSHA256=digest(folder / "run.json"), observationSHA256=digest(folder / "observation.json"))
            write(root / "manifest.json", metadata)
            with self.assertRaisesRegex(ValueError, "no complete native status"):
                load_scroll_evidence(root)

    def test_capture_interruption_inside_stability_rejects_with_or_without_display_time(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-interruption-") as name:
            root = Path(name)
            metadata = build_records(root)
            folder = root / "runs/00-cmdy"
            original_report = json.loads((folder / "observation.json").read_text())
            original_raw = json.loads((folder / "run.json").read_text())
            first = original_report["initial"]["stability"]["first"]["displayTicks"]
            for status in (2, 3, 4, 5):
                for event_offset in (None, -1000, 500):
                    with self.subTest(status=status, event_offset=event_offset):
                        report = deepcopy(original_report)
                        interruption = {"callbackTicks": first + 1000, "statusRaw": status,
                            "sampleIsValid": True, "hasImageBuffer": False, "generation": 1,
                            "armedAfterTicks": report["captureStartTicks"]}
                        if event_offset is not None:
                            interruption["displayTicks"] = first + event_offset
                        report["captureStatuses"].append(interruption)
                        report["captureStatuses"].sort(key=lambda x: x["callbackTicks"])
                        write(folder / "observation.json", report)
                        raw = deepcopy(original_raw); raw["observationSHA256"] = digest(folder / "observation.json")
                        write(folder / "run.json", raw)
                        altered = deepcopy(metadata)
                        altered["runs"][0].update(runSHA256=digest(folder / "run.json"), observationSHA256=digest(folder / "observation.json"))
                        write(root / "manifest.json", altered)
                        with self.assertRaisesRegex(ValueError, "capture inside stability interval"):
                            load_scroll_evidence(root)


if __name__ == "__main__":
    unittest.main()
