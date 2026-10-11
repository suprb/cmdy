"""Pure accounting and geometry gates; no application-specific fast paths."""
from __future__ import annotations
import hashlib
import math

RATE = 4_000_000
QUANTUM = 40_000
PERIOD_NS = 10_000_000
GRID = {"columns": 60, "rows": 18}
PAYLOAD_PERIOD = b"neutral pane output 0123456789abcdefghijklmnopqrstuvwxyz ABCD\r\n"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def descriptor_flags_match(original, restored, platform=None):
    if type(original) is not int or type(restored) is not int or min(original, restored) < 0:
        return False
    # Darwin exposes the sticky FWASWRITTEN kernel status through F_GETFL.
    # Writing the fixture can add it; F_SETFL cannot undo a completed write.
    # https://github.com/apple/darwin-xnu/blob/main/bsd/sys/fcntl.h
    return restored == original or (platform == "darwin" and restored == original | 0x00010000)


def validate_latency(report, pid, window_id, region, expected_count):
    """Reconstruct the endpoint from native clocks, including signed callback lag."""
    # Share the single-pane reader's UInt32 timebase, UInt64 tick bounds,
    # first-frame endpoint and signed callback calculation. Do not revive the
    # private schema-2 observer when loading historical four-pane records.
    from parity_gate import input_frame_durations
    values = input_frame_durations(report)
    require(report.get("metric") == "synthetic-key-to-WindowServer-frame"
            and report.get("markerMode") == "local-row", "wrong observer metric")
    require(report.get("pid") == pid and report.get("windowID") == window_id,
            "observer did not target the owned window")
    capture = report.get("capture", {})
    require(capture.get("region") == region and capture.get("requestedFPS") == 120
            and type(capture.get("completeFrames")) is int and capture["completeFrames"] > 0,
            "observer capture differs from derived pane region")
    samples = report["samples"]
    require(len(samples) == expected_count,
            "observer sample sequence differs")
    for sample in samples:
        frame = sample["frame"]
        require(type(frame.get("matchingPixels")) is int and frame["matchingPixels"] >= 64,
                "marker has insufficient validated pixels")
    ordered = sorted(values)
    require(bool(ordered), "no measured key events")
    expected_summary = {"median": ordered[math.ceil(.5 * len(ordered)) - 1],
                        "p95": ordered[math.ceil(.95 * len(ordered)) - 1], "max": ordered[-1]}
    require(set(report.get("summaryMs", {})) == set(expected_summary), "wrong observer summary")
    require(all(type(report["summaryMs"][key]) in (int, float)
                and math.isfinite(report["summaryMs"][key])
                and math.isclose(report["summaryMs"][key], expected, rel_tol=1e-12, abs_tol=1e-12)
                for key, expected in expected_summary.items()), "observer percentiles differ from raw clocks")
    return values


def validate_response_clocks(report, observation, receipts):
    """Tie every first-frame event to its real key receipt and offered-load interval."""
    start, finish = observation["startedMonotonicNs"], observation["finishedMonotonicNs"]
    require(type(start) is int and type(finish) is int and 0 < start < finish,
            "invalid host observation interval")
    require(len(report["samples"]) == len(receipts), "missing per-key receipt")
    base = report["timebase"]
    def ns(ticks):
        return ticks * base["numer"] // base["denom"]
    for sample, receipt in zip(report["samples"], receipts):
        require(sample["sequence"] == receipt["sequence"], "response sequence differs")
        clocks = [ns(sample[key]) for key in ("postBeforeTicks", "postAfterTicks", "validationFinishedTicks")]
        clocks.extend(ns(sample["frame"][key]) for key in ("displayTicks", "callbackTicks"))
        require(all(start <= value <= finish for value in clocks),
                "native event/frame escaped the measured busy-load interval")
        received, replied = receipt["receivedMonotonicNs"], receipt["repliedMonotonicNs"]
        require(clocks[0] <= received <= clocks[3] and received <= replied <= finish,
                "first frame is not ordered after its actual key receipt")
        # The last write can return after the consumer has presented its bytes.
        # It is retained and bounded, never used to replace the first-frame endpoint.


def validate_settling(record, observation):
    require(record.get("offers") and observation["startedMonotonicNs"] - record["offers"][0][2]
            >= 5_000_000_000, "five seconds of settling after actual offered load were not completed")


def validate_stream(record):
    require(record.get("requestedBytesPerSecond") == RATE, "unexpected offered rate")
    require(record.get("quantumBytes") == QUANTUM and record.get("periodNs") == PERIOD_NS,
            "unexpected offered schedule")
    start = record.get("activeStartNs")
    require(type(start) is int and start > 0, "missing active stream start")
    offers, writes = record.get("offers"), record.get("writes")
    require(isinstance(offers, list) and isinstance(writes, list), "missing raw receipts")
    prior_offer = None
    for index, offer in enumerate(offers):
        require(len(offer) == 5 and all(type(x) is int for x in offer), "invalid offer receipt")
        sequence, scheduled, actual, offset, length = offer
        require((sequence, scheduled, offset, length) ==
                (index, start + index * PERIOD_NS, index * QUANTUM, QUANTUM), "offer sequence or schedule changed")
        require(actual >= scheduled and (prior_offer is None or actual - prior_offer >= PERIOD_NS),
                "early offer or catch-up burst")
        prior_offer = actual
    count = 0
    ended = 0
    for write in writes:
        require(len(write) == 5 and all(type(x) is int for x in write), "invalid write receipt")
        sequence, offset, size, before, after = write
        require(0 <= sequence < len(offers), "write has no matching offer")
        offer = offers[sequence]
        require(offset == count and 0 < size <= QUANTUM, "completed byte gap or duplication")
        require(offset >= offer[3] and offset + size <= offer[3] + offer[4], "write escapes offered range")
        require(before >= offer[2] and before >= ended and after >= before, "write clock ordering invalid")
        if sequence + 1 < len(offers):
            require(after <= offers[sequence + 1][2], "more than one chunk was pending")
        count += size
        ended = after
    require(record.get("completedBytes") == count and record.get("offeredBytes") == len(offers) * QUANTUM,
            "receipt totals do not reconcile")
    require(record.get("pendingBytes") == len(offers) * QUANTUM - count and 0 <= record["pendingBytes"] <= QUANTUM,
            "pending data is not bounded by one offered chunk")
    require(ended <= record.get("stoppedMonotonicNs", 0), "writes extend after cleanup")


def interval_bounds(writes, start, finish):
    require(type(start) is int and type(finish) is int and finish > start, "invalid observation interval")
    lower = upper = 0
    for _, _, count, before, after in writes:
        if before >= start and after <= finish:
            lower += count
            upper += count
        elif after >= start and before <= finish:
            upper += count
    duration = (finish - start) / 1e9
    return {"startNs": start, "finishNs": finish, "durationSeconds": duration,
            "lowerBytes": lower, "upperBytes": upper,
            "lowerBytesPerSecond": lower / duration, "upperBytesPerSecond": upper / duration}


def validate_exit_barrier(workers, release, exits, final_hashes, release_hash):
    slots = {str(slot) for slot in workers}
    require(slots == {"0", "1", "2", "3"} and set(exits) == slots,
            "four worker exit receipts required")
    require(release.get("workerPIDs") == {str(slot): w["pid"] for slot, w in workers.items()}
            and release.get("finalSHA256") == final_hashes and set(final_hashes) == slots,
            "exit barrier does not bind all final worker receipts")
    ready, released = release.get("finalRecordsReadyMonotonicNs"), release.get("releaseMonotonicNs")
    require(type(ready) is int and type(released) is int
            and max(w["stoppedMonotonicNs"] for w in workers.values()) <= ready <= released,
            "exit barrier released before final records were ready")
    for slot, worker in workers.items():
        exited = exits[str(slot)]
        require(worker.get("exitBarrierRequested") is True
                and release.get("runToken") == worker["runToken"]
                and all(exited.get(k) == worker[k] for k in ("pid", "slot", "runToken"))
                and exited.get("status") == "released" and exited.get("releaseSHA256") == release_hash
                and exited.get("releaseMonotonicNs") == released
                and type(exited.get("exitingMonotonicNs")) is int
                and exited["exitingMonotonicNs"] >= released,
                "worker exited without the complete final-record barrier")


def validate_busy(record, observation):
    require(record.get("payloadPeriodHex") == PAYLOAD_PERIOD.hex()
            and record.get("payloadPeriodSHA256") == hashlib.sha256(PAYLOAD_PERIOD).hexdigest(),
            "busy payload differs from the registered byte stream")
    validate_stream(record)
    start, finish = observation["startedMonotonicNs"], observation["finishedMonotonicNs"]
    require(finish - start >= 4_000_000_000, "observation shorter than four seconds")
    require(record.get("status") == "stopped" and record.get("stopReason") in ("control-stop", "signal-SIGTERM"),
            "busy worker did not finish cleanly")
    require(record["activeStartNs"] <= start < finish <= record["stoppedMonotonicNs"], "incomplete interval coverage")
    require(record.get("activeGrid") == GRID and record.get("finalGrid") == GRID, "busy grid is not 60x18")
    require(not any(start <= item["monotonicNs"] <= finish for item in record.get("geometryChanges", [])),
            "geometry changed during observation")
    require(not record.get("received"), "busy worker received measured input")
    require(all(record.get("cleanup", {}).get(key) is True for key in ("termiosRestored", "stdoutRestored")),
            "terminal restoration failed")
    total = interval_bounds(record["writes"], start, finish)
    require(total["upperBytes"] - total["lowerBytes"] <= 2 * QUANTUM, "excessive boundary uncertainty")
    require(total["lowerBytesPerSecond"] >= RATE * .98 and total["upperBytesPerSecond"] <= RATE * 1.02,
            "observation throughput outside registered 98-102 percent bound")
    buckets = []
    for index in range((finish - start) // 1_000_000_000):
        bucket = interval_bounds(record["writes"], start + index * 1_000_000_000,
                                 start + (index + 1) * 1_000_000_000)
        require(bucket["lowerBytesPerSecond"] >= RATE * .9 and bucket["upperBytesPerSecond"] <= RATE * 1.1,
                "one-second throughput outside registered 90-110 percent bound")
        buckets.append(bucket)
    return {"wholeInterval": total, "oneSecondBuckets": buckets}


def validate_marker(record, latency, observation, expected_count):
    expected = list(range(1, expected_count + 1))
    received = record.get("received", [])
    require([entry.get("sequence") for entry in received] == expected, "marker receipt ordering differs")
    require([entry.get("sequence") for entry in latency["samples"]] == expected, "observer sequence differs")
    require(record.get("activeGrid") == GRID and record.get("finalGrid") == GRID, "marker grid is not 60x18")
    require(record.get("status") == "stopped" and record.get("stopReason") in ("control-stop", "signal-SIGTERM"),
            "marker did not finish cleanly")
    require(all(record.get("cleanup", {}).get(key) is True for key in ("termiosRestored", "stdoutRestored")),
            "marker terminal restoration failed")
    start, finish = observation["startedMonotonicNs"], observation["finishedMonotonicNs"]
    require(record["activeStartNs"] <= start < finish <= record["stoppedMonotonicNs"], "marker interval not covered")
    require(not any(start <= item["monotonicNs"] <= finish for item in record.get("geometryChanges", [])),
            "marker geometry changed during observation")
    require(all(item.get("byte") == 97 and item.get("replied") is True
                and start <= item["receivedMonotonicNs"] <= item["repliedMonotonicNs"] <= finish for item in received),
            "unexpected marker byte, failed response, or clock ordering")


def validate_rectangles(rectangles):
    require(len(rectangles) == 4 and all(type(r["slot"]) is int for r in rectangles)
            and {r["slot"] for r in rectangles} == {0, 1, 2, 3}, "four unique pane landmarks required")
    rects = {r["slot"]: r for r in rectangles}
    for rect in rects.values():
        require(all(type(rect[k]) in (int, float) and math.isfinite(rect[k]) for k in ("x", "y", "width", "height")),
                "nonfinite pane rectangle")
        require(rect["width"] > 0.2 and rect["height"] > 0.2
                and 0 <= rect["x"] < rect["x"] + rect["width"] <= 1
                and 0 <= rect["y"] < rect["y"] + rect["height"] <= 1
                and type(rect.get("fillFraction")) in (int, float)
                and .98 <= rect["fillFraction"] <= 1,
                "pane landmark missing, too small, or nonrectangular")
    a, b, c, d = [rects[i] for i in range(4)]
    require(a["x"] + a["width"] < b["x"] and c["x"] + c["width"] < d["x"]
            and a["y"] + a["height"] < c["y"] and b["y"] + b["height"] < d["y"], "panes are not disjoint 2x2")
    require(max(r["width"] for r in rects.values()) - min(r["width"] for r in rects.values()) <= .012
            and max(r["height"] for r in rects.values()) - min(r["height"] for r in rects.values()) <= .018,
            "pane extents are not equal")
    require(abs(a["x"] - c["x"]) < .012 and abs(b["x"] - d["x"]) < .012
            and abs(a["y"] - b["y"]) < .018 and abs(c["y"] - d["y"]) < .018,
            "pane rows or columns are misaligned")
    # Scan the actual interior; retain this derivation beside the raw capture.
    return {"x": a["x"] + a["width"] * .12, "y": a["y"] + a["height"] * .12,
            "width": a["width"] * .76, "height": a["height"] * .76}
