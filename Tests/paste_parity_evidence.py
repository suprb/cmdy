#!/usr/bin/env python3
"""Independent read-only paste adapter. Rebuild latency from native frame clocks.

Never executes retained tooling, opens a clipboard, queries a process, chooses
percentiles, changes policy, or trusts worker emit times/summary durations.
"""
from __future__ import annotations
import base64
import binascii
from datetime import datetime
from functools import lru_cache
import hashlib
import math
from pathlib import Path
import re
import termios

from bench_ancestry import validate_kernel_ancestry
from competitive_bench import BenchOptions, native_condition_signature
from paste_protocol import (BARCODE_COLUMNS, BLOCKS, CASE, ENABLED_ROW, GRID, GUARD_NS, INITIAL_ROW, INITIAL_SETTLE_NS,
    METRIC, PAYLOAD_BYTES, SAMPLES, WARMUPS, expected_receipt, preparation, response_first_row,
    row_symbols, viewport_sha256)
from paste_contract import config_text, validate_launch
from paste_dictionary import validate_sdef
from scroll_parity_evidence import (canonical, checked_window_helper, clock_interval, digest,
    fixture_probe, positive_int, power, read, require, tty, window)
from scroll_protocol import validate_frame_clock


def fourcc(value):
    return int.from_bytes(value.encode("ascii"), "big")


SEND_OPTIONS = 3 | 16 | 4096  # waitForReply | neverInteract | dontRecord


def checked_tooling_sources(hashes):
    from paste_bench import SOURCES
    require(set(hashes) == set(SOURCES), "retained paste source inventory differs")
    current = {name: digest(Path(__file__).resolve().parent / name) for name in SOURCES}
    # Exact complete source bundle used by the admitted AC/defaults and matched
    # cohorts before the capture-queue arm correction. Never execute archive
    # code or accept per-file mixtures. All raw evidence checks below still run.
    before_queue_correction = "2067429ce56fbdffe28f7dba1327cc5102f82e9718f15335036b11a19164e6fd"
    require(hashes == current or hashlib.sha256(canonical(hashes)).hexdigest() == before_queue_correction,
            "retained observer/controller contract differs from trusted validator source")


def checked_initial_settling(value, prepared, report):
    require(type(value) is dict and set(value) == {"requestedNS", "startedMonotonicNS", "finishedMonotonicNS"}
            and all(type(part) is int and part > 0 for part in value.values())
            and value["requestedNS"] == INITIAL_SETTLE_NS, "initial paste settling contract differs")
    before = report["clockBefore"]["absoluteTicks"] * report["timebase"]["numer"] // report["timebase"]["denom"]
    require(type(prepared["preparedMonotonicNS"]) is int
            and 0 < prepared["preparedMonotonicNS"] <= value["startedMonotonicNS"]
            and value["finishedMonotonicNS"] - value["startedMonotonicNS"] >= INITIAL_SETTLE_NS
            and value["finishedMonotonicNS"] <= before,
            "initial paste settling is short, precedes preparation, or overlaps observation")


@lru_cache(maxsize=4096)
def expected_classes(token, row):
    return bytes(16 if item == -1 else 17 if item == -2 else item
                 for ordinal in range(row, row + 36) for item in row_symbols(token, ordinal))


@lru_cache(maxsize=4096)
def viewport_digest(token, row):
    return viewport_sha256(token, row)


def geometry(value):
    width, height = value["width"], value["height"]
    require(positive_int(width) and positive_int(height) and width <= 16384 and height <= 16384, "invalid raster dimensions")
    columns, bands = value["columnSamples"], value["rowBands"]
    require(len(columns) == 120 and len(bands) == 36, "raster does not cover 120 codes and 36 rows")
    flat = []
    for points in columns:
        require(len(points) == 3 and all(type(x) is int and 0 <= x < width for x in points)
                and sorted(set(points)) == points, "invalid coded-cell interior samples")
        flat.extend(points)
    require(flat == sorted(set(flat)), "coded columns overlap")
    previous = None
    for band in bands:
        lower, upper = band["lower"], band["upper"]
        require(type(lower) is int and type(upper) is int and 0 <= lower < upper <= height
                and upper - lower >= 4 and (previous is None or previous == lower), "row gap/overlap/partial band")
        previous = upper
    discovery = value["discovery"]
    require(isinstance(discovery, dict) and set(discovery) == {"firstRow", "redLower", "redUpper", "greenLower", "greenUpper", "top", "rowHeight"}
            and all(type(item) is int for item in discovery.values()) and discovery["firstRow"] == INITIAL_ROW,
            "missing native sentinel-discovery preimage")
    red0, red1, green0, green1 = (discovery[key] for key in ("redLower", "redUpper", "greenLower", "greenUpper"))
    require(0 <= red0 < red1 < green0 < green1 <= width and 4 <= red1 - red0 <= 100
            and abs((green1 - green0) - (red1 - red0)) <= 1,
            "native sentinel spans do not describe full-width calibrated cells")
    red_center, green_center = (red0 + red1 - 1) / 2, (green0 + green1 - 1) / 2
    pitch = (green_center - red_center) / (BARCODE_COLUMNS - 1)
    require(pitch >= 4 and abs(pitch - (red1 - red0)) <= 1, "full-width sentinel pitch is invalid")
    reconstructed = []
    for column in range(BARCODE_COLUMNS):
        center = math.floor(red_center + column * pitch + 0.5)  # Swift .rounded(), positive coordinates.
        reconstructed.append([center - 1, center, center + 1])
    require(columns == reconstructed, "calibrated samples do not reconstruct from native sentinel discovery")
    require(discovery["rowHeight"] >= 4 and bands == [{"lower": discovery["top"] + row * discovery["rowHeight"],
            "upper": discovery["top"] + (row + 1) * discovery["rowHeight"]} for row in range(36)],
            "row bands do not reconstruct from native full-grid discovery")
    plain = {key: value[key] for key in ("width", "height", "columnSamples", "rowBands", "discovery")}
    require(hashlib.sha256(canonical(plain)).hexdigest() == value["calibrationSHA256"], "raster calibration hash mismatch")
    return 120 * 3 * sum(band["upper"] - band["lower"] for band in bands)


def checked_chrome_geometry(report, spec):
    """Reconstruct the version2 observer's recorded, raster-bound exception."""
    require(type(report.get("schemaVersion")) is int and report["schemaVersion"] == 2
            and type(report.get("ownedChromeGeometrySchema")) is int
            and report["ownedChromeGeometrySchema"] == 1
            and type(report.get("ownedChromeGeometryLimit")) is int
            and report["ownedChromeGeometryLimit"] == 4096,
            "missing version2 owned-chrome evidence contract")
    records = report.get("ownedChromeGeometry")
    require(isinstance(records, list) and 2 <= len(records) <= 4096,
            "missing or unbounded owned-chrome chronology")
    geometry(report["geometry"])  # A partial raster cannot establish an exception.
    main = window(report["windowBefore"], spec)
    raster_height = report["geometry"]["height"]
    require(report["capture"]["height"] == raster_height, "chrome/raster capture height differs")
    top = main["y"] + float(report["geometry"]["rowBands"][0]["lower"]) * main["height"] / float(raster_height)
    main_right, main_bottom = main["x"] + main["width"], main["y"] + main["height"]
    require(all(math.isfinite(value) for value in (top, main_right, main_bottom))
            and main["y"] < top < main_bottom, "invalid raster-derived chrome boundary")
    before, after = report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"]
    capture_start = report["captureStartTicks"]
    first_query = report["initial"]["stability"]["first"]["windowQueryFinishedTicks"]
    previous = None
    for index, record in enumerate(records):
        require(isinstance(record, dict) and set(record) == {"checkedTicks", "rasterDerivedViewportTop", "windows"},
                "incomplete owned-chrome observation")
        tick, observed_top, chrome = record["checkedTicks"], record["rasterDerivedViewportTop"], record["windows"]
        require(type(tick) is int and before <= tick <= after
                and (previous is None or previous < tick), "owned-chrome clocks reverse/repeat or leave observation")
        require(isinstance(chrome, list) and len(chrome) <= 4096, "invalid owned-chrome window list")
        if index == 0:
            require(observed_top is None and chrome == [] and tick < capture_start,
                    "initial uncalibrated window check must precede capture without an exception")
        else:
            require(type(observed_top) in (int, float) and math.isfinite(observed_top)
                    and observed_top == top and tick >= capture_start,
                    "owned-chrome boundary differs from the fixed complete raster")
            if index == 1:
                require(tick <= first_query, "chrome exception was not bound by the first acknowledged frame query")
        identifiers = set()
        for item in chrome:
            require(isinstance(item, dict) and set(item) == {"windowID", "ownerPID", "layer", "alpha", "onScreen", "bounds"},
                    "incomplete owned-chrome window metadata")
            identifier = item["windowID"]
            require(type(identifier) is int and 0 < identifier <= 0xffffffff
                    and identifier != spec["windowID"] and identifier not in identifiers
                    and type(item["ownerPID"]) is int and item["ownerPID"] == spec["appPID"]
                    and type(item["layer"]) is int and item["onScreen"] is True
                    and type(item["alpha"]) in (int, float) and math.isfinite(item["alpha"])
                    and 0 <= item["alpha"] <= 1, "owned-chrome identity/visibility differs")
            identifiers.add(identifier)
            # CGRect's Codable representation is [[originX, originY], [width, height]].
            bounds = item["bounds"]
            require(isinstance(bounds, list) and len(bounds) == 2
                    and all(isinstance(pair, list) and len(pair) == 2 for pair in bounds),
                    "invalid native CGRect encoding")
            (x, y), (width, height) = bounds
            require(all(type(value) in (int, float) and math.isfinite(value) for value in (x, y, width, height))
                    and width > 0 and height > 0 and math.isfinite(x + width) and math.isfinite(y + height)
                    and main["x"] <= x and main["y"] <= y
                    and x + width <= main_right and y + height <= top,
                    "owned chrome leaves the main rectangle or overlaps the measured viewport")
        previous = tick


def checked_frames(frames, report, spec, required_pixels):
    require(isinstance(frames, list) and 1 <= len(frames) <= 4096, "missing/bounded paste frame chronology")
    before, after = report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"]
    by_display = {}
    for frame in frames:
        require(all(positive_int(frame[key]) and frame[key] < 2**64
                    for key in ("callbackTicks", "windowQueryFinishedTicks", "displayTicks"))
                and before <= frame["callbackTicks"] <= frame["windowQueryFinishedTicks"] <= after
                and before < frame["displayTicks"] <= after, "frame clock leaves observation")
        require(window(frame["window"], spec) == report["windowBefore"], "per-frame owned window differs")
        encoded = frame.get("observedCellClasses")
        decoded_row = None
        if encoded is not None:
            require(isinstance(encoded, str) and len(encoded) == 5760, "missing/bounded 120 by 36 observed cell classes")
            try:
                observed = base64.b64decode(encoded, validate=True)
            except (ValueError, binascii.Error) as error:
                raise ValueError("invalid observed color class encoding") from error
            require(len(observed) == 4320 and all(value <= 17 or value in (254, 255) for value in observed),
                    "unknown or incomplete observed color classes")
            digits = observed[33:37]
            if all(value < 16 for value in digits):
                candidate = sum(value << (4 * (3 - index)) for index, value in enumerate(digits))
                if candidate <= 964 and observed == expected_classes(spec["token"], candidate):
                    decoded_row = candidate
        # Actual classes independently determine whether this whole viewport
        # matched. An expected hash or producer Boolean alone cannot admit it.
        require(frame.get("firstRow") == decoded_row, "producer row differs from observed full-width pixel classes")
        if decoded_row is None:
            require(frame["checkedPixels"] == 0 and frame.get("canonicalRowsSHA256") is None,
                    "partial/unknown raster claimed as complete")
        else:
            require(type(frame["firstRow"]) is int and frame["checkedPixels"] == required_pixels
                    and frame["canonicalRowsSHA256"] == viewport_digest(spec["token"], decoded_row),
                    "complete response count/hash differs from actual pixels")
        value = (decoded_row, encoded)
        require(frame["displayTicks"] not in by_display or by_display[frame["displayTicks"]] == value,
                "conflicting duplicate WindowServer timestamp")
        by_display[frame["displayTicks"]] = value
    return sorted(frames, key=lambda item: item["displayTicks"])


def checked_stability(group, report, spec, required_pixels, target):
    require(group["status"] == "valid" and group["targetFirstRow"] == target, "wrong full response target")
    ordered = checked_frames(group["frames"], report, spec, required_pixels)
    stable, boundary = group["stability"], group["afterTicks"]
    first = stable["first"]
    targets = [frame for frame in ordered if frame.get("firstRow") == target]
    require(targets and first in ordered and first == targets[0], "first full response moved or missing from raw frames")
    require(positive_int(boundary) and all(frame["displayTicks"] > boundary for frame in ordered),
            "pre-dispatch frame entered paste acknowledgement")
    later = [frame for frame in ordered if frame["displayTicks"] > first["displayTicks"]]
    require(all(frame.get("firstRow") == target for frame in later), "viewport regressed after first response")
    require(stable["laterCorrectDistinctFrames"] == len({frame["displayTicks"] for frame in later}),
            "later-frame count differs; idle cannot create complete frames")
    start, finish = max(first["displayTicks"], first["callbackTicks"]), stable["validationFinishedTicks"]
    require(stable["guardStartedTicks"] == start and type(finish) is int and start <= finish <= report["clockAfter"]["absoluteTicks"]
            and (finish - start) * report["timebase"]["numer"] >= GUARD_NS * report["timebase"]["denom"],
            "response observation guard is short or clock-invalid")
    require(all(frame["windowQueryFinishedTicks"] <= finish for frame in ordered), "frame validation follows guard finish")
    return first


def checked_capture_statuses(report, groups):
    records = report["captureStatuses"]
    require(report["captureStatusSchema"] == 1 and report["captureStatusLimit"] == 65536
            and isinstance(records, list) and len(groups) <= len(records) <= 65536,
            "missing/bounded native capture status chronology")
    before, after = report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"]
    previous, complete = before, set()
    for item in records:
        tick, display, status = item["callbackTicks"], item.get("displayTicks"), item.get("statusRaw")
        require(type(tick) is int and previous <= tick <= after
                and type(item["sampleIsValid"]) is bool and type(item["hasImageBuffer"]) is bool
                and (status is None or type(status) is int and 0 <= status <= 5)
                and (display is None or type(display) is int and 0 <= display < 2**64)
                and type(item["generation"]) is int and 1 <= item["generation"] <= len(groups)
                and item["armedAfterTicks"] == groups[item["generation"] - 1]["afterTicks"] <= tick,
                "invalid native capture status/generation/arming proof")
        previous = tick
        if status == 0 and item["sampleIsValid"] and item["hasImageBuffer"]:
            complete.add((tick, display, item["generation"]))
    for generation, group in enumerate(groups, 1):
        first = group["stability"]["first"]
        end = group["stability"]["validationFinishedTicks"]
        frame_keys = {(frame["callbackTicks"], frame["displayTicks"], generation) for frame in group["frames"]}
        require(frame_keys <= complete, "frame has no complete native capture status")
        for item in records:
            display, callback = item.get("displayTicks"), item["callbackTicks"]
            times = [callback] + ([display] if type(display) is int and display > 0 else [])
            if item.get("statusRaw") not in (0, 1) or not item["sampleIsValid"]:
                require(not any(first["displayTicks"] <= tick <= end for tick in times),
                        "blank/suspended/restarted/stopped/invalid capture inside response guard")
            if item["generation"] == generation and item.get("statusRaw") == 0 and type(display) is int:
                relevant = display > group["afterTicks"] and (callback <= end or display <= end)
                if relevant:
                    require(item["hasImageBuffer"] and (callback, display, generation) in frame_keys,
                            "complete status inside guard has no retained pixel-derived frame")


def terminal_query(value, report, spec, terminal_id=None):
    require(value["eventClass"] == fourcc("core") and value["eventID"] == fourcc("getd")
            and value["targetPID"] == spec["appPID"] and value["sendOptions"] == SEND_OPTIONS
            and value["terminalCount"] == 1 and isinstance(value["terminalID"], str)
            and 0 < len(value["terminalID"].encode()) <= 512
            and not any(ord(char) < 32 or ord(char) == 127 for char in value["terminalID"]),
            "public sole-terminal query contract differs")
    require(positive_int(value["startedTicks"]) and type(value["finishedTicks"]) is int
            and report["clockBefore"]["absoluteTicks"] <= value["startedTicks"] <= value["finishedTicks"]
            <= report["clockAfter"]["absoluteTicks"], "terminal query clocks leave observation")
    require(terminal_id is None or terminal_id == value["terminalID"], "stable public terminal ID changed")
    return value["terminalID"]


def checked_permissions(report, spec, groups):
    records = report["permissions"]
    # Initial discovery and each of the 43 actual input commands preflight both
    # public event kinds. A missing grant never permits a prompt or raw fallback.
    require(isinstance(records, list) and len(records) == 2 * (1 + len(groups)), "missing no-prompt permission preflights")
    previous = report["clockBefore"]["absoluteTicks"]
    for index, item in enumerate(records):
        expected = (fourcc("core"), fourcc("getd")) if index % 2 == 0 else (fourcc("Ghst"), fourcc("InTx"))
        require((item["eventClass"], item["eventID"]) == expected and item["targetPID"] == spec["appPID"]
                and item["askUserIfNeeded"] is False and type(item["status"]) is int and item["status"] == 0
                and type(item["startedTicks"]) is int and type(item["finishedTicks"]) is int
                and previous <= item["startedTicks"] <= item["finishedTicks"] <= report["clockAfter"]["absoluteTicks"],
                "authorization was missing, prompted, or incorrectly timed")
        previous = item["finishedTicks"]
        query = report["terminalQueryBefore"] if index < 2 else groups[(index - 2) // 2]["terminalQueryBefore"]
        require(item["finishedTicks"] <= query["startedTicks"], "query/dispatch occurred before permission preflight")


def checked_sample(value, report, spec, required_pixels, sequence, previous_end, terminal_id):
    wanted = expected_receipt(spec["token"], sequence)
    require(type(value["sequence"]) is int and value["sequence"] == sequence and value["bracketed"] is (sequence != 0)
            and value["payloadBytes"] == wanted["payloadBytes"] and value["payloadSHA256"] == wanted["payloadSHA256"],
            "paste work/payload sequence differs")
    event = value["event"]
    require(event["eventClass"] == fourcc("Ghst") and event["eventID"] == fourcc("InTx")
            and event["targetKeyword"] == fourcc("GItT") and event["terminalClass"] == fourcc("Gtrm")
            and event["addressDescriptorType"] == fourcc("kpid") and event["keyForm"] == fourcc("ID  ")
            and event["terminalID"] == terminal_id and event["targetPID"] == spec["appPID"]
            and event["sendOptions"] == SEND_OPTIONS and event["replyErrorNumber"] == 0,
            "public PID-addressed unique-ID paste command differs")
    for phase in ("Before", "After"):
        tty(value["tty" + phase], spec, report["appIdentity"], report["workerIdentity"])
        fixture_probe(value["fixture" + phase])
        require(window(value["window" + phase], spec) == report["windowBefore"], "paste window changed")
        terminal_query(value["terminalQuery" + phase], report, spec, terminal_id)
    arm, before, after = value["armControl"], value["fixtureBefore"], value["fixtureAfter"]
    for probe in (arm, before, after):
        fixture_probe(probe)
    require(arm["armedSequence"] == sequence and arm["receivedBytes"] == 0
            and before["armedSequence"] is None and before["receivedBytes"] == 0
            and after["armedSequence"] is None and after["receivedBytes"] == 0
            and before["acceptedPastes"] == max(0, sequence - 1)
            and after["acceptedPastes"] == sequence and after["offProbeVerified"] is True
            and all(probe["bracketModeEnabled"] is (sequence != 0) for probe in (arm, before, after)),
            "receiver did not prove exact off/on wire acceptance")
    first = checked_stability(value, report, spec, required_pixels, response_first_row(sequence))
    require(value["afterTicks"] == event["eventBeforeTicks"]
            and previous_end <= value["ttyBefore"]["startedTicks"] <= value["ttyBefore"]["finishedTicks"]
            <= value["terminalQueryBefore"]["startedTicks"] <= value["terminalQueryBefore"]["finishedTicks"]
            <= event["eventBeforeTicks"] <= event["eventAfterTicks"] <= value["stability"]["validationFinishedTicks"]
            <= value["ttyAfter"]["startedTicks"] <= value["ttyAfter"]["finishedTicks"]
            <= value["terminalQueryAfter"]["startedTicks"], "paste dispatch/guard/ownership checks overlap or reverse")
    return validate_frame_clock(event["eventBeforeTicks"], event["eventAfterTicks"], first["displayTicks"],
        first["callbackTicks"], first["windowQueryFinishedTicks"], value["stability"]["validationFinishedTicks"],
        report["timebase"]["numer"], report["timebase"]["denom"])["eventToCompleteViewportMS"]


def checked_worker(directory, metadata, spec, run):
    fixture = directory / "fixture"
    ready, prepared, final = (read(fixture / name) for name in ("ready.json", "prepared.json", "final.json"))
    require(ready["status"] == "ready" and prepared["status"] == "prepared" and final["status"] == "stopped",
            "incomplete worker lifecycle")
    for record in (ready, prepared, final):
        require(record["schemaVersion"] == 1 and record["benchmarkKind"] == "paste"
                and record["pid"] == spec["workerPID"] and record["token"] == spec["token"]
                and record["ttyPath"] == spec["ttyPath"] and record["unexpectedInputBytes"] == 0,
                "worker identity/input silence differs")
        require(set(record["sourceSHA256"]) == {"paste_worker.py", "paste_protocol.py", "scroll_protocol.py", "terminal_bench_worker.py"}
                and all(metadata["toolingSHA256"].get(name) == expected for name, expected in record["sourceSHA256"].items()),
                "executed worker/protocol module hashes differ")
    generated = preparation(spec["token"])
    require(run["preparedSHA256"] == digest(fixture / "prepared.json")
            and prepared["payloadBytes"] == len(generated)
            and prepared["payloadSHA256"] == hashlib.sha256(generated).hexdigest()
            and prepared["dsrQueryHex"] == b"\x1b[36;1H\x1b[6n".hex()
            and prepared["dsrReplyHex"] == b"\x1b[36;1R".hex(), "generated setup/DSR proof differs")
    require(not (ready["ttyFlagsRaw"][1] & termios.OPOST) and ready["receipts"] == prepared["receipts"] == []
            and ready["acceptedPastes"] == prepared["acceptedPastes"] == 0
            and prepared["offProbeVerified"] is False and prepared["bracketModeEnabled"] is False,
            "worker did not begin raw with bracket mode disabled")
    require(final["acceptedPastes"] == WARMUPS + SAMPLES and final["offProbeVerified"] is True
            and final["bracketModeEnabled"] is True and final["incompleteSequence"] is None and final["incompleteBytes"] == 0
            and len(final["receipts"]) == 1 + WARMUPS + SAMPLES, "missing/excess/incomplete paste receipts")
    previous = prepared["preparedMonotonicNS"]
    for sequence, item in enumerate(final["receipts"]):
        wanted = expected_receipt(spec["token"], sequence)
        require(all(item.get(key) == value and type(item.get(key)) is type(value) for key, value in wanted.items()),
                "exact Unicode body/bracket/response bytes differ")
        require(read(fixture / f"receipt-{sequence:02d}.json") == item, "retained individual paste receipt differs")
        require([item["grid"]["columns"], item["grid"]["rows"]] == list(GRID), "paste receipt native grid differs")
        times = [item[key] for key in ("receiveStartedMonotonicNS", "verifiedMonotonicNS", "emitStartedMonotonicNS", "emitFinishedMonotonicNS")]
        require(all(positive_int(value) for value in times) and previous <= times[0] <= times[1] <= times[2] <= times[3]
                <= final["finishedMonotonicNS"], "worker wrote a response before exact wire verification")
        previous = times[-1]
    actual_files = {path.name for path in fixture.glob("receipt-*.json")}
    require(actual_files == {f"receipt-{index:02d}.json" for index in range(43)}, "missing/extra worker receipts")
    require(all([item["columns"], item["rows"]] == list(GRID) for item in final["gridChecks"])
            and [final["gridAfter"]["columns"], final["gridAfter"]["rows"]] == list(GRID), "worker grid changed")
    stopped, cleanup = read(directory / "fixture-stop.json"), read(directory / "cleanup.json")
    require(stopped["complete"] is True and stopped["workerExited"] is True
            and stopped["finalSHA256"] == digest(fixture / "final.json")
            and final["stopReason"] == "control-finish" and final["terminalModeRestored"] is True
            and final["fileFlagsRestored"] is True and final["modeDifferenceIndices"] == []
            and final["ttyFlagsRestored"] == final["ttyFlagsOriginal"], "fixture cleanup/restoration incomplete")
    require(type(cleanup["returncode"]) is int and cleanup["appPID"] == spec["appPID"]
            and not cleanup.get("forcedKill"), "owned application cleanup incomplete/forced")


def checked_report(directory, metadata, terminal):
    spec, report, run, launch = (read(directory / name) for name in ("observer-spec.json", "observation.json", "run.json", "launch.json"))
    require(run["status"] == "valid" and run["terminal"] == terminal and run["observerReturncode"] == 0
            and run["observationSHA256"] == digest(directory / "observation.json")
            and not any(run.get(name) for name in ("error", "cleanupError", "conditionError")), "invalid/incomplete owned paste run")
    start, finish = datetime.fromisoformat(run["startedUTC"]), datetime.fromisoformat(run["finishedUTC"])
    require(start.tzinfo is not None and finish.tzinfo is not None
            and datetime.fromisoformat(metadata["startedUTC"]) <= start < finish <= datetime.fromisoformat(metadata["finishedUTC"])
            and start.timestamp() * 1e9 <= report["clockBefore"]["wallNS"] < report["clockAfter"]["wallNS"] <= finish.timestamp() * 1e9,
            "raw run/native clocks leave batch audit interval")
    require(report["schemaVersion"] == 2 and report["benchmarkKind"] == "paste" and report["status"] == "valid"
            and report["metric"] == metadata["metric"] == METRIC and report["grid"] == list(GRID)
            and report["barcodeColumns"] == BARCODE_COLUMNS and report["postMatchGuardNS"] == GUARD_NS
            and report["specSHA256"] == digest(directory / "observer-spec.json")
            and report["ownershipFailures"] == [], "observer contract/ownership failed")
    require(spec["appPID"] == launch["appPID"] == report["appIdentity"]["pid"]
            and spec["workerPID"] == launch["workerPID"] == report["workerIdentity"]["pid"]
            and report["appIdentity"]["uid"] == report["workerIdentity"]["uid"]
            and report["appIdentity"]["executable"] == spec["executable"] == metadata["binaries"][terminal]["path"]
            and spec["executableSHA256"] == report["executableSHA256"] == metadata["binaries"][terminal]["sha256"]
            and report["controllerPID"] == metadata["controllerPID"] == report["appIdentity"]["parentPID"],
            "owned process/controller/binary binding differs")
    validate_kernel_ancestry(report["initialAncestry"], report["appIdentity"], report["workerIdentity"])
    require(report["initialAncestry"]["finishedTicks"] <= report["clockBefore"]["absoluteTicks"], "late initial ancestry proof")
    require(spec["token"] == report["token"] == run["token"] and spec["displayID"] == metadata["displayID"]
            and spec["requestedFPS"] == 120 and 1 <= spec["timeoutSeconds"] <= 10
            and launch["terminal"] == terminal and launch["profile"] == metadata["profile"]
            and "CMDY_FRAME_TRACE" not in launch["environment"], "fixture/profile/display/trace binding differs")
    validate_launch(directory, metadata, launch, spec)
    require(run["configBeforeLaunchSHA256"] == digest(directory / "config-before-launch.json"), "launch configuration receipt changed")
    options = BenchOptions(Path(metadata["binaries"]["cmdy"]["path"]), Path(metadata["binaries"]["ghostty"]["path"]), profile=metadata["profile"])
    config = directory / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
    require(config.read_text() == config_text(terminal, options, Path(launch["cwd"]))
            and digest(config) == launch["configSHA256"]
            and run["canonicalConfigSHA256"] == hashlib.sha256(config_text(terminal, options, Path("<isolated-cwd>")).encode()).hexdigest(),
            "isolated config bytes/hash differ")
    require(window(report["windowBefore"], spec) == window(report["windowAfter"], spec)
            and report["windowBefore"]["processStartSeconds"] == report["appIdentity"]["startSeconds"]
            and report["windowBefore"]["processStartMicroseconds"] == report["appIdentity"]["startMicroseconds"], "window/process-start changed")
    for phase in ("before", "after"):
        require(power(run["power" + phase.title()]) == power(metadata["powerBefore"])
                and native_condition_signature(run["native" + phase.title()]) == native_condition_signature(metadata["nativeBefore"]),
                "per-run power/native conditions changed")
        checked_window_helper(read(directory / f"window-{phase}.json"), spec, report["windowBefore"])
        actual = read(directory / f"grid-{phase}.json")
        require([actual["columns"], actual["rows"]] == list(GRID), "actual native grid differs")
        tty(report["tty" + phase.title()], spec, report["appIdentity"], report["workerIdentity"])
        fixture_probe(report["fixture" + phase.title()])
    environment = {key: metadata["nativeBefore"][key] for key in ("lowPowerMode", "thermalState", "os")}
    require(report["environmentBefore"] == report["environmentAfter"] == environment, "observer conditions differ")
    clock_interval(report)
    require(run.get("preCaptureSettlingSHA256") == digest(directory / "pre-capture-settling.json"),
            "initial paste settling receipt missing or changed")
    checked_initial_settling(read(directory / "pre-capture-settling.json"),
                             read(directory / "fixture/prepared.json"), report)
    required_pixels = geometry(report["geometry"])
    capture = report["capture"]
    require(capture["kind"] == "owned-window" and capture["requestedFPS"] == 120 and capture["queueDepth"] == 8
            and capture["width"] == report["geometry"]["width"] and capture["height"] == report["geometry"]["height"]
            and capture["colorSpace"] == "sRGB" and capture["pixelFormat"] == "BGRA"
            and capture["ignoreShadowsSingleWindow"] is True and type(capture["pointPixelScale"]) in (int, float)
            and 1 <= capture["pointPixelScale"] <= 4
            and capture["width"] == round(report["windowBefore"]["width"] * capture["pointPixelScale"])
            and capture["height"] == round(report["windowBefore"]["height"] * capture["pointPixelScale"]),
            "capture changed native resolution/color/ownership contract")
    checked_chrome_geometry(report, spec)
    terminal_id = terminal_query(report["terminalQueryBefore"], report, spec)
    terminal_query(report["terminalQueryAfter"], report, spec, terminal_id)
    require(len(report["warmups"]) == WARMUPS and len(report["samples"]) == SAMPLES, "missing/excess paste samples")
    actions = [report["offProbe"], *report["warmups"], *report["samples"]]
    checked_permissions(report, spec, actions)
    groups = [report["initial"], report["offProbe"], report["enabledViewport"], *report["warmups"], *report["samples"]]
    checked_capture_statuses(report, groups)
    checked_stability(report["initial"], report, spec, required_pixels, INITIAL_ROW)
    require(report["initial"]["afterTicks"] == report["captureStartTicks"]
            and report["terminalQueryBefore"]["finishedTicks"] <= report["captureStartTicks"], "initial observation predates public target discovery")
    checked_sample(report["offProbe"], report, spec, required_pixels, 0,
                   report["initial"]["stability"]["validationFinishedTicks"], terminal_id)
    enabled = report["enableBracketed"]
    fixture_probe(enabled["control"])
    require(enabled["control"]["bracketModeEnabled"] is True and enabled["control"]["offProbeVerified"] is True
            and enabled["control"]["acceptedPastes"] == 0 and enabled["control"]["armedSequence"] is None
            and report["offProbe"]["terminalQueryAfter"]["finishedTicks"] <= enabled["startedTicks"] <= enabled["finishedTicks"]
            <= report["enabledViewport"]["stability"]["validationFinishedTicks"]
            and report["enabledViewport"]["afterTicks"] == enabled["startedTicks"], "bracket mode enable did not follow off-mode proof")
    checked_stability(report["enabledViewport"], report, spec, required_pixels, ENABLED_ROW)
    values, previous = [], report["enabledViewport"]["stability"]["validationFinishedTicks"]
    for sequence, item in enumerate(report["warmups"] + report["samples"], 1):
        require(item["warmup"] is (sequence <= WARMUPS), "warmup classification changed")
        elapsed = checked_sample(item, report, spec, required_pixels, sequence, previous, terminal_id)
        if sequence > WARMUPS:
            values.append(elapsed)
        previous = item["terminalQueryAfter"]["finishedTicks"]
    require(previous <= report["ttyAfter"]["startedTicks"]
            and report["fixtureAfter"]["acceptedPastes"] == WARMUPS + SAMPLES
            and report["fixtureAfter"]["offProbeVerified"] is True, "post-run worker/ownership proof incomplete")
    checked_worker(directory, metadata, spec, run)
    return values, report, spec, launch


def checked_manifest(directory, expected_binaries, pilot_only, manifest_name="manifest.json"):
    metadata = read(directory / manifest_name)
    require(metadata["schemaVersion"] == 1 and metadata["benchmarkKind"] == "paste"
            and metadata["state"] == ("pilot-complete-unpooled" if pilot_only else "complete")
            and metadata["diagnostic"] is False and metadata["pilotOnly"] is pilot_only and not metadata.get("error"),
            "incomplete/diagnostic/pilot-only paste evidence cannot satisfy parity")
    require(metadata["metric"] == METRIC and metadata["requestedBlocks"] == BLOCKS
            and metadata["samplesPerBlock"] == SAMPLES and metadata["warmupsPerBlock"] == WARMUPS
            and metadata["grid"] == list(GRID) and metadata["profile"] in ("matched", "cmdy-defaults")
            and metadata["first"] in ("cmdy", "ghostty"), "paste case/profile/count contract differs")
    binaries = {name: metadata["binaries"][name]["sha256"] for name in ("cmdy", "ghostty")}
    require(all(isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value) for value in binaries.values())
            and (expected_binaries is None or binaries == expected_binaries), "pinned app binaries differ")
    runtime = metadata["runtime"]
    require(runtime["workerPythonFlags"] == ["-S"] and runtime["pythonVersion"]
            and all(re.fullmatch("[0-9a-f]{64}", runtime[key]["sha256"]) for key in ("python", "shell")),
            "worker/shell runtime identity missing")
    from paste_bench import FROZEN_EXTRAS, SOURCES, validate_observer_build
    require(set(metadata["toolingSHA256"]) == set(SOURCES) | FROZEN_EXTRAS
            and read(directory / "tooling-freeze.json") == metadata["toolingSHA256"], "tooling identity incomplete")
    for name, expected in metadata["toolingSHA256"].items():
        require(Path(name).name == name and digest(directory / "tooling" / name) == expected, "frozen tooling changed")
    # Validate with the trusted current code, never import/execute evidence code.
    checked_tooling_sources({name: metadata["toolingSHA256"][name] for name in SOURCES})
    validate_observer_build(read(directory / "tooling/observer-build.json"),
                            read(directory / "tooling/observer-qualification.json"), metadata["toolingSHA256"])
    for name in ("cmdy", "ghostty"):
        published = validate_sdef((directory / "tooling" / (name + ".sdef")).read_bytes())
        require(all(metadata["dictionaries"][name].get(key) == value for key, value in published.items()),
                "public scripting dictionary changed")
    require(metadata["sourceBefore"] == metadata["sourceAfter"] and metadata["sourceBefore"]["status"] == "valid"
            and metadata["sourceBefore"]["manifestSHA256"] == digest(directory / "app-source-manifest.json"), "app source audit changed/missing")
    source = read(directory / "app-source-manifest.json")
    require(len(source["sources"]) == metadata["sourceBefore"]["sourceCount"]
            and source["sources"].get("App/Resources/Cmdy.sdef") == metadata["dictionaries"]["cmdy"]["sha256"],
            "app source audit does not bind its installed public scripting definition")
    require(power(metadata["powerBefore"]) == power(metadata["powerAfter"])
            and native_condition_signature(metadata["nativeBefore"]) == native_condition_signature(metadata["nativeAfter"]),
            "batch power/native conditions changed")
    machine = metadata["machine"]
    require(machine["font"]["postScriptName"] == "Menlo-Regular" and machine["font"]["sizePoints"] == 14
            and re.fullmatch("[0-9a-f]{64}", metadata["fontSHA256"])
            and all(machine[key] == metadata["machineAfter"][key] for key in ("font", "displays")), "font/display identity changed")
    require(isinstance(metadata.get("hardware", {}).get("stdout"), str) and metadata["hardware"]["stdout"], "missing hardware identity")
    return metadata, binaries


def checked_pilots(directory, metadata):
    require(set(metadata["pilots"]) == {"cmdy", "ghostty"}, "missing paired public-transport/full-frame pilot")
    chronology, tokens, domains = [], set(), set()
    for name in ("cmdy", "ghostty"):
        value = metadata["pilots"][name]
        require(value["path"] == f"pilot/{name}", "pilot path differs")
        folder = directory / value["path"]
        require(value["runSHA256"] == digest(folder / "run.json")
                and value["observationSHA256"] == digest(folder / "observation.json"), "pilot raw receipt changed")
        _, report, spec, launch = checked_report(folder, metadata, name)
        require(spec["token"] == value["token"], "pilot payload differs")
        require(launch["defaultsDomain"] not in domains, "pilot defaults domain reused")
        domains.add(launch["defaultsDomain"]); tokens.add(spec["token"])
        chronology.append((launch["startedMonotonicNS"], report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"], name))
    require(len(tokens) == 1 and sorted(chronology)[0][3] == metadata["first"], "pilot order/payload differs")
    require(sorted(path.name for path in (directory / "pilot").iterdir() if path.is_dir()) == ["cmdy", "ghostty"],
            "missing/extra pilot directories")
    return chronology, tokens, domains


def _load(directory, expected_binaries, pilot_only):
    directory = Path(directory)
    metadata, binaries = checked_manifest(directory, expected_binaries, pilot_only)
    chronology, pilot_tokens, domains = checked_pilots(directory, metadata)
    if pilot_only:
        require(metadata["runs"] == [] and not (directory / "runs").exists(), "unpooled pilot contains measured blocks")
        require(sorted(chronology)[1][1] > sorted(chronology)[0][2], "pilot observations overlapped")
        return {"path": str(directory), "status": "valid-unpooled-paired-pilot", "case": CASE,
                "binaries": binaries, "profile": metadata["profile"], "parityEligible": False}
    checkpoint = validate_pilot_checkpoint_evidence(directory, expected_binaries)
    require(metadata["pilotCheckpointSHA256"] == digest(directory / "pilot-checkpoint.json")
            and metadata["pilotAdmissionSHA256"] == digest(directory / "pilot-admission.json")
            and read(directory / "pilot-admission.json") == checkpoint,
            "paired pilot was not independently admitted before measured blocks")
    pilot_metadata = read(directory / "pilot-checkpoint.json")
    require(all(pilot_metadata[key] == metadata[key] for key in
                ("profile", "first", "pilots", "binaries", "dictionaries", "toolingSHA256", "sourceBefore", "powerBefore", "nativeBefore", "machine")),
            "measured batch differs from independently qualified pilot inputs")
    require(len(metadata["runs"]) == BLOCKS * 2, "missing paired paste block records")
    require(sorted(path.name for path in (directory / "runs").iterdir() if path.is_dir())
            == sorted(f"{block:02d}-{name}" for block in range(BLOCKS) for name in ("cmdy", "ghostty")),
            "missing/extra measured run directories")
    blocks, orders, tokens = {}, {}, {}
    for item in metadata["runs"]:
        block, name = item["block"], item["terminal"]
        require(type(block) is int and 0 <= block < BLOCKS and name in binaries
                and item["path"] == f"runs/{block:02d}-{name}", "unsafe/incorrect paste run index")
        folder = directory / item["path"]
        require(item["runSHA256"] == digest(folder / "run.json")
                and item["observationSHA256"] == digest(folder / "observation.json"), "raw run receipt changed")
        values, report, spec, launch = checked_report(folder, metadata, name)
        require(name not in blocks.setdefault(block, {}), "duplicate app/block")
        require(launch["defaultsDomain"] not in domains, "defaults domain reused across isolated runs")
        require(item["token"] == spec["token"] and spec["token"] not in pilot_tokens, "pilot nonce reused or pair payload differs")
        domains.add(launch["defaultsDomain"])
        blocks[block][name] = values
        orders.setdefault(block, []).append((launch["startedMonotonicNS"], name))
        tokens.setdefault(block, set()).add(spec["token"])
        chronology.append((launch["startedMonotonicNS"], report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"], name))
    require(sorted(blocks) == list(range(BLOCKS)) and all(set(pair) == {"cmdy", "ghostty"} for pair in blocks.values()), "unpaired paste blocks")
    firsts = [sorted(orders[block])[0][1] for block in range(BLOCKS)]
    require(firsts.count("cmdy") == firsts.count("ghostty") == BLOCKS // 2 and firsts[0] == metadata["first"]
            and all(firsts[index] != firsts[index - 1] for index in range(1, BLOCKS)), "paste order is not counterbalanced")
    chronology.sort()
    require(len({item[0] for item in chronology}) == len(chronology)
            and all(chronology[index][1] > chronology[index - 1][2] for index in range(1, len(chronology))),
            "owned observations overlap or native clocks reverse")
    require(all(len(value) == 1 for value in tokens.values()) and len(set.union(*tokens.values())) == BLOCKS,
            "apps did not receive identical per-pair payloads or reused a nonce")
    machine = metadata["machine"]
    return {"path": str(directory), "case": CASE, "kind": "input", "metric": METRIC,
            "profile": metadata["profile"], "power": power(metadata["powerBefore"]), "binaries": binaries,
            "grid": list(GRID), "blocks": blocks, "display": metadata["displayID"], "font": machine["font"],
            "fontSHA256": metadata["fontSHA256"], "displays": machine["displays"],
            "observerEnvironment": {key: metadata["nativeBefore"][key] for key in ("lowPowerMode", "thermalState", "os")},
            "hardware": metadata["hardware"]["stdout"], "pasteProtocol": {"payloadBytes": PAYLOAD_BYTES,
                "transport": "public-pid-apple-event-input-text", "fullWidthCells": 4320,
                "samplesPerBlock": SAMPLES, "postMatchGuardNS": GUARD_NS}}


def load_paste_evidence(directory, expected_binaries=None):
    """Return only independently validated native timing samples for parity."""
    try:
        return _load(directory, expected_binaries, False)
    except (KeyError, TypeError, IndexError, AttributeError, OSError) as error:
        raise ValueError("incomplete or malformed paste evidence") from error


def validate_pilot_evidence(directory, expected_binaries=None):
    """Validate public transport/full-frame pilot while explicitly excluding it."""
    try:
        return _load(directory, expected_binaries, True)
    except (KeyError, TypeError, IndexError, AttributeError, OSError) as error:
        raise ValueError("incomplete or malformed paste pilot") from error


def validate_pilot_checkpoint_evidence(directory, expected_binaries=None):
    """Read the finalized unpooled pilot checkpoint before any measured launch."""
    directory = Path(directory)
    try:
        metadata, binaries = checked_manifest(directory, expected_binaries, True, "pilot-checkpoint.json")
        chronology, _, _ = checked_pilots(directory, metadata)
        require(metadata["runs"] == [] and sorted(chronology)[1][1] > sorted(chronology)[0][2],
                "pilot checkpoint is pooled or overlapping")
        return {"status": "valid-unpooled-paired-pilot", "case": CASE, "parityEligible": False,
                "binaries": binaries, "profile": metadata["profile"],
                "checkpointSHA256": digest(directory / "pilot-checkpoint.json"),
                "validatorSHA256": metadata["toolingSHA256"]["paste_parity_evidence.py"],
                "pilots": metadata["pilots"]}
    except (KeyError, TypeError, IndexError, AttributeError, OSError) as error:
        raise ValueError("incomplete or malformed paired paste pilot checkpoint") from error
