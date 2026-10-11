"""Independent complete diagnostic batch reader. Does not admit resize parity."""
import json
from pathlib import Path

from history_export_evidence import validate_transfer
from history_export_protocol import resize_batch_expectation
from resize_batch_evidence import validate_frozen_view
from resize_calibration_evidence import validate_discovery
from resize_controller import expected_event
from resize_evidence import require, signed_ns, validate_document
from resize_protocol import GRIDS, SEPARATOR_ROWS, digest, frame_bytes, growth_guard_enabled, history, sequence_plan


def read(path):
    return json.loads(Path(path).read_text())


def observer_records(directory, expected_spec):
    root = directory / "native"
    require(read(root / "spec.json") == expected_spec, "observer native spec differs")
    paths = sorted(root.glob("[0-9][0-9][0-9][0-9].json"))
    require([p.name for p in paths] == [f"{i:04d}.json" for i in range(1, len(paths)+1)],
            "observer record sequence is incomplete")
    records = [read(p) for p in paths]
    cleanup = read(root / "cleanup.json")
    require(cleanup["exited"] is True and cleanup["pipesClosed"] is True
            and cleanup["successfulBlock"] is True and cleanup["returncode"] == 0
            and "error" not in cleanup, "observer cleanup is not complete")
    require(records[0]["op"] == "started" and records[-1]["op"] == "finished"
            and all(v.get("ok") is True for v in records), "observer response failed")
    return records, cleanup["ownedPID"]


def validate_batch(directory):
    directory = Path(directory); batch = directory / "batch"
    request = read(batch / "request.json"); ready = read(directory / "fixture/ready.json")
    received = read(directory / "fixture/received.json"); cleanup = read(directory / "fixture/cleanup.json")
    nonce, block = request["nonce"], request["block"]
    spec = request["nativeSpec"]; plan = sequence_plan(block)
    guarded = growth_guard_enabled(request)
    require(guarded == growth_guard_enabled(ready), "batch repaint history guard differs")
    require(request["schemaVersion"] == 1 and request["qualifying"] is False
            and request["workerReady"] == ready and ready["nonce"] == spec["nonce"] == nonce
            and ready["pid"] == spec["workerPID"] == cleanup["pid"]
            and ready["ttyPath"] == spec["ttyPath"] and ready["pairedBlock"] == block
            and ready["calibrationNonce"] != nonce, "batch identity or scope differs")
    require(cleanup["error"] == "" and cleanup["stopReason"] == "controller-finish"
            and cleanup["calibrationEvents"] == 2 and cleanup["batchEvents"] == 42
            and cleanup["historyExports"] == 2 and cleanup["exportInputBytesRetained"] == 0
            and cleanup["unexpectedCleanupInputBytes"] == 0 and cleanup["pending"] is None
            and cleanup["uncompletedOfferedSequence"] is None
            and all(cleanup[k] is True for k in ("termiosRestored", "fileFlagsRestored",
                "terminalRestoreWritten", "signalWakeupRestored", "signalPipeClosed")),
            "full worker cleanup differs")
    finish = read(batch / "worker-finish.json")
    require(finish["ok"] is True and finish["error"] == ""
            and finish["grid"] == dict(columns=120, rows=36)
            and finish["pid"] == ready["pid"] and finish["capability"] == request["workerCapability"]
            and finish["completedEvents"] == 42 and finish["events"] == received["events"]
            and finish["historyTransfer"] == received["historyTransfer"]
            and finish["calibrationEvents"] == received["calibrationEvents"]
            and finish["batchStart"] == received["batchStart"] and finish["pending"] is None,
            "final worker receipt differs")
    require(len(received["calibrationEvents"]) == 2
            and len(received["historyTransfer"]["completed"]) == 2
            and received["historyTransfer"]["active"] is None,
            "calibration or export coverage differs")
    for sequence, event in enumerate(received["calibrationEvents"], 1):
        payload = frame_bytes(ready["calibrationNonce"], sequence, *GRIDS[sequence % 2], history_growth_guard=guarded)
        require(event["sequence"] == sequence and event["epoch"] == "calibration"
                and event["grid"] == dict(zip(("columns", "rows"), GRIDS[sequence % 2]))
                and event["payloadSHA256"] == digest(payload)
                and event["offeredBytes"] == event["completedBytes"] == len(payload),
                "calibration workload differs")
    small, large = request["smallDiscovery"], request["largeDiscovery"]
    for value, grid in zip((small, large), GRIDS):
        geometry = validate_discovery(value)
        require((geometry["columns"], geometry["rows"]) == grid, "calibration grid differs")
    corpus = history(nonce)
    require((directory / "fixture/history.bin").read_bytes() == corpus
            and received["history"]["completedBytes"] == len(corpus)
            and received["history"]["payloadSHA256"] == digest(corpus)
            and received["batchStart"]["historyReloaded"] is False,
            "original history was changed or reloaded")
    records, observer_pid = observer_records(batch / "timed", spec)
    require(len(records) == 87 and records[1] == read(batch / "after-before-export-viewport.json"),
            "persistent observer does not cover exactly 42 events")
    display = records[0]
    for value in (small, large): validate_discovery(value, display)
    require(display["identity"]["pid"] == spec["pid"] and display["workerIdentity"]["pid"] == ready["pid"]
            and display["windowID"] == spec["windowID"] and display["displayID"] == spec["displayID"],
            "batch native ownership differs")
    exports = {}
    for index, phase in enumerate(("before", "after")):
        root = batch / f"{phase}-history"; document = read(root / "document.json")
        raw = (root / "generated-export.bin").read_bytes()
        transfer = received["historyTransfer"]["completed"][index]
        require(document["schemaVersion"] == 5
                and document["expectation"] == resize_batch_expectation(nonce, phase, history_growth_guard=guarded)
                and document["workerReady"] == ready and document["export"] == transfer["proof"]
                and document["workerArm"] == transfer["arm"]
                and all(document["nativeSpec"][k] == v for k, v in spec.items())
                and raw == (directory / f"fixture/history-exports/{phase}/generated-export.bin").read_bytes(),
                "batch history source or phase differs")
        validate_transfer(document, raw); exports[phase] = document
    require(exports["before"]["export"]["validation"]["normalizedSHA256"]
            == exports["after"]["export"]["validation"]["normalizedSHA256"], "history content changed")
    pids = [observer_pid]
    for name, sequence, after_ticks, before_ticks in (
        ("before-export-viewport", block*42, 0, exports["before"]["action"]["beforeTicks"]),
        ("before-final-export-viewport", block*42+42, 0, exports["after"]["action"]["beforeTicks"]),
        ("after-final-export-viewport", block*42+42, exports["after"]["export"]["receiveCompletedTicks"], None)):
        rows, pid = observer_records(batch / name, spec); pids.append(pid)
        require(len(rows) == 3 and rows[1] == read(batch / name / "viewport.json"), "viewport stream differs")
        validate_frozen_view(rows[1], nonce, sequence, rows[0], small,
                             after_ticks=after_ticks, before_ticks=before_ticks)
    validate_frozen_view(records[1], nonce, block*42, display, small,
                         after_ticks=exports["before"]["export"]["receiveCompletedTicks"])
    files = sorted((batch / "timed").glob("event-*.json"))
    require([p.name for p in files] == [f"event-{i:02d}.json" for i in range(42)], "batch event coverage differs")
    samples = []; previous_finish = max(records[1]["checkedTicks"], records[1]["displayTicks"])
    for index, (path, planned) in enumerate(zip(files, plan)):
        document = read(path); observed = document["entry"]["observer"]
        require(document["planned"] == planned and document["nonce"] == nonce and document["display"] == display
                and growth_guard_enabled(document) == guarded
                and document["sourceDiscovery"] == (small if index % 2 == 0 else large)
                and document["targetDiscovery"] == (large if index % 2 == 0 else small)
                and document["entry"]["worker"] == received["events"][index]
                and observed == records[3+2*index] and records[2+2*index]["op"] == "armed"
                and records[2+2*index]["sequence"] == planned["sequence"], "event provenance differs")
        arm = document["entry"]["arm"]
        require(arm["pid"] == ready["pid"] and arm["capability"] == request["workerCapability"]
                and arm["events"] == received["events"][:index]
                and arm["historyTransfer"]["completed"] == received["historyTransfer"]["completed"][:1]
                and arm["historyTransfer"]["active"] is None, "worker arm continuity differs")
        validate_document(document)
        gap = signed_ns(observed["action"]["beforeTicks"], previous_finish, display["timebase"])
        minimum = 0 if index == 0 else expected_event(nonce, plan[index-1], history_growth_guard=guarded)["postStabilityGapMS"] * 1_000_000
        require(gap >= minimum, "events overlap or omit the fixed post-stability gap")
        previous_finish = observed["finishedTicks"]
        if not planned["warmup"]: samples.append(observed["metricsNS"]["requestToFrameNS"])
    require(previous_finish <= exports["after"]["action"]["beforeTicks"], "final export precedes batch completion")
    final_view = read(batch / "before-final-export-viewport/viewport.json")
    require(min(final_view["displayTicks"], final_view["callbackTicks"]) >= previous_finish,
            "final history viewport predates completed batch")
    expected_writes = {
        ("calibration", "prepare-controls", None): b"\x1b[0m\x1b[?7h\x1b[?25l\x1b[2J\x1b[H",
        ("calibration", "history", None): corpus,
        ("calibration", "history-separators", None): b"\r\n" * SEPARATOR_ROWS,
        ("calibration", "initial-frame", 0): frame_bytes(ready["calibrationNonce"], 0, *GRIDS[0], history_growth_guard=guarded),
        ("batch", "batch-initial-frame", block*42): frame_bytes(nonce, block*42, *GRIDS[0], history_growth_guard=guarded)}
    for sequence in (1, 2):
        expected_writes[("calibration", "resize-frame", sequence)] = frame_bytes(ready["calibrationNonce"], sequence, *GRIDS[sequence % 2], history_growth_guard=guarded)
    for row in plan:
        expected_writes[("batch", "resize-frame", row["sequence"])] = frame_bytes(nonce, row["sequence"], row["columns"], row["rows"], history_growth_guard=guarded)
    counts = {}; last_tick = 0
    for row in received["writes"]:
        key = row["epoch"], row["label"], row["sequence"]
        require(key in expected_writes and row["offset"] == counts.get(key, 0) and row["bytes"] > 0
                and last_tick <= row["beforeTicks"] <= row["afterTicks"], "generated write chronology differs")
        counts[key] = counts.get(key, 0) + row["bytes"]; last_tick = row["afterTicks"]
    require(counts == {key: len(value) for key, value in expected_writes.items()}, "generated writes are incomplete or duplicated")
    return dict(status="independently-valid-complete-diagnostic-resize-batch", qualifying=False,
                performanceAdmission=False, terminal=request["terminal"], profile=request["profile"],
                historyGrowthGuardRows=4 if guarded else 0,
                block=block, events=42, warmups=2, measuredEvents=40, historyExports=2,
                viewportProofs=4, observerPIDs=pids, samplesNS=samples)
