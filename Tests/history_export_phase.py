"""Explicit, verification-only output after the original generated drain/samples."""
from history_export_protocol import ACTION, digest, expected_bytes, memory_payload, require

POLICY = "post-sample-public-history-v1"
CASES = ("primary-1000", "primary-5000", "alternate-continuous")
SCREEN_ACTION = "write_screen_file:paste"


def contract(case):
    require(type(case) is str and case in CASES, "verification-case-differs")
    primary = case != "alternate-continuous"
    # Each fixed 76-column CRLF workload leaves 35 data rows and one blank
    # row in the 120x36 screen. The original DSR footer moved the cursor.
    payload = b"\x1b[36;1H" + b"\r\n" * 35 + b"\x1b[6n" if primary else b""
    return dict(schemaVersion=1, policy=POLICY, case=case,
        action=ACTION if primary else SCREEN_ACTION, grid=dict(columns=120, rows=36),
        payloadHex=payload.hex(), payloadBytes=len(payload), payloadSHA256=digest(payload),
        expectedReplyHex=b"\x1b[36;1R".hex() if primary else "", blankLines=35 if primary else 0)


def selected_action(case=None, policy=None):
    if policy is None:
        require(case is None, "legacy-action-must-not-select-a-case")
        return ACTION
    require(type(policy) is str and policy == POLICY, "verification-policy-differs")
    return contract(case)["action"]


def validate_contract(value, case):
    expected = contract(case)
    require(type(value) is dict and set(value) == set(expected)
        and all(type(value[key]) is type(item) for key, item in expected.items())
        and type(value["grid"]) is dict and set(value["grid"]) == {"columns", "rows"}
        and all(type(item) is int for item in value["grid"].values()) and value == expected,
        "verification-contract-differs")
    return expected


def integer(value, *, positive=False):
    require(type(value) is int and (0 < value if positive else 0 <= value) and value < 1 << 63,
            "verification-integer-differs")
    return value


def validate_boundary(value, drain_finished):
    integer(drain_finished, positive=True)
    require(type(value) is dict and set(value) == {"kind", "finishedMonotonicNS"}
        and type(value["kind"]) is str and value["kind"] in ("untimed-drain", "all-memory-samples"),
        "verification-boundary-differs")
    finished = integer(value["finishedMonotonicNS"], positive=True)
    require(finished >= drain_finished and (value["kind"] != "untimed-drain" or finished == drain_finished),
            "verification-boundary-precedes-drain")
    return finished


def authorize_phase(mode, policy, spec, prepared, boundary):
    require(policy == POLICY and mode == "prepared" and type(prepared) is dict
        and prepared.get("expectation") == spec and "drain" in prepared,
        "verification-must-follow-one-original-drain")
    expected_bytes(spec); value = contract(spec["case"])
    validate_boundary(boundary, prepared["drain"]["finishedMonotonicNS"])
    return value


def authorize_arm(mode, policy):
    require(mode == ("verified" if policy == POLICY else "prepared")
        and policy in (None, POLICY), "arm-must-follow-one-preparation-or-verification")


def validate_phase(value, spec, worker_pid, prepared, *, boundary=None, timebase=None):
    fields = {"schemaVersion", "contract", "workerPID", "nonce", "drainFinishedMonotonicNS", "boundary",
              "startedTicks", "finishedTicks", "startedMonotonicNS", "finishedMonotonicNS",
              "gridBefore", "gridAfter", "writtenBytes", "responseHex"}
    require(type(value) is dict and set(value) == fields and type(value["schemaVersion"]) is int
        and value["schemaVersion"] == 1,
        "verification-phase-fields-or-contract-differ")
    validate_contract(value["contract"], spec["case"])
    expected_bytes(spec)
    require(value["workerPID"] == integer(worker_pid, positive=True)
        and type(value["workerPID"]) is int and value["nonce"] == spec["nonce"],
        "verification-worker-or-nonce-differs")
    payload = memory_payload(spec)
    require(prepared["expectation"] == spec and prepared["grid"] == dict(columns=120, rows=36)
        and prepared["bytes"] == len(payload) and prepared["sha256"] == digest(payload)
        and value["drainFinishedMonotonicNS"] == prepared["drain"]["finishedMonotonicNS"],
        "verification-original-drain-binding-differs")
    from terminal_bench_worker import expected_reply
    drained = prepared["drain"]; sequence = integer(drained["sequence"])
    require(sequence < 1000, "verification-drain-sequence-differs")
    footer, reply = expected_reply(36, 120, sequence)
    require(drained["footerHex"] == footer.hex() and drained["responseHex"] == drained["expectedResponseHex"] == reply.hex()
        and drained["payloadBytes"] == len(payload) and drained["gridBefore"] == drained["gridAfter"]
        and all(type(drained["gridBefore"][key]) is int and drained["gridBefore"][key] == number
                for key, number in (("columns", 120), ("rows", 36)))
        and integer(drained["finishedMonotonicNS"], positive=True) - integer(drained["startedMonotonicNS"], positive=True)
            == integer(drained["elapsedNS"], positive=True), "verification-original-drain-differs")
    edge = validate_boundary(value["boundary"], value["drainFinishedMonotonicNS"])
    if boundary is not None: require(value["boundary"] == boundary, "verification-sample-boundary-differs")
    require(edge <= integer(value["startedMonotonicNS"], positive=True)
        <= integer(value["finishedMonotonicNS"], positive=True)
        and integer(value["startedTicks"], positive=True) <= integer(value["finishedTicks"], positive=True),
        "verification-phase-clock-order-differs")
    require(value["gridBefore"] == value["gridAfter"] == value["contract"]["grid"]
        and type(value["writtenBytes"]) is int and value["writtenBytes"] == value["contract"]["payloadBytes"]
        and type(value["responseHex"]) is str and value["responseHex"] == value["contract"]["expectedReplyHex"],
        "verification-output-reply-or-grid-differs")
    if timebase is not None:
        numer, denom = timebase
        integer(numer, positive=True); integer(denom, positive=True)
        require(value["startedMonotonicNS"] <= value["startedTicks"] * numer // denom
            <= value["finishedTicks"] * numer // denom <= value["finishedMonotonicNS"],
            "verification-native-clock-mapping-differs")
    return dict(status="valid-verification-only-phase", qualifying=False,
        originalPayloadUnchanged=True, completeRowsStillRequired=True, action=value["contract"]["action"])


def validate_phase_cleanup(cleanup, phase, arm):
    controls = cleanup["controls"]
    require(type(controls) is list and 4 <= len(controls) <= 256
        and cleanup["status"] == "pass" and cleanup["pid"] == phase["workerPID"]
        and cleanup["nonce"] == phase["nonce"], "verification-cleanup-identity-differs")
    require(all(type(row) is dict and set(row) == {"op", "ticks"} and type(row["op"]) is str
                for row in controls), "verification-control-fields-differ")
    operations = [row for row in controls if row["op"] != "status"]
    require([row["op"] for row in operations] == ["drain", "verify-history", "arm", "finish"],
            "verification-control-order-or-count-differs")
    ticks = [integer(row["ticks"], positive=True) for row in controls]
    require(ticks == sorted(ticks) and operations[1]["ticks"] <= phase["startedTicks"]
        <= phase["finishedTicks"] <= operations[2]["ticks"] <= arm["armedTicks"]
        <= operations[3]["ticks"] <= integer(cleanup["finishedTicks"], positive=True),
        "verification-control-clock-order-differs")
    return dict(status="valid-verification-control-sequence", qualifying=False)
