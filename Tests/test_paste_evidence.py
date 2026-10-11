"""Explicitly synthetic records, never retained as performance measurements.

Exercise the entire raw six-pair adapter without native calls; reseal hashes
on mutations so semantic validation, rather than hash mismatch, rejects them.
"""
import base64
from copy import deepcopy
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import tempfile
import unittest

from competitive_bench import BenchOptions
from paste_bench import SOURCES, config_text, main, normalized_config_hash
from paste_build import OBSERVER_SOURCES, TEST_SOURCES
from paste_contract import expected_environment
from paste_dictionary import validate_sdef
from paste_protocol import INITIAL_SETTLE_NS, METRIC, expected_receipt, preparation, response_first_row, viewport_sha256
from paste_parity_evidence import (SEND_OPTIONS, checked_capture_statuses, checked_frames, checked_sample,
    checked_stability, expected_classes, fourcc, geometry, load_paste_evidence, validate_pilot_evidence,
    validate_pilot_checkpoint_evidence, checked_report, checked_initial_settling)
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
    for name in ("paste-observer", "window-helper"):
        (tooling / name).write_text("SYNTHETIC UNIT TEST: NOT AN EXECUTABLE\n")
    dictionary = (HERE.parent / "App/Resources/Cmdy.sdef").read_bytes()
    definition = validate_sdef(dictionary)
    for name in ("cmdy", "ghostty"):
        (tooling / (name + ".sdef")).write_bytes(dictionary)
    source_hashes = {name: digest(tooling / name) for name in SOURCES}
    command = ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5",
               *(str(tooling / name) for name in OBSERVER_SOURCES), "-o", str(tooling / "paste-observer")]
    write(tooling / "observer-build.json", {"nativeObservationRun": False,
        "binarySHA256": digest(tooling / "paste-observer"), "command": command,
        "sourceSHA256": {name: source_hashes[name] for name in OBSERVER_SOURCES}})
    write(tooling / "observer-qualification.json", {"status": "pass", "sourcesUnchanged": True,
        "nativeObservationRun": False, "appleEventsSent": False, "permissionQueriesRun": False,
        "sourceSHA256": {name: source_hashes[name] for name in set(OBSERVER_SOURCES + TEST_SOURCES + ["paste_build.py", "paste_protocol.py", "scroll_protocol.py"])},
        "commands": [{"name": name, "exitCode": 0, "exitedAndReaped": True}
                     for name in ("build-paste-observer", "build-paste-native-tests", "check-paste-native")]})
    frozen = {path.name: digest(path) for path in tooling.iterdir()}
    write(root / "tooling-freeze.json", frozen)
    power = {"signature": {"source": "AC Power", "settings": "synthetic settings"}}
    environment = {"lowPowerMode": False, "thermalState": 0, "os": "synthetic test OS"}
    native = {"ok": True, **environment}
    machine = {"font": {"postScriptName": "Menlo-Regular", "sizePoints": 14}, "displays": [{"displayID": 1}]}
    write(root / "app-source-manifest.json", {"sources": {"App/Resources/Cmdy.sdef": definition["sha256"]}})
    source = {"status": "valid", "sourceCount": 1, "manifestSHA256": digest(root / "app-source-manifest.json")}
    metadata = {"schemaVersion": 1, "benchmarkKind": "paste", "state": "complete", "diagnostic": False,
        "pilotOnly": False, "profile": "matched", "metric": METRIC,
        "requestedBlocks": 6, "samplesPerBlock": 40, "warmupsPerBlock": 2, "grid": [120, 36], "displayID": 1,
        "controllerPID": 10, "first": "cmdy", "startedUTC": "2026-09-09T00:00:00+00:00", "finishedUTC": "2026-09-09T01:00:00+00:00",
        "binaries": {name: {"sha256": letter * 64, "path": "/synthetic/" + name} for name, letter in (("cmdy", "a"), ("ghostty", "b"))},
        "dictionaries": {name: dict(definition, path="/synthetic/" + name + ".sdef") for name in ("cmdy", "ghostty")},
        "runtime": {"pythonVersion": "synthetic Python", "python": {"path": "/synthetic/python", "sha256": "c" * 64},
                    "shell": {"path": "/bin/zsh", "sha256": "d" * 64}, "workerPythonFlags": ["-S"]},
        "toolingSHA256": frozen, "toolingDirectory": str(tooling), "sourceBefore": source, "sourceAfter": source,
        "powerBefore": power, "powerAfter": power, "nativeBefore": native, "nativeAfter": native,
        "machine": machine, "machineAfter": machine, "fontSHA256": "e" * 64,
        "hardware": {"stdout": "synthetic unit-test machine"}, "pilots": {}, "runs": []}
    options = BenchOptions(Path("/synthetic/cmdy"), Path("/synthetic/ghostty"))
    raster = {"width": 720, "height": 240, "columnSamples": [[6 * col + n for n in (2, 3, 4)] for col in range(120)],
              "rowBands": [{"lower": 12 + 6 * row, "upper": 12 + 6 * (row + 1)} for row in range(36)],
              "discovery": {"firstRow": 964, "redLower": 0, "redUpper": 6, "greenLower": 714,
                            "greenUpper": 720, "top": 12, "rowHeight": 6}}
    raster["calibrationSHA256"] = hashlib.sha256(json.dumps(raster, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def run(folder, terminal, token, ordinal):
        pid = 100 + ordinal * 2; offset = ordinal * 30_000_000_000 + INITIAL_SETTLE_NS
        proof = {"appPID": pid, "windowID": pid, "frontmostPID": pid, "displayID": 1,
                 "processStartSeconds": 1, "processStartMicroseconds": 2, "x": 120, "y": 120, "width": 720, "height": 240}
        spec = {"appPID": pid, "workerPID": pid + 1, "windowID": pid, "displayID": 1, "token": token,
                "socketPath": f"/private/tmp/cmdy-paste-synthetic-{ordinal}/control.sock", "timeoutSeconds": 10,
                "ttyPath": "/dev/ttys999", "executable": "/synthetic/" + terminal,
                "executableSHA256": metadata["binaries"][terminal]["sha256"], "requestedFPS": 120}
        write(folder / "observer-spec.json", spec)
        app = {"pid": pid, "parentPID": 10, "uid": 501, "startSeconds": 1, "startMicroseconds": 2, "executable": spec["executable"]}
        worker = {"pid": pid + 1, "parentPID": pid if terminal == "cmdy" else pid + 1000,
                  "uid": 501, "startSeconds": 1, "startMicroseconds": 3, "executable": "/synthetic/python"}

        def tty(start):
            return {"status": "valid", "appPID": pid, "workerPID": pid + 1, "ttyPath": spec["ttyPath"],
                "processIdentityValid": True, "workerIsDescendant": True, "columns": 120, "rows": 36,
                "openResult": 0, "windowSizeResult": 0, "fstatResult": 0, "openedDeviceIsCharacter": True,
                "openedDeviceID": 1, "workerControllingDeviceID": 1, "processInfoExpectedBytes": 100,
                "processInfoResult": 100, "workerUID": 501, "observerUID": 501, "workerProcessGroupID": pid + 1,
                "workerForegroundProcessGroupID": pid + 1, "externalTCGetPGRP": -1, "externalTCGetPGRPErrno": 25,
                "startedTicks": offset + start, "finishedTicks": offset + start + 1,
                "ancestry": ancestry_fixture(app, worker, start=offset + start, step=0)[0]}

        def probe(count=0, off=False, enabled=False, armed=None):
            return {"ok": True, "status": "prepared", "unexpectedInputBytes": 0, "grid": {"columns": 120, "rows": 36},
                    "acceptedPastes": count, "offProbeVerified": off, "bracketModeEnabled": enabled,
                    "armedSequence": armed, "receivedBytes": 0}

        def query(start):
            return {"startedTicks": offset + start, "finishedTicks": offset + start + 1,
                    "terminalID": f"synthetic-pane-{pid}", "terminalCount": 1, "targetPID": pid,
                    "eventClass": fourcc("core"), "eventID": fourcc("getd"), "sendOptions": SEND_OPTIONS}

        def permission(start):
            return [{"eventClass": fourcc(a), "eventID": fourcc(b), "targetPID": pid, "askUserIfNeeded": False,
                     "status": 0, "startedTicks": offset + start + i, "finishedTicks": offset + start + i}
                    for i, (a, b) in enumerate((("core", "getd"), ("Ghst", "InTx")))]

        def stable(base, row):
            frame = {"displayTicks": offset + base + 1_000_000, "callbackTicks": offset + base + 999_900,
                     "windowQueryFinishedTicks": offset + base + 1_000_100, "window": proof, "firstRow": row,
                     "checkedPixels": 77_760, "canonicalRowsSHA256": viewport_sha256(token, row),
                     "observedCellClasses": base64.b64encode(expected_classes(token, row)).decode()}
            return {"status": "valid", "afterTicks": offset + base, "targetFirstRow": row, "frames": [frame],
                    "stability": {"first": frame, "guardStartedTicks": frame["displayTicks"], "laterCorrectDistinctFrames": 0,
                                  "validationFinishedTicks": offset + base + 270_000_000}}

        permissions = permission(800)

        def action(sequence):
            base = (sequence + 3) * 300_000_000
            value = stable(base, response_first_row(sequence))
            receipt = expected_receipt(token, sequence)
            value.update(sequence=sequence, bracketed=sequence != 0,
                payloadBytes=receipt["payloadBytes"], payloadSHA256=receipt["payloadSHA256"],
                ttyBefore=tty(base - 100), ttyAfter=tty(base + 270_000_001),
                fixtureBefore=probe(max(0, sequence - 1), sequence > 0, sequence > 0),
                fixtureAfter=probe(sequence, True, sequence > 0),
                armControl=probe(max(0, sequence - 1), sequence > 0, sequence > 0, sequence),
                windowBefore=proof, windowAfter=proof,
                terminalQueryBefore=query(base - 20), terminalQueryAfter=query(base + 270_000_003),
                event={"eventBeforeTicks": offset + base, "eventAfterTicks": offset + base + 2_000_000,
                       "eventClass": fourcc("Ghst"), "eventID": fourcc("InTx"), "targetKeyword": fourcc("GItT"),
                       "terminalClass": fourcc("Gtrm"), "terminalID": f"synthetic-pane-{pid}", "targetPID": pid,
                       "addressDescriptorType": fourcc("kpid"), "keyForm": fourcc("ID  "),
                       "sendOptions": SEND_OPTIONS, "replyErrorNumber": 0})
            permissions.extend(permission(base - 50))
            return value

        wall = 1788912000 * 1_000_000_000
        report = {"schemaVersion": 2, "benchmarkKind": "paste", "status": "valid", "metric": METRIC,
            "grid": [120, 36], "barcodeColumns": 120, "postMatchGuardNS": 250_000_000,
            "specSHA256": digest(folder / "observer-spec.json"), "token": token, "ownershipFailures": [], "controllerPID": 10,
            "appIdentity": app, "workerIdentity": worker, "initialAncestry": ancestry_fixture(app, worker, start=offset + 1)[0],
            "executableSHA256": spec["executableSHA256"], "windowBefore": proof, "windowAfter": proof,
            "environmentBefore": environment, "environmentAfter": environment,
            "clockBefore": {"wallNS": wall + offset + 100, "absoluteTicks": offset + 100, "continuousTicks": offset + 100},
            "clockAfter": {"wallNS": wall + offset + 20_000_000_000, "absoluteTicks": offset + 20_000_000_000, "continuousTicks": offset + 20_000_000_000},
            "timebase": {"numer": 1, "denom": 1}, "geometry": raster, "captureStartTicks": offset + 1000,
            "capture": {"kind": "owned-window", "requestedFPS": 120, "width": 720, "height": 240, "queueDepth": 8,
                        "pointPixelScale": 1, "colorSpace": "sRGB", "pixelFormat": "BGRA", "ignoreShadowsSingleWindow": True},
            "ownedChromeGeometrySchema": 1, "ownedChromeGeometryLimit": 4096,
            "ownedChromeGeometry": [{"checkedTicks": offset + 500, "rasterDerivedViewportTop": None, "windows": []},
                                    {"checkedTicks": offset + 1_001_000, "rasterDerivedViewportTop": 132, "windows": []}],
            "ttyBefore": tty(100), "ttyAfter": tty(19_000_000_000), "fixtureBefore": probe(), "fixtureAfter": probe(42, True, True),
            "initial": stable(1000, 964), "offProbe": action(0), "samples": [], "warmups": [],
            "terminalQueryBefore": query(900), "terminalQueryAfter": query(19_000_000_003),
            "enableBracketed": {"startedTicks": offset + 1_180_000_000, "finishedTicks": offset + 1_180_000_001,
                                "control": probe(0, True, True)},
            "enabledViewport": stable(1_180_000_000, 962)}
        # Allow the mode-enable guard to finish before the first warmup.
        for sequence in range(1, 43):
            value = action(sequence)
            value["warmup"] = sequence <= 2
            report["warmups" if sequence <= 2 else "samples"].append(value)
        # Move all bracketed actions later, maintaining a 300 ms cadence.
        def shift(value, amount):
            if isinstance(value, dict):
                for key, item in value.items():
                    if key.endswith("Ticks") and type(item) is int:
                        value[key] += amount
                    elif key != "window":
                        shift(item, amount)
            elif isinstance(value, list):
                for item in value:
                    shift(item, amount)
        # Use deep copies so shared first-frame references shift only once.
        for group in report["warmups"] + report["samples"]:
            first = group["stability"]["first"]
            group["stability"]["first"] = deepcopy(first)
            shift(group, 300_000_000)
        for item in permissions[4:]:
            item["startedTicks"] += 300_000_000; item["finishedTicks"] += 300_000_000
        report["permissions"] = permissions
        groups = [report["initial"], report["offProbe"], report["enabledViewport"], *report["warmups"], *report["samples"]]
        report.update(captureStatusSchema=1, captureStatusLimit=65536,
            captureStatuses=[{"callbackTicks": frame["callbackTicks"], "displayTicks": frame["displayTicks"], "statusRaw": 0,
                "sampleIsValid": True, "hasImageBuffer": True, "generation": generation, "armedAfterTicks": group["afterTicks"]}
                for generation, group in enumerate(groups, 1) for frame in group["frames"]])
        write(folder / "observation.json", report)
        cwd = Path(f"/private/tmp/cmdy-drain-synthetic-{ordinal}/work"); domain = f"com.cmdy.bench.{ordinal:032x}"
        config = folder / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
        config.parent.mkdir(parents=True, exist_ok=True); config.write_text(config_text(terminal, options, cwd))
        launch = {"appPID": pid, "workerPID": pid + 1, "terminal": terminal, "profile": "matched",
            "environment": expected_environment(folder, cwd, domain), "cwd": str(cwd), "defaultsDomain": domain,
            "config": str(config), "readyPath": str(folder / "fixture/ready.json"),
            "arguments": [metadata["binaries"][terminal]["path"]] + (["--config-default-files=false", f"--config-file={config}"] if terminal == "ghostty" else []),
            "startedMonotonicNS": offset - INITIAL_SETTLE_NS, "configSHA256": digest(config),
            "fixtureCommand": ["/synthetic/python", "-S", str(tooling / "paste_worker.py"), "--output", str(folder / "fixture"),
                               "--socket", spec["socketPath"], "--token", token, "--timeout", "600"]}
        (folder / "zsh").mkdir(); (folder / "zsh/.zshenv").write_text("unsetopt RCS\nexec " + shlex.join(launch["fixtureCommand"]) + "\n")
        write(folder / "config-before-launch.json", {str(path.relative_to(folder)): digest(path) for path in [config, folder / "zsh/.zshenv"]})
        write(folder / "launch.json", launch)
        shared = {"ok": True, "pid": pid, "frontmostPID": pid, "windows": [{"onScreen": True, "ownerPID": pid,
            "windowID": pid, "displayID": 1, "bounds": {key: proof[key] for key in ("x", "y", "width", "height")}}]}
        for phase in ("before", "after"):
            write(folder / f"window-{phase}.json", shared); write(folder / f"grid-{phase}.json", {"columns": 120, "rows": 36})
        generated = preparation(token)
        record = {"schemaVersion": 1, "benchmarkKind": "paste", "pid": pid + 1, "token": token, "ttyPath": spec["ttyPath"],
            "unexpectedInputBytes": 0, "payloadBytes": len(generated), "payloadSHA256": hashlib.sha256(generated).hexdigest(),
            "dsrReplyHex": b"\x1b[36;1R".hex(), "dsrQueryHex": b"\x1b[36;1H\x1b[6n".hex(),
            "ttyFlagsRaw": [0, 0, 0, 0], "ttyFlagsOriginal": [1, 2, 3, 4], "ttyFlagsRestored": [1, 2, 3, 4],
            "modeDifferenceIndices": [], "stopReason": "control-finish", "terminalModeRestored": True, "fileFlagsRestored": True,
            "sourceSHA256": {name: frozen[name] for name in ("paste_worker.py", "paste_protocol.py", "scroll_protocol.py", "terminal_bench_worker.py")},
            "preparedMonotonicNS": offset - INITIAL_SETTLE_NS + 10, "finishedMonotonicNS": offset + 19_000_000_000,
            "gridChecks": [{"columns": 120, "rows": 36}], "gridAfter": {"columns": 120, "rows": 36},
            "receipts": [], "acceptedPastes": 0, "offProbeVerified": False, "bracketModeEnabled": False}
        for name in ("ready", "prepared"):
            write(folder / f"fixture/{name}.json", dict(record, status=name))
        record.update(status="stopped", acceptedPastes=42, offProbeVerified=True, bracketModeEnabled=True,
                      incompleteSequence=None, incompleteBytes=0)
        for sequence in range(43):
            item = expected_receipt(token, sequence); tick = offset + 100 + sequence * 10
            item.update(receiveStartedMonotonicNS=tick, verifiedMonotonicNS=tick + 1,
                        emitStartedMonotonicNS=tick + 2, emitFinishedMonotonicNS=tick + 3, grid={"columns": 120, "rows": 36})
            record["receipts"].append(item); write(folder / f"fixture/receipt-{sequence:02d}.json", item)
        write(folder / "fixture/final.json", record)
        write(folder / "fixture-stop.json", {"complete": True, "workerExited": True, "finalSHA256": digest(folder / "fixture/final.json")})
        write(folder / "cleanup.json", {"appPID": pid, "returncode": 0})
        write(folder / "pre-capture-settling.json", {"requestedNS": INITIAL_SETTLE_NS,
            "startedMonotonicNS": offset - INITIAL_SETTLE_NS + 20, "finishedMonotonicNS": offset + 20})
        raw = {"status": "valid", "terminal": terminal, "token": token,
            "startedUTC": (datetime.fromisoformat(metadata["startedUTC"]) + timedelta(seconds=ordinal * 30)).isoformat(),
            "finishedUTC": (datetime.fromisoformat(metadata["startedUTC"]) + timedelta(seconds=ordinal * 30 + 29)).isoformat(),
            "observerReturncode": 0, "observationSHA256": digest(folder / "observation.json"),
            "preCaptureSettlingSHA256": digest(folder / "pre-capture-settling.json"),
            "configBeforeLaunchSHA256": digest(folder / "config-before-launch.json"),
            "powerBefore": power, "powerAfter": power, "nativeBefore": native, "nativeAfter": native,
            "canonicalConfigSHA256": normalized_config_hash(terminal, options), "preparedSHA256": digest(folder / "fixture/prepared.json")}
        write(folder / "run.json", raw)
        return {"path": str(folder.relative_to(root)), "token": token, "runSHA256": digest(folder / "run.json"),
                "observationSHA256": digest(folder / "observation.json")}

    for ordinal, terminal in enumerate(("cmdy", "ghostty")):
        metadata["pilots"][terminal] = run(root / "pilot" / terminal, terminal, "a" * 32, ordinal)
    checkpoint = dict(metadata, state="pilot-complete-unpooled", pilotOnly=True, runs=[],
                      finishedUTC="2026-09-09T00:01:00+00:00")
    write(root / "pilot-checkpoint.json", checkpoint)
    # Explicitly synthetic schema construction. The real recorder invokes the
    # independent validator here; tests exercise that rejection boundary below.
    admission = {"status": "valid-unpooled-paired-pilot", "case": "input/paste", "parityEligible": False,
        "binaries": {name: metadata["binaries"][name]["sha256"] for name in ("cmdy", "ghostty")},
        "profile": metadata["profile"], "checkpointSHA256": digest(root / "pilot-checkpoint.json"),
        "validatorSHA256": frozen["paste_parity_evidence.py"], "pilots": metadata["pilots"]}
    write(root / "pilot-admission.json", admission)
    metadata.update(pilotCheckpointSHA256=digest(root / "pilot-checkpoint.json"),
                    pilotAdmissionSHA256=digest(root / "pilot-admission.json"))
    ordinal = 2
    for block in range(6):
        for terminal in (("cmdy", "ghostty") if block % 2 == 0 else ("ghostty", "cmdy")):
            item = run(root / "runs" / f"{block:02d}-{terminal}", terminal, f"{block + 1:032x}", ordinal)
            item.update(block=block, terminal=terminal); metadata["runs"].append(item); ordinal += 1
    write(root / "manifest.json", metadata)
    return metadata


class PasteEvidenceTests(unittest.TestCase):
    def test_trusted_source_versions_require_whole_bundles(self):
        from paste_parity_evidence import checked_tooling_sources
        legacy = json.loads((HERE / "testdata/paste_pre_queue_correction_sources.json").read_text())
        current = {name: digest(HERE / name) for name in SOURCES}
        checked_tooling_sources(legacy)
        checked_tooling_sources(current)
        for changed in (dict(legacy, **{"paste_observation.swift": current["paste_observation.swift"]}),
                        dict(current, **{"paste_observation.swift": legacy["paste_observation.swift"]}),
                        dict(legacy, **{"paste_observer.swift": "a" * 64})):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                checked_tooling_sources(changed)

    def test_initial_settling_cannot_be_short_or_overlap_observation(self):
        value = {"requestedNS": INITIAL_SETTLE_NS, "startedMonotonicNS": 100,
                 "finishedMonotonicNS": INITIAL_SETTLE_NS + 100}
        prepared = {"preparedMonotonicNS": 90}
        report = {"clockBefore": {"absoluteTicks": INITIAL_SETTLE_NS + 101},
                  "timebase": {"numer": 1, "denom": 1}}
        checked_initial_settling(value, prepared, report)
        for change in [dict(requestedNS=1), dict(startedMonotonicNS=89),
                       dict(finishedMonotonicNS=INITIAL_SETTLE_NS + 99),
                       dict(finishedMonotonicNS=INITIAL_SETTLE_NS + 102),
                       dict(requestedNS=float(INITIAL_SETTLE_NS))]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                checked_initial_settling(dict(value, **change), prepared, report)

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="paste-synthetic-evidence-")
        cls.root = Path(cls.temp.name)
        cls.metadata = build_records(cls.root)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_complete_six_pairs_reads_native_frame_clocks(self):
        item = load_paste_evidence(self.root, {"cmdy": "a" * 64, "ghostty": "b" * 64})
        self.assertEqual((item["case"], item["kind"], item["grid"]), ("input/paste", "input", [120, 36]))
        self.assertEqual(len(item["blocks"]), 6)
        self.assertTrue(all(len(values) == 40 and values == [1.0] * 40 for pair in item["blocks"].values() for values in pair.values()))

    def test_resealed_observer_mutations_reject_semantically(self):
        folder = self.root / "runs/00-cmdy"
        original = json.loads((folder / "observation.json").read_text())
        raw = json.loads((folder / "run.json").read_text())

        def sample(report):
            return report["samples"][0]

        def change_actual_pixels(report):
            frame = sample(report)["frames"][0]
            cells = bytearray(base64.b64decode(frame["observedCellClasses"])); cells[-1] = 0
            frame["observedCellClasses"] = base64.b64encode(cells).decode()

        def change_geometry(report, kind):
            value = report["geometry"]
            if kind == "horizontal-shift":
                value["columnSamples"] = [[x + 1 for x in points] for points in value["columnSamples"]]
            elif kind == "compressed-width":
                value["columnSamples"] = [[3 * col + n for n in (0, 1, 2)] for col in range(120)]
            else:
                for band in value["rowBands"]:
                    band["lower"] += 1; band["upper"] += 1
            plain = {k: v for k, v in value.items() if k != "calibrationSHA256"}
            value["calibrationSHA256"] = hashlib.sha256(json.dumps(plain, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

        def add_late_status(report):
            value = sample(report); first = value["frames"][0]
            status = next(deepcopy(item) for item in report["captureStatuses"] if item["callbackTicks"] == first["callbackTicks"])
            status.update(statusRaw=2, hasImageBuffer=False,
                          callbackTicks=value["stability"]["validationFinishedTicks"] + 1,
                          displayTicks=first["displayTicks"] + 1)
            report["captureStatuses"].append(status)
            report["captureStatuses"].sort(key=lambda item: item["callbackTicks"])

        def transient_response(report):
            value = sample(report); frame = deepcopy(value["frames"][0]); row = frame["firstRow"] + 1
            frame.update(firstRow=row, canonicalRowsSHA256=viewport_sha256(report["token"], row),
                         observedCellClasses=base64.b64encode(expected_classes(report["token"], row)).decode(),
                         displayTicks=frame["displayTicks"] + 1000, callbackTicks=frame["callbackTicks"] + 1000,
                         windowQueryFinishedTicks=frame["windowQueryFinishedTicks"] + 1000)
            value["frames"].append(frame)
            previous = next(item for item in report["captureStatuses"] if item["callbackTicks"] == value["frames"][0]["callbackTicks"])
            report["captureStatuses"].append(dict(previous, callbackTicks=frame["callbackTicks"], displayTicks=frame["displayTicks"]))
            report["captureStatuses"].sort(key=lambda item: item["callbackTicks"])

        mutations = [
            ("wrong actual last cell despite expected hash", change_actual_pixels),
            ("missing observed classes", lambda r: sample(r)["frames"][0].pop("observedCellClasses")),
            ("one missing checked pixel", lambda r: sample(r)["frames"][0].update(checkedPixels=77_759)),
            ("forged expected hash", lambda r: sample(r)["frames"][0].update(canonicalRowsSHA256="f" * 64)),
            ("horizontal discovery shift", lambda r: change_geometry(r, "horizontal-shift")),
            ("compressed partial width", lambda r: change_geometry(r, "compressed-width")),
            ("vertical discovery shift", lambda r: change_geometry(r, "vertical-shift")),
            ("permission prompt", lambda r: r["permissions"][0].update(askUserIfNeeded=True)),
            ("denied permission", lambda r: r["permissions"][1].update(status=-1743)),
            ("PID target changed", lambda r: sample(r)["event"].update(targetPID=9876)),
            ("index target substituted", lambda r: sample(r)["event"].update(keyForm=fourcc("indx"))),
            ("interacting send flags", lambda r: sample(r)["event"].update(sendOptions=3 | 32 | 4096)),
            ("stale pane target", lambda r: sample(r)["terminalQueryAfter"].update(terminalID="different-pane")),
            ("ambiguous pane query", lambda r: sample(r)["terminalQueryBefore"].update(terminalCount=2)),
            ("reply failure", lambda r: sample(r)["event"].update(replyErrorNumber=-1728)),
            ("wrong paste length", lambda r: sample(r).update(payloadBytes=1024)),
            ("wrong paste body", lambda r: sample(r).update(payloadSHA256="a" * 64)),
            ("early guard finish", lambda r: sample(r)["stability"].update(validationFinishedTicks=sample(r)["frames"][0]["displayTicks"] + 1)),
            ("transient correct response", transient_response),
            ("late-delivered blank status", add_late_status),
            ("missing complete status", lambda r: r["captureStatuses"].pop(5)),
            ("false bracket off proof", lambda r: r["offProbe"]["fixtureAfter"].update(bracketModeEnabled=True)),
            ("missing sample", lambda r: r["samples"].pop()),
            ("changed native grid", lambda r: sample(r)["ttyAfter"].update(columns=119)),
            ("changed foreground", lambda r: sample(r)["windowAfter"].update(frontmostPID=12345)),
            ("missing repeated ancestry", lambda r: sample(r)["ttyAfter"].pop("ancestry")),
        ]
        try:
            for name, mutate in mutations:
                with self.subTest(name=name):
                    report = deepcopy(original); mutate(report)
                    write(folder / "observation.json", report)
                    resealed = dict(raw, observationSHA256=digest(folder / "observation.json"))
                    write(folder / "run.json", resealed)
                    with self.assertRaises((ValueError, KeyError)):
                        checked_report(folder, self.metadata, "cmdy")
        finally:
            write(folder / "observation.json", original); write(folder / "run.json", raw)

    def test_resealed_worker_receipt_and_cleanup_mutations_reject(self):
        folder = self.root / "runs/00-cmdy"
        original = json.loads((folder / "fixture/final.json").read_text())
        stop = json.loads((folder / "fixture-stop.json").read_text())
        receipt = json.loads((folder / "fixture/receipt-03.json").read_text())
        try:
            for kind in ("body-hash", "brackets", "emit-before-verify", "unrestored-mode", "extra-input", "missing-receipt"):
                with self.subTest(kind=kind):
                    final = deepcopy(original)
                    if kind == "body-hash": final["receipts"][3]["payloadSHA256"] = "f" * 64
                    elif kind == "brackets": final["receipts"][3]["wireBytes"] -= 12
                    elif kind == "emit-before-verify": final["receipts"][3]["emitStartedMonotonicNS"] = final["receipts"][3]["verifiedMonotonicNS"] - 1
                    elif kind == "unrestored-mode": final["terminalModeRestored"] = False
                    elif kind == "extra-input": final["unexpectedInputBytes"] = 1
                    else: final["receipts"].pop()
                    write(folder / "fixture/final.json", final)
                    write(folder / "fixture/receipt-03.json", final["receipts"][3])
                    write(folder / "fixture-stop.json", dict(stop, finalSHA256=digest(folder / "fixture/final.json")))
                    with self.assertRaises(ValueError):
                        checked_report(folder, self.metadata, "cmdy")
        finally:
            write(folder / "fixture/final.json", original); write(folder / "fixture-stop.json", stop)
            write(folder / "fixture/receipt-03.json", receipt)

    def test_invalid_pilot_prevents_every_measured_launch(self):
        from unittest.mock import patch
        from paste_bench import run_registered_blocks
        path = self.root / "pilot-checkpoint.json"; original = json.loads(path.read_text())
        try:
            invalid = dict(original, state="running"); write(path, invalid)
            with patch("paste_bench.run_owned") as measured, self.assertRaises(ValueError):
                run_registered_blocks(BenchOptions(Path("/synthetic/cmdy"), Path("/synthetic/ghostty")),
                    None, None, self.root, deepcopy(self.metadata), {"cmdy": "a" * 64, "ghostty": "b" * 64})
            measured.assert_not_called()
        finally:
            write(path, original)

    def test_pilot_only_cannot_enter_full_parity(self):
        path = self.root / "manifest.json"
        try:
            changed = dict(self.metadata, state="pilot-complete-unpooled", pilotOnly=True, runs=[])
            write(path, changed)
            with self.assertRaises(ValueError):
                load_paste_evidence(self.root)
        finally:
            write(path, self.metadata)

    def test_existing_output_is_not_modified_or_launched(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as name:
            output = Path(name) / "existing"; output.mkdir(); sentinel = output / "manifest.json"; sentinel.write_text("untouched\n")
            args = ["--output", str(output), "--cmdy-bin", "/missing/cmdy", "--ghostty-bin", "/missing/ghostty",
                "--cmdy-sha256", "a" * 64, "--ghostty-sha256", "b" * 64, "--display-id", "1",
                "--cmdy-source-manifest", "/missing/manifest", "--cmdy-source-root", "/missing/root",
                "--observer-build", "/missing/build", "--window-helper", "/missing/helper"]
            with patch("paste_bench.TerminalSession") as session, self.assertRaises(FileExistsError):
                main(args)
            session.assert_not_called()
            self.assertEqual(sentinel.read_text(), "untouched\n")
            self.assertEqual(list(output.iterdir()), [sentinel])


if __name__ == "__main__":
    unittest.main()
