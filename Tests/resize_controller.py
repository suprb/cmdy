#!/usr/bin/env python3
"""Pure resize plan and receipt helpers. Whole-batch admission is blocked."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import secrets
import socket

from resize_protocol import (GRIDS, digest, frame_bytes, history, row_word,
                             sequence_plan, check_nonce, cell_classes_bytes, FIXTURE_VERSION)

HERE = Path(__file__).resolve().parent
METRIC = "one-native-AX-size-request-to-first-complete-generated-cell-viewport-v2"
INTENDED_METRIC = "one-native-AX-size-request-to-first-complete-generated-cell-viewport-v2"
GAPS = (
    "complete native campaigns with explicitly bound four-row history growth protection in both apps",
    "complete six-pair native validation in both profiles and public gate integration",
)


def worker_request(ready: dict, capability: str, operation: str, **fields) -> dict:
    """Only outside metric timing; neither ACK nor status establishes a frame."""
    check_nonce(capability)
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2)
        connection.connect(ready["socketPath"])
        connection.sendall(json.dumps(dict(op=operation, capability=capability,
                                          **fields)).encode() + b"\n")
        response = bytearray()
        while not response.endswith(b"\n"):
            chunk = connection.recv(8192)
            if not chunk or len(response) + len(chunk) > 256 * 1024:
                raise RuntimeError("fixture response is incomplete or exceeds bound")
            response.extend(chunk)
    result = json.loads(response)
    if (result.get("ok") is not True or result.get("pid") != ready["pid"]
            or result.get("capability") != capability or result.get("error")):
        raise RuntimeError("wrong fixture identity or failed control operation")
    return result


def expected_event(nonce: str, event: dict, *, history_growth_guard=False) -> dict:
    payload = frame_bytes(nonce, event["sequence"], event["columns"], event["rows"], history_growth_guard=history_growth_guard)
    value = {**event, "fixtureVersion": FIXTURE_VERSION, "nonce": nonce,
            "cellClassesSHA256": digest(cell_classes_bytes(nonce, event["sequence"], event["columns"], event["rows"])), "payloadBytes": len(payload),
            "payloadSHA256": digest(payload),
            "words": [row_word(nonce, event["sequence"], event["columns"], event["rows"], row)
                      for row in range(event["rows"])],
            "postStabilityGapMS": (70, 83, 109, 127, 97)[event["sequence"] % 5]}
    if history_growth_guard: value["historyGrowthGuardRows"] = 4
    return value


def check_event_join(expected: dict, worker: dict, observer: dict) -> None:
    """Join independent receipts; this is additional proof, never the endpoint."""
    if worker.get("sequence") != expected["sequence"] or observer.get("sequence") != expected["sequence"]:
        raise ValueError("worker/observer sequence differs")
    target = dict(columns=expected["columns"], rows=expected["rows"])
    if worker.get("grid") != target or observer.get("finalTTYGrid") != target:
        raise ValueError("native TTY target differs")
    if (worker.get("completedBytes") != expected["payloadBytes"]
            or worker.get("offeredBytes") != expected["payloadBytes"]
            or worker.get("payloadSHA256") != expected["payloadSHA256"]):
        raise ValueError("worker repaint bytes differ")
    if not worker.get("signalCounter", -1) > worker.get("armSignalCounter", -1):
        raise ValueError("no actual new SIGWINCH authorized this repaint")
    action = observer["action"]
    first = observer["firstCompleteFrame"]
    ordered = (worker["armedTicks"], action["beforeTicks"], worker["signalReceivedTicks"],
               worker["observedTicks"], worker["startedTicks"], first["displayTicks"])
    if list(ordered) != sorted(ordered):
        raise ValueError("arm/request/signal/ioctl/paint/frame causality differs")
    if action["afterTicks"] < action["beforeTicks"] or action["axCallCount"] != 1 or action["axResult"] != 0:
        raise ValueError("native event did not contain one successful size action")
    # PTY write may return after pixels are already processed; completedTicks
    # is not required to precede displayTime and is never a latency endpoint.
    if (first.get("complete") is not True or first.get("matchedRows") != expected["rows"]
            or first.get("words") != expected["words"]
            or observer.get("stableAfterFirst") is not True
            or observer.get("ownershipValid") is not True
            or observer.get("signedClockValid") is not True
            or observer.get("observerFailures") != []):
        raise ValueError("first-frame/stability/ownership/clock proof is incomplete")


def prepare_plan(output: Path, profile: str, nonce: str | None = None) -> dict:
    nonce = check_nonce(nonce or secrets.token_hex(16))
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    corpus = history(nonce)
    (output / "history.bin").write_bytes(corpus)
    plan = {"schemaVersion": 1, "fixtureVersion": FIXTURE_VERSION, "case": "resize", "kind": "input", "metric": METRIC,
            "status": "blocked", "nativeReady": False, "qualifying": False,
            "intendedMetric": INTENDED_METRIC, "profile": profile,
            "nonce": nonce, "font": {"family": "Menlo", "style": "Regular", "points": 14},
            "initialGrid": dict(zip(("columns", "rows"), GRIDS[0])),
            "history": {"logicalRows": 1000, "bytesPerLogicalRowWithCRLF": 147,
                        "bytes": len(corpus), "sha256": digest(corpus), "separatorCRLFCount": 36,
                        "screen": "primary", "retentionValidated": False},
            "blocks": [{"block": block,
                        "order": ["cmdy", "ghostty"] if block % 2 == 0 else ["ghostty", "cmdy"],
                        "events": [expected_event(nonce, event) for event in sequence_plan(block)]}
                       for block in range(6)],
            "eventTimeoutSeconds": 3, "stabilityMilliseconds": 50,
            "workerTimeoutSeconds": 180, "gaps": list(GAPS)}
    (output / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    return plan


# The future paired controller must use the shared isolated public-window
# launcher and unchanged six-block / two-warmup / forty-measured workload.
# Standalone history/viewport export passed; timed-batch integration and native calibration remain unresolved;
# see TERMINAL-RESIZE-BENCHMARKS.md. No pure receipt can assert them. This file
# creates plans only; resize_recorder.py records explicitly diagnostic events.


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", type=Path)
    parser.add_argument("--profile", choices=("matched", "cmdy-defaults"), default="matched")
    parser.add_argument("--nonce")
    args = parser.parse_args(argv)
    if args.prepare is None:
        parser.error("this pure plan tool requires --prepare; native diagnostics are separate; qualification remains blocked")
    plan = prepare_plan(args.prepare, args.profile, args.nonce)
    print(json.dumps({"status": plan["status"], "nativeReady": False,
                      "measuredEventsPerApp": 240, "warmupEventsPerApp": 12,
                      "output": str(args.prepare), "gaps": plan["gaps"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
