#!/usr/bin/env python3
"""Read-only raw scroll evidence adapter. The parent parity gate owns policy.

No native calls, process launches, output writes, percentile selection, or
threshold changes. Missing/diagnostic/calibration-only/partial records fail.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from bench_ancestry import validate_kernel_ancestry
import re
import termios
from functools import lru_cache
from datetime import datetime

from competitive_bench import BenchOptions, native_condition_signature
from scroll_protocol import (BLOCKS, GRID, SAMPLES, STABILITY_NS, WheelCalibration,
    payload, sample_plan, validate_frame_clock, validate_paired_calibration, viewport_sha256)
from scroll_contract import validate_launch

viewport_digest = lru_cache(maxsize=4096)(viewport_sha256)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def positive_int(value):
    return type(value) is int and value > 0


def power(value):
    result = value.get("signature", {})
    require(result.get("source") in ("AC Power", "Battery Power") and isinstance(result.get("settings"), str)
            and result["settings"], "missing power source/settings")
    return result


def geometry(value):
    width, height = value["width"], value["height"]
    require(positive_int(width) and positive_int(height) and width <= 16384 and height <= 16384, "invalid raster dimensions")
    columns, bands = value["columnSamples"], value["rowBands"]
    require(len(columns) == 42 and len(bands) == 36, "raster does not cover 42 codes and 36 rows")
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
    plain = {key: value[key] for key in ("width", "height", "columnSamples", "rowBands")}
    require(hashlib.sha256(canonical(plain)).hexdigest() == value["calibrationSHA256"], "raster calibration hash mismatch")
    return 42 * 3 * sum(band["upper"] - band["lower"] for band in bands)


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


def tty(value, spec, app, worker):
    require(value.get("status") == "valid" and value.get("workerPID") == spec["workerPID"]
            and value.get("appPID") == spec["appPID"] and value.get("ttyPath") == spec["ttyPath"]
            and value.get("processIdentityValid") is True and value.get("workerIsDescendant") is True
            and value.get("columns") == 120 and value.get("rows") == 36, "invalid per-event owned TTY/grid")
    require(value.get("openResult") == 0 and value.get("windowSizeResult") == 0
            and value.get("fstatResult") == 0 and value.get("openedDeviceIsCharacter") is True
            and positive_int(value.get("processInfoExpectedBytes"))
            and value.get("processInfoResult") == value["processInfoExpectedBytes"]
            and value.get("workerUID") == value.get("observerUID")
            and positive_int(value.get("workerProcessGroupID"))
            and value.get("workerForegroundProcessGroupID") == value["workerProcessGroupID"]
            and value.get("workerControllingDeviceID") == value.get("openedDeviceID"), "TTY device/foreground proof missing")
    require(positive_int(value.get("startedTicks")) and value.get("finishedTicks", 0) >= value["startedTicks"], "TTY diagnostic clock invalid")
    validate_kernel_ancestry(value["ancestry"], app, worker)
    require(value["startedTicks"] <= value["ancestry"]["startedTicks"]
        <= value["ancestry"]["finishedTicks"] <= value["finishedTicks"], "TTY ancestry observation clock invalid")
    # External tcgetpgrp is retained as a diagnostic. ENOTTY is expected when
    # the observer has deliberately not acquired the worker's controlling TTY.
    require(type(value.get("externalTCGetPGRP")) is int and type(value.get("externalTCGetPGRPErrno")) is int,
            "missing actual external TTY diagnostic")


def fixture_probe(value):
    require(value.get("ok") is True and value.get("status") == "prepared"
            and value.get("unexpectedInputBytes") == 0
            and [value["grid"]["columns"], value["grid"]["rows"]] == list(GRID), "fixture was noisy/unprepared or resized")


def window(value, spec):
    require(value["appPID"] == spec["appPID"] == value["frontmostPID"]
            and value["windowID"] == spec["windowID"] and value["displayID"] == spec["displayID"]
            and positive_int(value["processStartSeconds"]) and type(value["processStartMicroseconds"]) is int,
            "owned PID/window/focus/display/start identity differs")
    require(all(type(value[key]) in (int, float) and math.isfinite(value[key]) for key in ("x", "y", "width", "height"))
            and value["width"] > 100 and value["height"] > 100, "invalid window bounds")
    return value


def checked_window_helper(value, spec, native_window):
    require(value.get("ok") is True and value.get("pid") == spec["appPID"] == value.get("frontmostPID")
            and len(value.get("windows", [])) == 1, "shared helper failed foreground/window ownership")
    owned = value["windows"][0]
    require(owned["onScreen"] is True and owned["ownerPID"] == spec["appPID"]
            and owned["windowID"] == spec["windowID"] and owned["displayID"] == spec["displayID"]
            and all(owned["bounds"][key] == native_window[key] for key in ("x", "y", "width", "height")),
            "native/shared helper window proof differs")


def clock_interval(report):
    before, after, base = report["clockBefore"], report["clockAfter"], report["timebase"]
    require(all(positive_int(base[key]) and base[key] < 2**32 for key in ("numer", "denom")),
            "missing or invalid native timebase")
    for key in ("wallNS", "absoluteTicks", "continuousTicks"):
        require(positive_int(before[key]) and type(after[key]) is int
                and before[key] < after[key] < 2**64, "invalid observation clock interval")
    scale = base["numer"] / base["denom"]
    absolute = (after["absoluteTicks"] - before["absoluteTicks"]) * scale
    continuous = (after["continuousTicks"] - before["continuousTicks"]) * scale
    wall = after["wallNS"] - before["wallNS"]
    require(abs(absolute - continuous) <= 5_000_000 and abs(wall - absolute) <= 100_000_000,
            "sleep/wall clock discontinuity")
    return scale


def checked_frames(frames, report, spec, required_pixels):
    require(isinstance(frames, list) and 3 <= len(frames) <= 4096, "missing/bounded frame chronology")
    before, after = report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"]
    for frame in frames:
        require(all(positive_int(frame[key]) and frame[key] < 2**64
                    for key in ("callbackTicks", "windowQueryFinishedTicks", "displayTicks"))
                and before <= frame["callbackTicks"] <= frame["windowQueryFinishedTicks"] <= after
                and before < frame["displayTicks"] <= after, "frame clock lies outside observation")
        require(window(frame["window"], spec) == report["windowBefore"], "per-frame ownership/geometry changed")
        row = frame.get("firstRow")
        if row is not None:
            require(type(row) is int and 0 <= row <= 964 and frame["checkedPixels"] == required_pixels
                    and frame["canonicalRowsSHA256"] == viewport_digest(spec["token"], row), "incomplete/incorrect 36-row acknowledgement")
        else:
            require(frame["checkedPixels"] == 0 and frame.get("canonicalRowsSHA256") is None, "partial raster claimed as a match")
    # The same WindowServer event cannot acknowledge two different viewports.
    by_display = {}
    for frame in frames:
        value = (frame.get("firstRow"), frame.get("canonicalRowsSHA256"))
        require(frame["displayTicks"] not in by_display or by_display[frame["displayTicks"]] == value, "conflicting duplicate frame timestamp")
        by_display[frame["displayTicks"]] = value
    return sorted(frames, key=lambda value: value["displayTicks"])


def checked_capture_statuses(report):
    """Validate raw status evidence without changing stability admission."""
    records = report["captureStatuses"]
    require(report["captureStatusSchema"] == 1 and report["captureStatusLimit"] == 65536
            and isinstance(records, list) and 3 <= len(records) <= 65536,
            "missing/bounded native capture status chronology")
    before, after = report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"]
    previous = before
    complete = set()
    for item in records:
        tick, display, status = item["callbackTicks"], item.get("displayTicks"), item.get("statusRaw")
        require(type(tick) is int and previous <= tick <= after
                and type(item["sampleIsValid"]) is bool and type(item["hasImageBuffer"]) is bool
                and (status is None or type(status) is int) and (display is None or type(display) is int and display >= 0)
                and positive_int(item["generation"]) and before <= item["armedAfterTicks"] <= tick,
                "invalid native capture status record")
        previous = tick
        if status == 0 and item["sampleIsValid"] and item["hasImageBuffer"]:
            complete.add((tick, display))
    groups = [report["initial"], *report["warmups"], *report["samples"], *report["mappingAttempts"]]
    require(all((frame["callbackTicks"], frame["displayTicks"]) in complete
                for group in groups for frame in group["frames"]),
            "viewport acknowledgement has no complete native status record")
    for group in groups:
        first = group["stability"]["first"]["displayTicks"]
        finished = group["stability"]["validationFinishedTicks"]
        for item in records:
            if item.get("statusRaw") not in (2, 3, 4, 5):
                continue
            # A status event inside the interval remains disqualifying even
            # when delivered late. Conversely, delivery inside the interval
            # is not excused by a missing or earlier event timestamp.
            event = item.get("displayTicks")
            ticks = [item["callbackTicks"]] + ([event] if type(event) is int and event > 0 else [])
            require(not any(first <= tick <= finished for tick in ticks),
                    "blank/suspended/restarted/stopped capture inside stability interval")
    # Idle neither counts as a later correct frame nor extends stability.


def checked_stability(value, report, spec, required_pixels, target, measured=True):
    ordered = checked_frames(value["frames"], report, spec, required_pixels)
    stable = value["stability"]
    first = stable["first"]
    require(first in ordered and first.get("firstRow") == target, "stability endpoint is not a raw target frame")
    # Calibration may use the final settled suffix to determine distance. No
    # duration from this mapping selection is ever admitted to measured blocks.
    candidates = [frame for frame in ordered if frame.get("firstRow") == target]
    require(candidates, "no complete target frame")
    if measured:
        require(first["displayTicks"] == candidates[0]["displayTicks"], "endpoint moved to a later settled target frame")
    later = [frame for frame in ordered if frame["displayTicks"] > first["displayTicks"]]
    require(later and all(frame.get("firstRow") == target for frame in later), "viewport changed after first complete target")
    distinct = {frame["displayTicks"] for frame in later}
    require(len(distinct) >= 2 and stable["laterCorrectDistinctFrames"] == len(distinct)
            and stable["lastCorrectDisplayTicks"] == max(distinct), "missing distinct stable frames")
    base = report["timebase"]
    require((max(distinct) - first["displayTicks"]) * base["numer"] / base["denom"] >= STABILITY_NS
            and max(distinct) <= stable["validationFinishedTicks"] <= report["clockAfter"]["absoluteTicks"],
            "stable interval too short or beyond validation clock")
    return first


def checked_sample(value, report, spec, required_pixels, before_row, after_row, delta, identifier, measured):
    event = value["event"]
    require(event["rawDelta"] == delta and event["units"] == "line" and event["isContinuous"] is False
            and event["sourceUserData"] == identifier and positive_int(event["eventTimestamp"]), "native wheel payload/post proof differs")
    require(value["beforeFirstRow"] == before_row and value["afterFirstRow"] == after_row
            and value["rowsMoved"] == abs(after_row - before_row), "event work/row plan differs")
    if measured:
        require(abs(after_row - before_row) == 3 and value["status"] == "valid", "measured event did not move exactly three rows")
    else:
        require(value["status"] == "valid-unpooled-mapping", "calibration attempt was not acknowledged")
    for phase in ("Before", "After"):
        tty(value["tty" + phase], spec, report["appIdentity"], report["workerIdentity"]); fixture_probe(value["fixture" + phase])
        require(window(value["window" + phase], spec) == report["windowBefore"], "per-event owned window changed")
    bounds = report["windowBefore"]
    require(bounds["x"] < event["x"] < bounds["x"] + bounds["width"]
            and bounds["y"] < event["y"] < bounds["y"] + bounds["height"], "wheel location is outside owned window")
    first = checked_stability(value, report, spec, required_pixels, after_row, measured=measured)
    require(all(frame["displayTicks"] > event["eventBeforeTicks"] for frame in value["frames"]), "pre-event frame entered acknowledgement")
    result = validate_frame_clock(event["eventBeforeTicks"], event["eventAfterTicks"], first["displayTicks"],
        first["callbackTicks"], first["windowQueryFinishedTicks"], value["stability"]["validationFinishedTicks"],
        report["timebase"]["numer"], report["timebase"]["denom"])
    require(value["ttyBefore"]["finishedTicks"] <= event["eventBeforeTicks"]
            <= event["eventAfterTicks"] <= value["ttyAfter"]["startedTicks"], "event lies outside owned TTY checks")
    return result["eventToCompleteViewportMS"]


def trial_order(values, initial, report):
    previous_end = initial["stability"]["validationFinishedTicks"]
    previous_event_timestamp = 0
    for value in values:
        event = value["event"]
        require(previous_end <= value["ttyBefore"]["startedTicks"]
                <= value["ttyBefore"]["finishedTicks"] <= event["eventBeforeTicks"],
                "events overlap or begin before the preceding stability/TTY proof")
        require(value["stability"]["validationFinishedTicks"] <= value["ttyAfter"]["startedTicks"]
                <= value["ttyAfter"]["finishedTicks"] <= report["clockAfter"]["absoluteTicks"],
                "post-event TTY observation does not follow stability")
        require(event["eventTimestamp"] > previous_event_timestamp, "native wheel creation timestamps repeat or reverse")
        previous_end = value["ttyAfter"]["finishedTicks"]
        previous_event_timestamp = event["eventTimestamp"]


def checked_report(directory, metadata, terminal, calibration):
    spec, report, run, launch = (read(directory / name) for name in ("observer-spec.json", "observation.json", "run.json", "launch.json"))
    mode = "calibrate" if calibration else "measure"
    require(run.get("status") == "valid" and run["mode"] == mode and run["terminal"] == terminal
            and run["observationSHA256"] == digest(directory / "observation.json") and run["observerReturncode"] == 0
            and not run.get("cleanupError") and not run.get("conditionError") and not run.get("error"), "incomplete/invalid owned run")
    start, finish = datetime.fromisoformat(run["startedUTC"]), datetime.fromisoformat(run["finishedUTC"])
    require(start.tzinfo is not None and finish.tzinfo is not None
            and datetime.fromisoformat(metadata["startedUTC"]) <= start < finish <= datetime.fromisoformat(metadata["finishedUTC"]),
            "raw run does not lie inside the recorded batch audit interval")
    require(start.timestamp() * 1e9 <= report["clockBefore"]["wallNS"]
            < report["clockAfter"]["wallNS"] <= finish.timestamp() * 1e9,
            "native wall clock does not lie inside the recorded owned-run interval")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 2
            and report["benchmarkKind"] == "scroll" and report["mode"] == mode
            and report["status"] == ("valid-unpooled-calibration" if calibration else "valid")
            and report["metric"] == metadata["metric"] and report["grid"] == list(GRID)
            and report["specSHA256"] == digest(directory / "observer-spec.json")
            and report["windowGuardFailures"] == [], "invalid observer/spec/guard state")
    require(spec["appPID"] == launch["appPID"] and spec["workerPID"] == launch["workerPID"]
            and report["appIdentity"]["pid"] == spec["appPID"] and report["workerIdentity"]["pid"] == spec["workerPID"]
            and report["appIdentity"]["uid"] == report["workerIdentity"]["uid"]
            and report["appIdentity"]["executable"] == spec["executable"] == metadata["binaries"][terminal]["path"]
            and spec["executableSHA256"] == report["executableSHA256"] == metadata["binaries"][terminal]["sha256"], "binary/process binding differs")
    require(report["controllerPID"] == metadata["controllerPID"] == report["appIdentity"]["parentPID"],
            "native observer did not bind the controller-owned app")
    validate_kernel_ancestry(report["initialAncestry"], report["appIdentity"], report["workerIdentity"])
    require(report["initialAncestry"]["finishedTicks"] <= report["clockBefore"]["absoluteTicks"],
            "initial ancestry proof was not captured before observation")
    require(spec["token"] == run["token"] == report["token"] and launch["terminal"] == terminal
            and launch["profile"] == metadata["profile"] and "CMDY_FRAME_TRACE" not in launch["environment"], "fixture/profile/trace differs")
    validate_launch(directory, metadata, launch, spec)
    require(run["configBeforeLaunchSHA256"] == digest(directory / "config-before-launch.json"),
            "registered launch inputs receipt changed")
    command = launch["fixtureCommand"]
    require(len(command) == 11 and Path(command[0]).resolve() == Path(metadata["runtime"]["python"]["path"]).resolve()
            and command[1] == "-S" and Path(command[2]).name == "scroll_worker.py"
            and command[3] == "--output" and command[5] == "--socket" and command[7:9] == ["--token", spec["token"]]
            and command[9:] == ["--timeout", "600"], "frozen silent worker command/runtime differs")
    require(spec["displayID"] == metadata["displayID"] and spec["requestedFPS"] == 120, "display/capture cadence differs")
    require(window(report["windowBefore"], spec) == window(report["windowAfter"], spec), "window changed")
    require(report["windowBefore"]["processStartSeconds"] == report["appIdentity"]["startSeconds"]
            and report["windowBefore"]["processStartMicroseconds"] == report["appIdentity"]["startMicroseconds"], "native process start identity differs")
    for phase in ("before", "after"):
        require(power(run["power" + phase.title()]) == power(metadata["powerBefore"]), "per-run power changed")
        require(native_condition_signature(run["native" + phase.title()]) == native_condition_signature(metadata["nativeBefore"]), "per-run native conditions changed")
        checked_window_helper(read(directory / f"window-{phase}.json"), spec, report["windowBefore"])
        actual = read(directory / f"grid-{phase}.json")
        require([actual["columns"], actual["rows"]] == list(GRID), "actual grid differs")
    environment = {key: metadata["nativeBefore"][key] for key in ("lowPowerMode", "thermalState", "os")}
    require(report["environmentBefore"] == report["environmentAfter"] == environment, "observer conditions differ")
    clock_interval(report)
    checked_capture_statuses(report)
    required_pixels = geometry(report["geometry"])
    require(report["capture"]["kind"] == "owned-window" and report["capture"]["requestedFPS"] == 120
            and report["capture"]["width"] == report["geometry"]["width"]
            and report["capture"]["height"] == report["geometry"]["height"]
            and report["stabilityNS"] == STABILITY_NS, "capture/geometry/stability contract differs")
    checked_chrome_geometry(report, spec)
    for phase in ("Before", "After"):
        tty(report["tty" + phase], spec, report["appIdentity"], report["workerIdentity"]); fixture_probe(report["fixture" + phase])
    checked_stability(report["initial"], report, spec, required_pixels, 964)
    require(report["clockBefore"]["absoluteTicks"] <= report["captureStartTicks"]
            and all(frame["displayTicks"] > report["captureStartTicks"] for frame in report["initial"]["frames"]),
            "initial stability included a frame from before stream arming")
    # Exact controlled config plus separately stable semantic hash; only the
    # generated per-session cwd differs between fresh Ghostty invocations.
    from scroll_bench import config_text, normalized_config_hash
    options = BenchOptions(Path(metadata["binaries"]["cmdy"]["path"]), Path(metadata["binaries"]["ghostty"]["path"]), profile=metadata["profile"])
    config = directory / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
    require(config.read_text() == config_text(terminal, options, Path(launch["cwd"]))
            and digest(config) == launch["configSHA256"]
            and run["canonicalConfigSHA256"] == normalized_config_hash(terminal, options), "isolated config content/hash differs")
    if terminal == "ghostty":
        from scroll_public_config import validate_public_policy
        query = read(directory / "public-config-query.json")
        require(digest(directory / "public-config-query.json") == run["publicConfigQuerySHA256"],
                "public installed defaults/config-validation evidence changed")
        policy = validate_public_policy(query, metadata["binaries"][terminal]["path"],
            metadata["binaries"][terminal]["sha256"], launch["config"], config.read_text(), metadata["profile"])
        require(policy["validatedDiscreteMultiplier"] == run["validatedDiscreteMultiplier"]
                and policy["policyOrigin"] == run["discretePolicyOrigin"],
                "validated discrete scroll policy differs")
    prepared, final, ready = (read(directory / "fixture" / name) for name in ("prepared.json", "final.json", "ready.json"))
    generated = payload(spec["token"])
    require(ready["status"] == "ready" and prepared["status"] == "prepared" and final["status"] == "stopped",
            "worker lifecycle states are incomplete or out of order")
    require(digest(directory / "fixture/prepared.json") == run["preparedSHA256"]
            and all(record["pid"] == spec["workerPID"] and record["token"] == spec["token"]
                    and record["ttyPath"] == spec["ttyPath"] and record["unexpectedInputBytes"] == 0
                    for record in (ready, prepared, final)), "worker identity/noise proof differs")
    for record in (ready, prepared, final):
        require(record["workerSourceSHA256"] == metadata["toolingSHA256"]["scroll_worker.py"]
                and record["protocolSourceSHA256"] == metadata["toolingSHA256"]["scroll_protocol.py"]
                and record["transportSourceSHA256"] == metadata["toolingSHA256"]["terminal_bench_worker.py"], "executed worker/module hashes differ")
    require(prepared["payloadSHA256"] == hashlib.sha256(generated).hexdigest()
            and prepared["payloadBytes"] == len(generated) and prepared["historyRows"] == 1000
            and prepared["dsrReplyHex"] == b"\x1b[36;1R".hex()
            and prepared["dsrQueryHex"] == b"\x1b[36;1H\x1b[6n".hex(), "setup generated bytes/DSR mismatch")
    require(not (ready["ttyFlagsRaw"][1] & termios.OPOST), "fixture output was not raw; inactive ONLCR alone is irrelevant")
    stopped = read(directory / "fixture-stop.json")
    require(stopped.get("complete") is True and stopped.get("workerExited") is True
            and stopped["finalSHA256"] == digest(directory / "fixture/final.json")
            and final["status"] == "stopped" and final["stopReason"] == "control-finish"
            and final["terminalModeRestored"] is True and final["fileFlagsRestored"] is True
            and final["modeDifferenceIndices"] == [] and final["ttyFlagsRestored"] == final["ttyFlagsOriginal"],
            "missing restored fixture final record/exit")
    cleanup = read(directory / "cleanup.json")
    require(type(cleanup.get("returncode")) is int and cleanup.get("appPID") == spec["appPID"]
            and not cleanup.get("forcedKill"), "owned app cleanup incomplete/forced")
    mapping = report["mapping"]
    require(mapping["rowsPerEvent"] == 3 and mapping["units"] == "line" and mapping["isContinuous"] is False,
            "one-event three-row mapping differs")
    if calibration:
        require(report["samples"] == [] and report["warmups"] == [], "calibration mixed with measured events")
        attempts = report["mappingAttempts"]
        require(len(attempts) >= 2 and len(attempts) <= 20 and len(attempts) % 2 == 0, "incomplete mapping search")
        trial_order(attempts, report["initial"], report)
        for index in range(0, len(attempts), 2):
            delta = index // 2 + 1
            actual = attempts[index]["afterFirstRow"]
            require(type(actual) is int and 0 <= actual <= 964, "invalid calibrated distance")
            checked_sample(attempts[index], report, spec, required_pixels, 964, actual, delta, index + 1, False)
            checked_sample(attempts[index + 1], report, spec, required_pixels, actual, 964, -delta, index + 2, False)
            require((actual == 961) is (index == len(attempts) - 2), "mapping search skipped/continued past first equal-work result")
        require(mapping["upwardRawDelta"] == len(attempts) // 2 and mapping["downwardRawDelta"] == -len(attempts) // 2,
                "frozen mapping differs from actual accepted events")
        return [], report, spec, launch
    require(report["mappingAttempts"] == [] and len(report["warmups"]) == 2 and len(report["samples"]) == SAMPLES,
            "missing/excess measured samples or warmups")
    trial_order(report["warmups"] + report["samples"], report["initial"], report)
    for index, value in enumerate(report["warmups"]):
        require(value["sequence"] == index and value["warmup"] is True, "warmup classification/sequence changed")
        checked_sample(value, report, spec, required_pixels, 964 - 3 * index, 961 - 3 * index,
                       mapping["upwardRawDelta"], index + 1, True)
    values = []
    for plan, value in zip(sample_plan(), report["samples"]):
        require(value["sequence"] == plan["sequence"] and value["warmup"] is False, "measured event sequence changed")
        values.append(checked_sample(value, report, spec, required_pixels, plan["beforeFirstRow"], plan["afterFirstRow"],
            mapping["upwardRawDelta"] if plan["direction"] < 0 else mapping["downwardRawDelta"], plan["sequence"] + 3, True))
    return values, report, spec, launch


def load_scroll_evidence(directory, expected_binaries=None):
    directory = Path(directory)
    metadata = read(directory / "manifest.json")
    require(metadata.get("schemaVersion") == 1 and metadata.get("benchmarkKind") == "scroll"
            and metadata.get("state") == "complete" and metadata.get("diagnostic") is False
            and metadata.get("calibrationOnly") is False and not metadata.get("error"), "incomplete/diagnostic/calibration-only scroll evidence")
    require(metadata["metric"] == "synthetic-wheel-to-first-complete-three-row-viewport-frame"
            and metadata["requestedBlocks"] == BLOCKS and metadata["samplesPerBlock"] == SAMPLES
            and metadata["warmupsPerBlock"] == 2 and metadata["grid"] == list(GRID)
            and metadata["profile"] in ("matched", "cmdy-defaults"), "scroll case/profile/count contract differs")
    binaries = {name: metadata["binaries"][name]["sha256"] for name in ("cmdy", "ghostty")}
    require(all(re.fullmatch("[0-9a-f]{64}", value) for value in binaries.values())
            and (expected_binaries is None or binaries == expected_binaries), "pinned binaries differ")
    runtime = metadata["runtime"]
    require(runtime["workerPythonFlags"] == ["-S"] and runtime["pythonVersion"]
            and all(re.fullmatch("[0-9a-f]{64}", runtime[key]["sha256"]) for key in ("python", "shell")), "worker/shell runtime identity missing")
    for name, expected in metadata["toolingSHA256"].items():
        require(Path(name).name == name and digest(directory / "tooling" / name) == expected, "frozen tooling drift")
    from scroll_bench import SOURCES
    require(set(metadata["toolingSHA256"]) == set(SOURCES) | {"scroll-observer", "window-helper"}, "incomplete tooling identity")
    for name in ("BenchKernelAncestry.swift", "bench_ancestry.py"):
        require(metadata["toolingSHA256"][name] == digest(Path(__file__).resolve().parent / name),
                "ancestry helper differs from trusted validator source")
    require(metadata["sourceBefore"] == metadata["sourceAfter"] and metadata["sourceBefore"]["status"] == "valid"
            and metadata["sourceBefore"]["manifestSHA256"] == digest(directory / "app-source-manifest.json"), "app source manifest drift/missing audit")
    require(len(read(directory / "app-source-manifest.json")["sources"]) == metadata["sourceBefore"]["sourceCount"], "source audit count differs")
    require(power(metadata["powerBefore"]) == power(metadata["powerAfter"]), "batch power changed")
    require(native_condition_signature(metadata["nativeBefore"]) == native_condition_signature(metadata["nativeAfter"]), "batch native conditions changed")
    machine = metadata["machine"]
    require(machine["font"]["postScriptName"] == "Menlo-Regular" and machine["font"]["sizePoints"] == 14
            and re.fullmatch("[0-9a-f]{64}", metadata["fontSHA256"])
            and all(machine[key] == metadata["machineAfter"][key] for key in ("font", "displays")), "font/display metadata changed")
    mappings = {name: WheelCalibration(**metadata["calibrations"][name]) for name in ("cmdy", "ghostty")}
    validate_paired_calibration(mappings["cmdy"], mappings["ghostty"])
    chronology, calibration_tokens, launch_domains = [], set(), set()
    for name, mapping in mappings.items():
        require(mapping.binary_sha256 == binaries[name] and mapping.profile == metadata["profile"]
                and mapping.source_sha256 == metadata["toolingSHA256"]["scroll_protocol.py"], "calibration provenance differs")
        folder = directory / "calibration" / name
        _, report, spec, launch = checked_report(folder, metadata, name, True)
        require(launch["defaultsDomain"] not in launch_domains, "defaults domain was reused across isolated runs")
        launch_domains.add(launch["defaultsDomain"])
        chronology.append((launch["startedMonotonicNS"], report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"]))
        calibration_tokens.add(spec["token"])
        require(mapping.raw_evidence_sha256 == digest(folder / "observation.json")
                and mapping.config_sha256 == read(folder / "run.json")["canonicalConfigSHA256"]
                and mapping.upward_raw_delta == report["mapping"]["upwardRawDelta"]
                and mapping.downward_raw_delta == report["mapping"]["downwardRawDelta"], "raw calibration and mapping differ")
    require(len(calibration_tokens) == 1, "calibration pair received different payloads")
    require(len(metadata["runs"]) == BLOCKS * 2, "missing paired block records")
    actual_dirs = sorted(path.name for path in (directory / "runs").iterdir() if path.is_dir())
    expected_dirs = sorted(f"{block:02d}-{name}" for block in range(BLOCKS) for name in ("cmdy", "ghostty"))
    require(actual_dirs == expected_dirs, "missing/extra run directories")
    blocks, orders, tokens = {}, {}, {}
    for index, item in enumerate(metadata["runs"]):
        block, terminal = item["block"], item["terminal"]
        require(type(block) is int and 0 <= block < BLOCKS and terminal in mappings
                and item["path"] == f"runs/{block:02d}-{terminal}", "unsafe/incorrect run index")
        folder = directory / item["path"]
        require(digest(folder / "run.json") == item["runSHA256"]
                and digest(folder / "observation.json") == item["observationSHA256"], "raw run hashes differ")
        values, report, spec, launch = checked_report(folder, metadata, terminal, False)
        require(launch["defaultsDomain"] not in launch_domains, "defaults domain was reused across isolated runs")
        launch_domains.add(launch["defaultsDomain"])
        chronology.append((launch["startedMonotonicNS"], report["clockBefore"]["absoluteTicks"], report["clockAfter"]["absoluteTicks"]))
        require(terminal not in blocks.setdefault(block, {}), "duplicate app/block")
        blocks[block][terminal] = values
        orders.setdefault(block, []).append((launch["startedMonotonicNS"], terminal))
        tokens.setdefault(block, set()).add(spec["token"])
        mapping = mappings[terminal]
        require(report["mapping"]["upwardRawDelta"] == mapping.upward_raw_delta
                and report["mapping"]["downwardRawDelta"] == mapping.downward_raw_delta
                and read(folder / "run.json")["canonicalConfigSHA256"] == mapping.config_sha256,
                "measured event/config differs from preregistered calibration")
    require(sorted(blocks) == list(range(BLOCKS)) and all(set(pair) == {"cmdy", "ghostty"} for pair in blocks.values()), "unpaired blocks")
    firsts = [sorted(orders[block])[0][1] for block in range(BLOCKS)]
    require(firsts.count("cmdy") == firsts.count("ghostty") == BLOCKS // 2
            and firsts[0] == metadata["first"] and all(firsts[i] != firsts[i - 1] for i in range(1, BLOCKS)), "block order not counterbalanced")
    chronology.sort()
    require(len({item[0] for item in chronology}) == len(chronology)
            and all(chronology[index][1] > chronology[index - 1][2] for index in range(1, len(chronology))),
            "owned app observations overlap or native clocks reverse across runs")
    require(all(len(value) == 1 for value in tokens.values()) and len(set.union(*tokens.values())) == BLOCKS,
            "apps did not receive identical per-pair payloads or nonce was reused across blocks")
    require(isinstance(metadata.get("hardware", {}).get("stdout"), str) and metadata["hardware"]["stdout"], "missing hardware identity")
    return {"path": str(directory), "case": "scroll", "kind": "input", "metric": metadata["metric"],
            "profile": metadata["profile"], "power": power(metadata["powerBefore"]), "binaries": binaries,
            "grid": list(GRID), "blocks": blocks, "display": metadata["displayID"], "font": machine["font"],
            "fontSHA256": metadata["fontSHA256"], "displays": machine["displays"],
            "observerEnvironment": {key: metadata["nativeBefore"][key] for key in ("lowPowerMode", "thermalState", "os")},
            "hardware": metadata["hardware"]["stdout"], "scrollProtocol": {"rowsPerEvent": 3,
                "units": "line", "samplesPerBlock": SAMPLES, "stabilityNS": STABILITY_NS,
                "calibrations": metadata["calibrations"]}}
