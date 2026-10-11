"""Schema-4 generated raw archives and mutations; no GUI or native helper calls."""
from copy import deepcopy
import json
import os
from pathlib import Path
import shlex
import tempfile
import unittest

import memory_parity_evidence as evidence
from history_export_evidence import validate_transfer
from history_export_protocol import ACTION, FILE_LIMIT, SHORTCUT, expectation, validate_export_bytes
from memory_public_history import MEMORY_TOOLING, TRANSPORT
from test_bench_ancestry import ancestry_fixture
from test_history_export import transfer_fixture
from test_memory_bench import RawMemoryEvidenceTests


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def run_path(root, record):
    return root / "runs" / f"{record['block']:02d}-{record['position']:02d}-{record['case']}-{record['terminal']}"


def build_fixture(root, profile="matched", blocks=2, block_start=0):
    """Twelve complete fake runs; invented counters can never be native evidence."""
    legacy = RawMemoryEvidenceTests()
    manifest, records = legacy.fixture(root, profile=profile, schema=3, blocks=blocks, block_start=block_start)
    manifest.update(schemaVersion=4, historyTransport=TRANSPORT)
    manifest["arguments"]["output"] = str(root)
    for terminal, item in manifest["binaries"].items():
        item["path"] = "/owned/" + terminal
    for old in (root / "tooling").iterdir():
        if old.name not in MEMORY_TOOLING:
            old.unlink()
    for name in MEMORY_TOOLING:
        (root / "tooling" / name).write_bytes(("synthetic schema4 source " + name).encode())
    manifest["toolingSHA256"] = {name: evidence.digest(root / "tooling" / name) for name in MEMORY_TOOLING}
    for index, record in enumerate(records):
        run = run_path(root, record)
        fixture = run / "fixture"
        fixture.mkdir(mode=0o700)
        launch = evidence.read(run / "launch.json")
        ready = evidence.read(run / "ready.json")
        (run / "ready.json").unlink()
        app_pid, worker_pid = record["identity"]["appPID"], record["identity"]["workerPID"]
        nonce = manifest["payloads"]["generatedMarker"] + f"{index:016x}"
        capability = f"{index + 100:032x}"
        expected = expectation(record["case"], nonce)
        temporary = f"/private/tmp/cmdy-memory-export-synthetic{index}"
        control = f"/private/tmp/cmdy-memory-control-synthetic{index}/control.sock"
        command = ["/owned/python3.13", "-S", str(root / "tooling/history_export_worker.py"),
            "--output", str(fixture), "--temporary-directory", temporary, "--socket", control,
            "--capability", capability, "--nonce", nonce, "--case", record["case"],
            "--payload", str(root / "payloads" / (record["case"] + ".bin")), "--timeout", "600"]
        binding = dict(schemaVersion=1, transport=TRANSPORT, nonce=nonce, capability=capability,
            expectation=expected, temporaryDirectory=temporary, socketPath=control, worker=command,
            workerSHA256=manifest["toolingSHA256"]["history_export_worker.py"])
        write(run / "public-history-binding.json", binding)
        original_flags = [1, 3, 4, 5, 9600, 9600]
        ready.update(schemaVersion=1, role="history-public-export", pid=worker_pid, parentPID=app_pid,
            ttyPath=f"/dev/ttys{index:03d}", socketPath=control, nonce=nonce, temporaryDirectory=temporary,
            startedTicks=launch["startedMonotonicNS"] + 100, startedMonotonicNS=launch["startedMonotonicNS"] + 50,
            ttyFlagsBefore=original_flags, onlcrEnabled=True, outputPostprocessingEnabled=False,
            columns=120, rows=36)
        write(fixture / "ready.json", ready)
        config = run / ("cmdy-config/config" if record["terminal"] == "cmdy" else "ghostty.config")
        cwd = f"/private/tmp/cmdy-drain-synthetic{index}/work"
        config.write_text(config.read_text().replace("/isolated/work", cwd)
                          + "keybind = " + SHORTCUT + "=" + ACTION + "\n")
        domain = "com.cmdy.bench." + f"{index + 500:032x}"
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": temporary + "/",
            "ZDOTDIR": str(run / "zsh"), "XDG_CONFIG_HOME": str(run / "xdg-config"),
            "XDG_DATA_HOME": str(run / "xdg-data"), "XDG_CACHE_HOME": str(run / "xdg-cache"),
            "XDG_STATE_HOME": str(run / "xdg-state"), "CMDY_CONFIG_DIR": str(run / "cmdy-config"),
            "CMDY_DEFAULTS_DOMAIN": domain}
        argv = [manifest["binaries"][record["terminal"]]["path"]]
        if record["terminal"] == "ghostty":
            argv += ["--config-default-files=false", "--config-file=" + str(config)]
        launch.update(arguments=argv, cwd=cwd, defaultsDomain=domain, config=str(config),
            configSHA256=evidence.digest(config), environment=environment, fixtureCommand=command,
            readyPath=str(fixture / "ready.json"), drainFixtureSource=None,
            fixtureReadyMonotonicNS=ready["readyMonotonicNS"],
            fixtureReadyObservedMonotonicNS=ready["readyMonotonicNS"] + 10)
        (run / "zsh").mkdir()
        (run / "zsh/.zshenv").write_text("unsetopt RCS\nexec " + shlex.join(command) + "\n")
        write(run / "launch.json", launch)
        write(run / "cleanup.json", {"appPID": app_pid, "fixtureQuit": False, "returncode": -15})
        app = dict(pid=app_pid, parentPID=1, uid=501, startSeconds=1_000_000 + index,
            startMicroseconds=7, executable=argv[0])
        worker = dict(pid=worker_pid, parentPID=app_pid, uid=501, startSeconds=2_000_000 + index,
            startMicroseconds=8, executable=command[0])
        for sample in record["samples"]:
            for role, identity in (("app", app), ("worker", worker)):
                sample[role].update(processStartSeconds=identity["startSeconds"],
                                    processStartMicroseconds=identity["startMicroseconds"])
        begin = record["samples"][-1]["guardFinishedMonotonicNS"] + 100
        def owner(tick):
            chain, _, _ = ancestry_fixture(app, worker, start=tick)
            return dict(identity=deepcopy(app), workerIdentity=deepcopy(worker), ancestry=chain,
                window=dict(identity=deepcopy(app), windowID=record["window"]["windows"][0]["windowID"],
                    displayID=1, foregroundPID=app_pid, occluded=False, queriedTicks=tick + 20,
                    bounds=deepcopy(record["window"]["windows"][0]["bounds"])),
                grid=dict(columns=120, rows=36), ttyPath=ready["ttyPath"], ttyDevice=7, workerTTYDevice=7,
                workerProcessGroup=worker_pid, workerForegroundGroup=worker_pid)
        transfer, raw = transfer_fixture(record["case"])
        proof = transfer["export"]
        received_path = temporary + "/generated.txt"
        proof.update(pathReceiptASCII=received_path, pathBytes=len(received_path),
                     validation=validate_export_bytes(raw, expected))
        proof["opened"]["uid"] = proof["afterRead"]["uid"] = proof["beforeInventory"]["directory"]["uid"] = 501
        arm = dict(armedTicks=begin + 200, armedMonotonicNS=begin + 201,
                   deadlineMonotonicNS=begin + 201 + 3_000_000_000, beforeInventory=proof["beforeInventory"])
        complete = begin + 201 + 3_000_000_000 + 100
        proof.update(receiveStartedTicks=arm["armedTicks"], receiveCompletedTicks=complete,
            receiveStartedMonotonicNS=arm["armedMonotonicNS"], receiveCompletedMonotonicNS=complete + 1,
            receiveDeadlineMonotonicNS=arm["deadlineMonotonicNS"], receiveWindowSeconds=3,
            chunks=[dict(bytes=proof["pathBytes"], ticks=begin + 450, monotonicNS=begin + 451)])
        before, after = dict(ok=True, op="inspect", owner=owner(begin + 10)), dict(ok=True, op="inspect", owner=owner(complete + 100))
        action = dict(ok=True, op="post-key", intendedAction=ACTION, actionInvocationVerified=False,
            shortcut=SHORTCUT, keyCode=36, eventCount=2, modifierFlags=0x60000,
            eventTypes=["keyDown", "keyUp"], autorepeat=0,
            targetPID=app_pid, foregroundActivated=False, beforeTicks=begin + 400, betweenTicks=begin + 401,
            afterTicks=begin + 402, beforeOwner=owner(begin + 300), afterOwner=owner(begin + 500))
        initial_spec = dict(pid=app_pid, workerPID=worker_pid, ttyPath=ready["ttyPath"], nonce=nonce,
            windowID=record["window"]["windows"][0]["windowID"], displayID=1,
            executableSHA256=manifest["binaries"][record["terminal"]]["sha256"])
        native_spec = dict(initial_spec, expectedApp=app, expectedWorker=worker)
        transfer = dict(schemaVersion=1, terminal=record["terminal"], expectation=expected, nativeSpec=native_spec,
            workerReady=ready, workerArm=arm, action=action, export=proof,
            beforeOwner=before["owner"], afterOwner=after["owner"])
        raw_drain = {key: value for key, value in record["drain"].items() if key not in ("ok", "windowBefore", "windowAfter")}
        prepared = dict(expectation=expected, grid=dict(columns=120, rows=36), bytes=record["payloadBytes"],
                        sha256=record["payloadSHA256"], drain=raw_drain)
        def reply(mode, armed, exported):
            return dict(schemaVersion=1, ok=True, pid=worker_pid, capability=capability,
                mode=mode, grid=dict(columns=120, rows=36), error="", prepared=prepared,
                arm=armed, proof=exported, unexpectedInputBytes=0)
        record["drain"].update(reply("prepared", None, None))
        record["historyVerification"] = dict(schemaVersion=1, transport=TRANSPORT, ok=True,
            ownedPID=app_pid, workerPID=worker_pid, expectation=expected, before=before, after=after,
            arm=reply("armed", arm, None), action=action, received=reply("received", arm, proof), proof=proof,
            transfer=transfer, transferValidation=validate_transfer(transfer, raw), timebase=dict(numer=1, denom=1),
            hostStartedMonotonicNS=begin, nativeStartedMonotonicNS=action["beforeTicks"],
            nativeFinishedMonotonicNS=complete, hostFinishedMonotonicNS=complete + 200,
            expectedRows=expected["logicalRows"], retainedRows=expected["logicalRows"],
            normalizedSHA256=proof["validation"]["normalizedSHA256"], retainedRawFile="fixture/generated-export.bin")
        finish_reply = reply("received", arm, proof)
        finish = dict(reply=finish_reply, workerExit=dict(pid=worker_pid,
            startIdentity=record["identity"]["workerLaunchIdentity"], exited=True,
            startedMonotonicNS=complete + 400, finishedMonotonicNS=complete + 600))
        cleanup = dict(schemaVersion=1, status="pass", pid=worker_pid, nonce=nonce, finishedTicks=complete + 500,
            reason="controller-finish", errorCode="", inputBytesRetained=0, unexpectedInputBytes=0,
            controlSocketRemoved=True, termiosRestored=True, fileFlagsRestored=True, terminalRestoreWritten=True,
            ttyFlagsOriginal=original_flags[:4], ttyFlagsAfter=original_flags[:4], controls=[
                dict(op="drain", ticks=raw_drain["startedMonotonicNS"] - 1), dict(op="arm", ticks=begin + 190),
                dict(op="status", ticks=complete + 10), dict(op="finish", ticks=complete + 300)])
        for relative, value in [("history-inspect-spec.json", initial_spec), ("history-action-spec.json", native_spec),
                ("fixture/arm.json", arm), ("fixture/prepared.json", prepared), ("fixture/export.json", proof),
                ("history-verification.json", record["historyVerification"]), ("history-finish-reply.json", finish_reply),
                ("history-finish.json", finish), ("fixture/cleanup.json", cleanup), ("memory.json", record)]:
            write(run / relative, value)
        (fixture / "generated-export.bin").write_bytes(raw)
        (fixture / "generated-export.bin").chmod(0o600)
    manifest["finalConditions"] = legacy.conditions(evidence.read(run_path(root, records[-1]) / "history-finish.json")["workerExit"]["finishedMonotonicNS"] + 100)
    write(root / "manifest.json", manifest)
    write(root / "records.json", records)
    return manifest, records


class PublicMemoryEvidenceTests(unittest.TestCase):
    pins = RawMemoryEvidenceTests.pins

    def test_complete_both_profiles_returns_only_raw_memory_and_cpu(self):
        for profile in ("matched", "cmdy-defaults"):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                build_fixture(root, profile)
                value = evidence.load_memory_evidence(root, self.pins)
                self.assertEqual(len(value), 9)
                self.assertEqual({item["kind"] for item in value}, {"memory", "cpu"})
                self.assertEqual([len(v) for p in value[0]["blocks"].values() for v in p.values()], [3, 3, 3, 3])
                self.assertTrue(all(item["profile"] == profile for item in value))

    def test_nonunit_native_clock_timebase_preserves_all_raw_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); build_fixture(root)
            expected = evidence.load_memory_evidence(root, self.pins)
            def convert(key, value):
                if key.endswith("Ticks") or key == "ticks":
                    return value // 2
                if key == "timebaseNumer":
                    return 2
                if key == "timebase":
                    return dict(numer=2, denom=1)
                if key in ("nativeStartedMonotonicNS", "nativeFinishedMonotonicNS"):
                    return value // 2 * 2
                return value
            for path in [root / "records.json", *(root / "runs").rglob("*.json")]:
                edit(path, lambda value: transform_fields(value, convert))
            self.assertEqual(evidence.load_memory_evidence(root, self.pins), expected)

    def test_consistently_resealed_transfer_still_must_join_memory_samples(self):
        def shift_ticks(key, value):
            if key.endswith("Ticks") or key == "ticks" or key in (
                    "nativeStartedMonotonicNS", "nativeFinishedMonotonicNS"):
                return value + 10_000_000_000
            return value
        changes = {
            "different-lifetime": (lambda key, value: value + 1 if key == "startMicroseconds" else value,
                                    "sampled BSD identity"),
            "different-window": (lambda key, value: dict(value, x=value["x"] + 1) if key == "bounds" else value,
                                  "owner clock/window"),
            "different-clock-domain": (shift_ticks, "owner clock/window"),
        }
        for name, (change, error) in changes.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); _, records = build_fixture(root)
                run = run_path(root, records[0])
                # Reseal every duplicate, including raw native/control/worker records.
                for path in [*run.glob("history-*.json"), *(run / "fixture").glob("*.json")]:
                    edit(path, lambda value: transform_fields(value, change))
                for path in (root / "records.json", run / "memory.json"):
                    value = evidence.read(path)
                    record = value[0] if isinstance(value, list) else value
                    transform_fields(record["historyVerification"], change)
                    write(path, value)
                audit = evidence.read(run / "history-verification.json")
                self.assertEqual(validate_transfer(audit["transfer"], (run / "fixture/generated-export.bin").read_bytes()),
                                 audit["transferValidation"])
                with self.assertRaisesRegex(ValueError, error):
                    evidence.load_memory_evidence(root, self.pins)

    def test_retained_export_is_private_bounded_and_never_follows_replacements(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, records = build_fixture(root)
            fixture = run_path(root, records[0]) / "fixture"
            path = fixture / "generated-export.bin"; raw = path.read_bytes()
            for name in ("file-symlink", "directory-symlink", "hardlink", "public-mode", "oversized", "empty"):
                with self.subTest(name=name):
                    other = fixture.parent / "original-fixture" if name == "directory-symlink" else fixture / "original.bin"
                    if name == "file-symlink":
                        path.rename(other); path.symlink_to(other)
                    elif name == "directory-symlink":
                        fixture.rename(other); fixture.symlink_to(other, target_is_directory=True)
                    elif name == "hardlink":
                        os.link(path, other)
                    elif name == "public-mode":
                        path.chmod(0o644)
                    else:
                        with path.open("r+b") as stream:
                            stream.truncate(FILE_LIMIT + 1 if name == "oversized" else 0)
                    with self.assertRaises((ValueError, OSError)):
                        evidence.load_memory_evidence(root, self.pins)
                    if name == "file-symlink":
                        path.unlink(); other.rename(path)
                    elif name == "directory-symlink":
                        fixture.unlink(); other.rename(fixture)
                    elif name == "hardlink":
                        other.unlink()
                    path.write_bytes(raw); path.chmod(0o600)
            self.assertEqual(len(evidence.load_memory_evidence(root, self.pins)), 9)

    def test_resealed_record_identity_clock_and_control_mutations_reject(self):
        changes = {
            "summary-only": lambda r: r["historyVerification"].pop("transfer"),
            "fabricated-validation": lambda r: r["historyVerification"]["transferValidation"].update(qualifying=True),
            "missing-sample": lambda r: r["samples"].pop(),
            "bsd-app-lifetime": lambda r: r["samples"][0]["app"].update(processStartSeconds=1),
            "bsd-worker-lifetime": lambda r: r["samples"][1]["worker"].update(processStartMicroseconds=999),
            "clock-timebase": lambda r: r["historyVerification"]["timebase"].update(numer=2),
            "fake-native-start": lambda r: r["historyVerification"].update(nativeStartedMonotonicNS=1),
            "audit-before-sampling": lambda r: r["historyVerification"].update(hostStartedMonotonicNS=1),
            "wrong-control-capability": lambda r: r["drain"].update(capability="0" * 32),
            "missing-complete-control": lambda r: r["historyVerification"]["received"].update(mode="armed"),
            "wrong-file-name": lambda r: r["historyVerification"].update(retainedRawFile="summary.json"),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, original = build_fixture(root)
            run = run_path(root, original[0])
            for name, change in changes.items():
                with self.subTest(name=name):
                    records = deepcopy(original); change(records[0])
                    write(root / "records.json", records); write(run / "memory.json", records[0])
                    write(run / "history-verification.json", records[0]["historyVerification"])
                    with self.assertRaises((ValueError, KeyError, TypeError)):
                        evidence.load_memory_evidence(root, self.pins)

    def test_independent_raw_files_launch_finish_and_inventory_mutations_reject(self):
        changes = {
            "actual-last-row": ("fixture/generated-export.bin", lambda p: p.write_bytes(p.read_bytes().replace(b"ROW_000999", b"ROW_000998"))),
            "prepared-not-same-drain": ("fixture/prepared.json", lambda p: edit(p, lambda v: v["drain"].update(elapsedNS=3))),
            "worker-not-exited": ("history-finish.json", lambda p: edit(p, lambda v: v["workerExit"].update(exited=False))),
            "finish-wrong-lifetime": ("history-finish.json", lambda p: edit(p, lambda v: v["workerExit"].update(startIdentity="other"))),
            "cleanup-input": ("fixture/cleanup.json", lambda p: edit(p, lambda v: v.update(unexpectedInputBytes=1))),
            "cleanup-tty": ("fixture/cleanup.json", lambda p: edit(p, lambda v: v["ttyFlagsAfter"].__setitem__(0, 0))),
            "cleanup-controls": ("fixture/cleanup.json", lambda p: edit(p, lambda v: v["controls"].insert(1, dict(op="prepare", ticks=1)))),
            "wrong-launch-worker": ("launch.json", lambda p: edit(p, lambda v: v["fixtureCommand"].__setitem__(1, "-I"))),
            "foreign-tmpdir": ("launch.json", lambda p: edit(p, lambda v: v["environment"].update(TMPDIR="/tmp/"))),
            "unexpected-shell": ("zsh/.zshenv", lambda p: p.write_text(p.read_text() + "echo unexpected\n")),
            "native-target": ("history-action-spec.json", lambda p: edit(p, lambda v: v.update(executableSHA256="f" * 64))),
            "missing-arm": ("fixture/arm.json", lambda p: p.unlink()),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, records = build_fixture(root); run = run_path(root, records[0])
            for name, (relative, mutate) in changes.items():
                with self.subTest(name=name):
                    path = run / relative; before = path.read_bytes(); mutate(path)
                    with self.assertRaises((ValueError, KeyError, TypeError, OSError)):
                        evidence.load_memory_evidence(root, self.pins)
                    path.write_bytes(before)
            (root / "tooling/unregistered.py").write_text("synthetic")
            with self.assertRaisesRegex(ValueError, "inventory"):
                evidence.load_memory_evidence(root, self.pins)


def edit(path, mutation):
    value = evidence.read(path); mutation(value); write(path, value)


def transform_fields(value, transform):
    """Change deserialized fields without concealing duplicate-record mismatches."""
    if isinstance(value, dict):
        for key, item in value.items():
            transform_fields(item, transform)
            value[key] = transform(key, item)
    elif isinstance(value, list):
        for item in value:
            transform_fields(item, transform)


if __name__ == "__main__":
    unittest.main()
