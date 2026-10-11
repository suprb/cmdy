#!/usr/bin/env python3
"""Independent v2 generated-cell diagnostic event validator. Never admits resize parity."""
from __future__ import annotations

import argparse
import base64
import binascii
import json
import math
from pathlib import Path

from resize_controller import METRIC, expected_event
from resize_protocol import GRIDS, digest, check_grid, FIXTURE_VERSION, cell_classes_bytes, growth_guard_enabled
from bench_ancestry import validate_kernel_ancestry
from resize_contract import OBSERVATION_SCOPE, require_qualifying_adapter
from resize_calibration_evidence import validate_discovery, validate_display_capture


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    return json.loads(Path(path).read_text())


def file_hash(path):
    return digest(Path(path).read_bytes())


def integer(value, name, minimum=0):
    require(type(value) is int and minimum <= value <= (1 << 63) - 1, "invalid " + name)
    return value


def signed_ns(end, start, timebase):
    integer(end, "end ticks"); integer(start, "start ticks")
    numer = integer(timebase["numer"], "timebase numerator", 1)
    denom = integer(timebase["denom"], "timebase denominator", 1)
    require(numer <= 1_000_000_000 and denom <= 1_000_000_000, "implausible clock timebase")
    value = abs(end - start) * numer // denom
    require(value <= (1 << 63) - 1, "signed nanoseconds overflow")
    return value if end >= start else -value


def config_signature(contents, cwd, terminal):
    """Normalize only the exact owned cwd token, never arbitrary settings."""
    if terminal == "ghostty":
        original = "working-directory = " + str(cwd) + "\n"
        require(contents.count(original) == 1, "exact owned working-directory setting missing")
        contents = contents.replace(original, "working-directory = <OWNED_WORKING_DIRECTORY>\n")
    return digest(contents.encode())


def validate_proof(proof, display, bounds=None):
    require(proof.get("proofScope") is None and proof.get("schemaVersion") is None,
            "file-transport proof cannot authorize a resize frame")
    require(proof["identity"] == display["identity"] and proof["foregroundPID"] == display["identity"]["pid"]
        and proof["windowID"] == display["windowID"] > 0 and proof["displayID"] == display["displayID"]
        and proof["occluded"] is False, "owned process/window/display/focus proof differs")
    require(all(type(proof["bounds"][part]) in (float, int) and math.isfinite(proof["bounds"][part])
        for part in ("x", "y", "width", "height")), "invalid native bounds")
    integer(proof["queriedTicks"], "proof clock", 1)
    if bounds is not None:
        require(proof["bounds"] == bounds, "native target bounds differ")


def validate_event(entry, planned, nonce, display, source, target, *, history_growth_guard=False):
    """Recompute metric and first-match selection from raw frame chronology."""
    validate_display_capture(display)
    require(display.get("observationScope") == OBSERVATION_SCOPE and display.get("qualifying") is False
            and display.get("requestClock") == "mach_absolute_time"
            and display.get("frameClock") == "SCStreamFrameInfo.displayTime",
            "native Mach/WindowServer clock sources or fixture scope differ")
    check_grid(source["columns"], source["rows"])
    check_grid(target["columns"], target["rows"])
    require((source["columns"], source["rows"]) != (target["columns"], target["rows"]),
            "event must change between both frozen grids")
    require((planned["columns"], planned["rows"]) == (target["columns"], target["rows"]),
            "planned target does not match calibration")
    require(type(planned["warmup"]) is bool, "warmup must be explicit boolean")
    validate_kernel_ancestry(display["initialAncestry"], display["identity"], display["workerIdentity"])
    expected = expected_event(nonce, planned, history_growth_guard=history_growth_guard)
    require(entry["expected"] == expected, "event plan/generation differs")
    worker, observer = entry["worker"], entry["observer"]
    require(observer.get("observationScope") == OBSERVATION_SCOPE and observer.get("qualifying") is False
            and observer.get("fixtureVersion") == display.get("fixtureVersion") == FIXTURE_VERSION,
            "wrong fixture version/scope or diagnostic claims qualification")
    sequence = expected["sequence"]
    for value in (worker["sequence"], observer["sequence"]): integer(value, "sequence")
    require(worker["sequence"] == observer["sequence"] == sequence, "event sequence differs")
    grid = {"columns": expected["columns"], "rows": expected["rows"]}
    require(worker["grid"] == observer["finalTTYGrid"] == grid, "real TTY target differs")
    require(worker["sourceGrid"] == [source["columns"], source["rows"]], "worker source grid differs")
    integer(worker["offeredBytes"], "offered bytes", 1)
    integer(worker["completedBytes"], "completed bytes", 1)
    require(worker["offeredBytes"] == worker["completedBytes"] == expected["payloadBytes"]
        and worker["payloadSHA256"] == expected["payloadSHA256"], "generated byte work differs")
    require(integer(worker["signalCounter"], "signal counter", 1) > integer(worker["armSignalCounter"], "arm counter"),
            "repaint lacks actual new SIGWINCH")
    arm = entry["arm"]
    integer(arm["pending"]["signalCounter"], "arm proof counter")
    integer(arm["pending"]["sequence"], "arm proof sequence")
    require(arm.get("ok") is True and arm["pid"] == display["workerIdentity"]["pid"]
        and arm["pending"] == {"sequence": sequence, "target": [grid["columns"], grid["rows"]],
                              "signalCounter": worker["armSignalCounter"]}, "socket arm proof differs")
    action = observer["action"]
    require(observer.get("ok") is True and observer.get("op") == "complete"
        and action["axCallCount"] == 1 and action["axResult"] == 0 and not action.get("error"),
        "single native AX action failed")
    integer(action["axCallCount"], "AX call count", 1)
    require(type(action["axResult"]) is int, "AX status must be integer")
    require(action["requestedBounds"] == target["outerBounds"], "AX requested different target")
    validate_proof(action["beforeProof"], display, source["outerBounds"])
    validate_proof(action["afterProof"], display)
    start = integer(action["beforeTicks"], "request start", 1)
    returned = integer(action["afterTicks"], "request return", 1)
    require(action["beforeProof"]["queriedTicks"] <= start <= returned
        <= action["afterProof"]["queriedTicks"], "native request/guard clocks differ")
    require(source["outerBounds"]["x"] == target["outerBounds"]["x"]
        and source["outerBounds"]["y"] == target["outerBounds"]["y"], "measured event changes position")
    frames = observer["frames"]
    require(0 < len(frames) <= 500, "missing or unbounded complete-frame chronology")
    first = None
    previous = 0
    previous_callback = 0
    window_id = action["beforeProof"]["windowID"]
    for frame in frames:
        ticks = [integer(frame[key], key, 1) for key in ("displayTicks", "callbackTicks", "checkedTicks")]
        require(previous <= ticks[0] and previous_callback <= ticks[1] <= frame["before"]["queriedTicks"]
            <= frame["after"]["queriedTicks"] <= ticks[2], "signed SCK clock chronology differs")
        previous = ticks[0]
        previous_callback = ticks[1]
        require(type(frame["matching"]) is bool, "frame match is not boolean")
        for proof in (frame["before"], frame["after"]):
            validate_proof(proof, display, target["outerBounds"] if frame["matching"] else None)
            require(proof["windowID"] == window_id, "window identity changed during observation")
        if ticks[0] < start:
            continue
        if first is not None:
            require(frame["matching"] is True, "first complete repaint did not stay correct")
        elif frame["matching"]:
            require(ticks[1] >= start, "matching-frame callback predates request")
            first = frame
    require(first is not None, "no complete post-request matching frame")
    statuses = observer["statusRecords"]
    require(0 < len(statuses) <= 500, "SCK status chronology missing or unbounded")
    finished = integer(observer["finishedTicks"], "observation completion", 1)
    final_query = integer(observer["finalProof"]["queriedTicks"], "final proof clock", 1)
    last_status = 0
    for record in statuses:
        callback = integer(record["callbackTicks"], "status callback", 1)
        display_ticks = record.get("displayTicks")
        if display_ticks is not None: integer(display_ticks, "status display")
        require(type(record["status"]) is int and record["status"] in (0, 1, 2, 4)
            and callback >= last_status, "unknown, suspended, stopped or unordered SCK status")
        require(record["status"] != 0 or (display_ticks or 0) > 0, "complete status lacks display clock")
        require(max(callback, display_ticks or 0) <= final_query, "status clocks are outside final validation")
        last_status = callback
        if callback >= first["callbackTicks"] or (display_ticks or 0) >= first["displayTicks"]:
            require(record["status"] in (0, 1), "blank/restarted capture after first complete repaint")
    frame_keys = [(row["callbackTicks"], row["displayTicks"]) for row in frames]
    status_keys = [(row["callbackTicks"], row["displayTicks"]) for row in statuses if row["status"] == 0]
    require(len(set(frame_keys)) == len(frame_keys) and len(set(status_keys)) == len(status_keys)
            and frame_keys == status_keys,
            "complete frame/status records are not a one-to-one ordered correspondence")
    result = observer["firstCompleteFrame"]
    encoded = result["observedCellClasses"]
    require(isinstance(encoded, str) and len(encoded) <= 7040,
            "observed cell stream is missing or unbounded")
    try: observed_cells = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error: raise ValueError("invalid observed cell base64") from error
    wanted_cells = cell_classes_bytes(nonce, sequence, target["columns"], target["rows"])
    require(observed_cells == wanted_cells and first.get("observedCellClasses") == encoded,
            "pixel-derived full-width observed cell stream differs")
    require(all(frame.get("observedCellClasses") is None for frame in frames if frame is not first),
            "cell streams must be retained only for the first matching frame")
    integer(result["matchedRows"], "matched row count", 1)
    integer(result["matchedCells"], "matched cell count", 1)
    require(result["matchedCells"] == len(observed_cells) == target["columns"] * target["rows"]
            and result["cellClassesSHA256"] == digest(observed_cells) == expected["cellClassesSHA256"],
            "full-width cell count/content proof differs")
    require(result["complete"] is True and result["matchedRows"] == expected["rows"]
        and result["words"] == expected["words"], "every-row/CRC/context proof differs")
    require(all(result[key] == first[key] for key in ("displayTicks", "callbackTicks", "checkedTicks"))
        and result["beforeProof"] == first["before"] and result["afterProof"] == first["after"],
        "later frame substituted for first matching repaint")
    times = [worker["armedTicks"], start, worker["signalReceivedTicks"], worker["observedTicks"],
             worker["startedTicks"], first["displayTicks"]]
    for value in times: integer(value, "worker causality clock", 1)
    require(times == sorted(times),
            "arm/AX/SIGWINCH/ioctl/write/frame causality differs")
    integer(worker["completedTicks"], "write completion", 1)
    require(worker["completedTicks"] >= worker["startedTicks"], "write completed before starting")
    require(display["initialAncestry"]["finishedTicks"] <= worker["armedTicks"],
            "initial ancestry was captured after the event started")
    validate_kernel_ancestry(observer["finalAncestry"], display["identity"], display["workerIdentity"])
    require(final_query <= observer["finalAncestry"]["startedTicks"]
            <= observer["finalAncestry"]["finishedTicks"] <= finished,
            "final ancestry clocks are not enclosed by event completion")
    validate_proof(observer["finalProof"], display, target["outerBounds"])
    require(observer["finalProof"]["windowID"] == window_id
        and max(returned, action["afterProof"]["queriedTicks"],
                *(max(frame["displayTicks"], frame["checkedTicks"]) for frame in frames)) <= final_query <= finished,
        "final target identity/clock differs")
    tb = display["timebase"]
    recomputed = {"requestToFrameNS": signed_ns(first["displayTicks"], start, tb),
        "requestReturnOffsetNS": signed_ns(returned, start, tb),
        "frameMinusRequestReturnNS": signed_ns(first["displayTicks"], returned, tb),
        "captureCallbackLagNS": signed_ns(first["callbackTicks"], first["displayTicks"], tb),
        "stabilityValidationNS": signed_ns(finished, first["callbackTicks"], tb)}
    require(all(type(value) is int for value in observer["metricsNS"].values()),
            "signed metrics must be exact integer nanoseconds")
    require(recomputed == observer["metricsNS"] and 0 <= recomputed["requestToFrameNS"] <= 3_000_000_000
        and signed_ns(finished, max(first["displayTicks"], first["callbackTicks"]), tb) >= 50_000_000
        and signed_ns(finished, start, tb) <= 3_000_000_000, "signed metric/stability recomputation differs")
    require(all(observer[field] is True for field in ("stableAfterFirst", "ownershipValid", "signedClockValid"))
        and observer["observerFailures"] == [], "incomplete observer qualification")
    return recomputed["requestToFrameNS"]



def validate_document(document):
    """A valid event is still diagnostic: equal retained history is not proven."""
    require(document["schemaVersion"] == 1 and document["case"] == "resize"
            and document["metric"] == METRIC and document["qualifying"] is False,
            "unrecognized diagnostic envelope")
    before = document["entry"]["observer"]["action"]["beforeTicks"]
    require(validate_discovery(document["sourceDiscovery"], document["display"], before) == document["source"]
            and validate_discovery(document["targetDiscovery"], document["display"], before) == document["target"],
            "diagnostic does not bind exact native calibration discoveries")
    latency = validate_event(document["entry"], document["planned"], document["nonce"],
                             document["display"], document["source"], document["target"],
                             history_growth_guard=growth_guard_enabled(document))
    return {"schemaVersion": 1, "case": "resize", "diagnosticValid": True,
            "qualifying": False, "observationScope": OBSERVATION_SCOPE,
            "metric": METRIC, "requestToGeneratedCellViewportNS": latency}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("document", type=Path)
    parser.add_argument("--qualify", action="store_true",
                        help="always rejects: native calibration and retained history are unproven")
    args = parser.parse_args(argv)
    try:
        if args.qualify: require_qualifying_adapter()
        if args.document.stat().st_size > 4 * 1024 * 1024:
            raise ValueError("diagnostic document exceeds 4 MiB bound")
        result = validate_document(read(args.document))
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(json.dumps({"diagnosticValid": False, "qualifying": False, "error": str(error)}, sort_keys=True))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__": raise SystemExit(main())
