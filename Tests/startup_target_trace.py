"""Independent, pure validator for protocol-v5 startup worker traces.

This validates worker chronology only, not a displayed frame or a performance
sample. Native frame validation and complete prospective cohort admission are also required.
"""
import hashlib
from startup_grid import Witness

PROTOCOL = "startup-full-generated-viewport-v5"


def require(value, message):
    if not value:
        raise ValueError(message)


def integer(value, label, low=0, high=2**64 - 1):
    require(type(value) is int and low <= value <= high, "invalid " + label)
    return value


def validate(ready, output, cleanup, token, target):
    Witness(token, *target, 1, 1).validate()
    require(output["protocol"] == cleanup["protocol"] == PROTOCOL
        and output["diagnosticOnly"] is True, "foreign or scored diagnostic")
    pid = integer(ready["pid"], "worker PID", 1)
    require(output["pid"] == cleanup["pid"] == pid
        and ready["token"] == output["token"] == cleanup["token"] == token,
        "worker identity or nonce differs")
    require(output["targetGrid"] == list(target) and output["status"] == "stopped"
        and output["error"] == cleanup["error"] == "" and output["signalOverflow"] is False,
        "incomplete or failed worker trace")
    require(cleanup["generation"] == 1 and cleanup["completedViewport"] is True
        and cleanup["termiosRestored"] is True and cleanup["flagsRestored"] is True,
        "worker completion or cleanup missing")
    start = integer(ready["startedTicks"], "worker start", 1)
    recorded = integer(output["recordedTicks"], "trace publication", start)
    integer(cleanup["finishedTicks"], "worker cleanup", recorded)
    signals, observations, events = output["signals"], output["gridObservations"], output["events"]
    require(isinstance(signals, list) and len(signals) <= 64
        and isinstance(observations, list) and 4 <= len(observations) <= 512
        and isinstance(events, list) and len(events) == 1, "missing or unbounded chronology")
    previous = start
    for value in signals:
        require(set(value) == {"receivedTicks"}, "unexpected signal fields")
        previous = integer(value["receivedTicks"], "SIGWINCH", previous, recorded)

    def count(tick):
        return sum(value["receivedTicks"] <= tick for value in signals)

    first_target = None
    previous = start
    for index, value in enumerate(observations):
        require(set(value) == {"index", "reason", "beforeTicks", "afterTicks", "columns", "rows",
            "signalCounterBefore", "signalCounterAfter"}, "incomplete grid observation")
        require(type(value["index"]) is int and value["index"] == index, "reordered grid observation")
        before = integer(value["beforeTicks"], "ioctl begin", previous, recorded)
        previous = integer(value["afterTicks"], "ioctl end", before, recorded)
        columns = integer(value["columns"], "observed columns", 0, 65535)
        rows = integer(value["rows"], "observed rows", 0, 65535)
        require(integer(value["signalCounterBefore"], "ioctl signal counter", 0, 64) == count(before)
            and integer(value["signalCounterAfter"], "ioctl signal counter", 0, 64) == count(previous),
            "ioctl signal chronology differs")
        require(value["reason"] in ("initial", "wake", "poll", "before-write", "signal-during-write", "after-write", "final"),
            "unknown ioctl reason")
        if (columns, rows) == tuple(target) and first_target is None:
            first_target = index
        if first_target is not None:
            require((columns, rows) == tuple(target), "observed grid changed after first target")
    require(observations[0]["reason"] == "initial" and observations[-1]["reason"] == "final"
        and all(value["reason"] not in ("initial", "final") for value in observations[1:-1]),
        "initial or final grid evidence differs")
    require((ready["initialColumns"], ready["initialRows"]) ==
        (observations[0]["columns"], observations[0]["rows"]), "true initial grid was replaced")
    require(first_target is not None and type(output["firstTargetIndex"]) is int
        and output["firstTargetIndex"] == first_target, "skipped first target observation")
    require(all(value["reason"] in ("initial", "wake", "poll") for value in observations[:first_target + 1]),
        "write happened before target")
    event = events[0]
    core_fields = {"generation", "columns", "rows", "observedTicks", "startedTicks", "completedTicks",
        "offeredBytes", "completedBytes", "payloadSHA256"}
    require(set(event) == core_fields | {"signalCounterAtObserved", "signalCounterAtStarted", "signalCounter"}
        and output["paintAttempt"] == {key: event[key] for key in core_fields},
        "extra, partial or substituted paint attempt")
    require(type(event["generation"]) is int and event["generation"] == 1
        and (event["columns"], event["rows"]) == tuple(target), "noninitial or wrong-grid paint")
    payload = Witness(token, *target, 1, 1).frame_bytes()
    require(integer(event["offeredBytes"], "offered bytes", 1) == len(payload)
        and integer(event["completedBytes"], "completed bytes", 1) == len(payload)
        and event["payloadSHA256"] == hashlib.sha256(payload).hexdigest(), "generated work differs")
    observed = integer(event["observedTicks"], "target observation", start, recorded)
    paint_start = integer(event["startedTicks"], "write begin", observed, recorded)
    completed = integer(event["completedTicks"], "write completion", paint_start, recorded)
    require(observed == observations[first_target]["afterTicks"], "paint clock lost target wait")
    for field, tick in (("signalCounterAtObserved", observed), ("signalCounterAtStarted", paint_start),
                        ("signalCounter", completed)):
        require(integer(event[field], field, 0, 64) == count(tick), "paint signal chronology differs")
    before = [value for value in observations if value["reason"] == "before-write"]
    after = [value for value in observations if value["reason"] == "after-write"]
    require(len(before) == len(after) == 1 and before[0]["index"] == first_target + 1
        and before[0]["afterTicks"] <= paint_start and completed <= after[0]["beforeTicks"]
        and after[0]["index"] > before[0]["index"], "write lacks adjacent grid brackets")
    between = observations[before[0]["index"] + 1:after[0]["index"]]
    require(all(value["reason"] == "signal-during-write" and paint_start <= value["beforeTicks"]
        <= value["afterTicks"] <= completed for value in between), "write-time grid check misplaced")
    require(all(value["reason"] in ("poll", "wake", "final")
        for value in observations[after[0]["index"] + 1:]), "unexpected post-paint observation")
    require(all(value["receivedTicks"] <= observations[-1]["afterTicks"] for value in signals),
        "signal lacks final grid observation")
    return dict(diagnosticOnly=True, qualifying=False, workerTraceValid=True,
        initialGrid=[ready["initialColumns"], ready["initialRows"]], targetGrid=list(target),
        waitedForTarget=first_target > 0, generatedViewports=1,
        observations=len(observations), deliveredSignals=len(signals))
