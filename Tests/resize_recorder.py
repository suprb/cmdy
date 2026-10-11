#!/usr/bin/env python3
"""Bounded recorder for one diagnostic resize on an already owned prepared app.

No app launch, activation, calibration fitting or qualification is implicit.
The native observer is a separately built helper. This tool is not a parity run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import time

from resize_contract import blocked_status, require_qualifying_adapter
from resize_calibration_evidence import validate_discovery
from resize_controller import METRIC, expected_event, worker_request
from resize_evidence import validate_document
from resize_protocol import check_nonce, growth_guard_enabled
from resize_worker import atomic_json

HERE = Path(__file__).resolve().parent


def require(condition, message):
    if not condition: raise RuntimeError(message)


class Native:
    def __init__(self, executable, run, spec):
        self.directory = run / "native"; self.directory.mkdir(mode=0o700)
        self.spec = spec
        atomic_json(self.directory / "spec.json", spec)
        self.log = (self.directory / "stderr.log").open("wb")
        try:
            self.process = subprocess.Popen([str(executable), "--spec", str(self.directory / "spec.json")],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, bufsize=0)
        except Exception:
            self.log.close()
            raise
        self.buffer = bytearray(); self.records = []; self.next_id = 0
        try:
            self.started = self.read(8)
            require(self.started.get("ok") and self.started.get("op") == "started", "native stream did not start")
        except Exception:
            self.close(False)
            raise

    def read(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" in self.buffer:
                line, _, rest = self.buffer.partition(b"\n"); self.buffer = bytearray(rest)
                value = json.loads(line)
                self.records.append(value)
                # Called only before/after the native event endpoint; no
                # filesystem write is made while waiting for a timed frame.
                atomic_json(self.directory / f"{len(self.records):04d}.json", value)
                return value
            if not select.select([self.process.stdout], [], [], max(0, min(.1, deadline - time.monotonic())))[0]:
                continue
            data = os.read(self.process.stdout.fileno(), 65536)
            require(bool(data), "native observer closed its result pipe")
            self.buffer.extend(data)
            require(len(self.buffer) <= 4 * 1024 * 1024, "native result exceeds metadata bound")
        raise TimeoutError("native response deadline exceeded")

    def request(self, operation, timeout=6, **fields):
        request = dict(op=operation, **fields)
        payload = json.dumps(request, separators=(",", ":")).encode() + b"\n"
        require(len(payload) <= 512 * 1024, "native request exceeds bound")
        self.process.stdin.write(payload)
        result = self.read(timeout)
        require(result.get("ok") is True, "native request failed: " + str(result.get("error", result)))
        expected_op = {"arm": "armed", "go": "complete", "finish": "finished"}.get(operation, operation)
        require(result.get("op") == expected_op, "native response operation differs")
        if "sequence" in fields and operation != "discover":
            require(result.get("sequence") == fields["sequence"], "native response sequence differs")
        return result

    def close(self, success):
        receipt = {"ownedPID": self.process.pid, "successfulBlock": success}
        try:
            if self.process.poll() is None:
                if success:
                    result = self.request("finish")
                    require(result.get("op") == "finished", "native stream did not finish")
                else:
                    self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception as error:
            receipt["error"] = str(error)
            if self.process.poll() is None:
                self.process.terminate()
                try: self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill(); self.process.wait(timeout=2)
        finally:
            receipt["returncode"] = self.process.returncode
            receipt["exited"] = self.process.poll() is not None
            for stream in (self.process.stdin, self.process.stdout):
                if stream is not None: stream.close()
            receipt["pipesClosed"] = self.process.stdin.closed and self.process.stdout.closed
            self.log.close()
            atomic_json(self.directory / "cleanup.json", receipt)
        require(receipt["exited"] and (not success or receipt["returncode"] == 0), "native observer cleanup failed")



def validate_build(executable, manifest):
    build = json.loads(manifest.read_text())
    require(build["nativeObservationRun"] is False, "build must be an explicit compile-only record")
    require(build["binarySHA256"] == hashlib.sha256(executable.read_bytes()).hexdigest(),
            "native executable differs from the compiled observer")
    from resize_build import OBSERVER_SOURCES
    require(set(build["sourceSHA256"]) == set(OBSERVER_SOURCES), "observer source inventory differs")
    for name, expected in build["sourceSHA256"].items():
        require(hashlib.sha256((HERE / name).read_bytes()).hexdigest() == expected,
                "observer source changed since build: " + name)
    return build


def record_diagnostic(executable, manifest, request, output):
    """The caller owns the prepared app/worker; this function owns only its child."""
    require(request["schemaVersion"] == 1 and request["qualifying"] is False,
            "explicit diagnostic request required")
    check_nonce(request["nonce"])
    guarded = growth_guard_enabled(request)
    require(guarded == growth_guard_enabled(request["workerReady"]), "worker repaint history guard differs")
    require(request["nativeSpec"]["nonce"] == request["nonce"], "worker/frame nonce differs")
    require(request["nativeSpec"]["workerPID"] == request["workerReady"]["pid"]
            and request["nativeSpec"]["ttyPath"] == request["workerReady"]["ttyPath"],
            "worker PID or PTY binding differs")
    build = validate_build(executable, manifest)
    require(validate_discovery(request["sourceDiscovery"]) == request["source"]
            and validate_discovery(request["targetDiscovery"]) == request["target"],
            "exact native calibration discoveries are required")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    atomic_json(output / "request.json", request)
    atomic_json(output / "observer-build.json", build)
    native = None
    result = {"schemaVersion": 1, "case": "resize", "qualifying": False,
              "workerAndAppCleanupOwnedByCaller": True, "status": "failed"}
    success = False
    try:
        native = Native(executable, output, request["nativeSpec"])
        source, target, planned = request["source"], request["target"], request["planned"]
        require(native.started["initialTTYGrid"] == {"columns": source["columns"], "rows": source["rows"]},
                "prepared source real TTY grid differs")
        # Bind both discoveries to this live process/window/capture before any
        # arm or AX action. A self-consistent discovery from another run is not
        # authority to reuse its geometry or display timing configuration.
        validate_discovery(request["sourceDiscovery"], native.started)
        validate_discovery(request["targetDiscovery"], native.started)
        # Starting the stream does not imply its first source pixels arrived.
        # Wait for those exact pixels before arm requires lastPixels to exist.
        native.request("verify", sequence=request["sourceSequence"], calibration=source)
        native.request("arm", sequence=planned["sequence"], sourceSequence=request["sourceSequence"],
                       calibration=target, sourceCalibration=source)
        armed = worker_request(request["workerReady"], request["workerCapability"], "arm",
            sequence=planned["sequence"], grid={"columns": planned["columns"], "rows": planned["rows"]})
        atomic_json(output / "worker-arm.json", armed)
        # The following pipe operation does not timestamp the event. Only
        # native AXSize and WindowServer display ticks establish its endpoint.
        observed = native.request("go", sequence=planned["sequence"])
        # All subsequent control/status calls are after native observation.
        status = worker_request(request["workerReady"], request["workerCapability"], "status")
        atomic_json(output / "worker-status.json", status)
        candidates = [item for item in status["events"] if item["sequence"] == planned["sequence"]]
        require(len(candidates) == 1, "exact single worker event receipt missing")
        document = {"schemaVersion": 1, "case": "resize", "qualifying": False, "metric": METRIC,
                    "nonce": request["nonce"], "planned": planned, "display": native.started,
                    "source": source, "target": target,
                    "sourceDiscovery": request["sourceDiscovery"], "targetDiscovery": request["targetDiscovery"],
                    "entry": {"expected": expected_event(request["nonce"], planned, history_growth_guard=guarded), "arm": armed,
                              "worker": candidates[0], "observer": observed}}
        if guarded: document["historyGrowthGuardRows"] = 4
        atomic_json(output / "event.json", document)
        result.update(validate_document(document), status="diagnostic-only")
        success = True
    except BaseException as error:
        result["error"] = repr(error)
        raise
    finally:
        try:
            if native is not None: native.close(success)
        except BaseException as error:
            result.update(status="failed", diagnosticValid=False, cleanupError=repr(error))
            raise
        finally:
            atomic_json(output / "result.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--qualify", action="store_true")
    parser.add_argument("--record-diagnostic", type=Path)
    parser.add_argument("--observer", type=Path)
    parser.add_argument("--observer-build", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if args.status or not (args.qualify or args.record_diagnostic):
        print(json.dumps(blocked_status(), indent=2, sort_keys=True)); return 0
    try:
        if args.qualify: require_qualifying_adapter()
        require(args.observer is not None and args.observer_build is not None and args.output is not None,
                "diagnostic recorder requires separately built observer, build record and new output")
        require(args.record_diagnostic.stat().st_size <= 512 * 1024, "request exceeds metadata bound")
        result = record_diagnostic(args.observer.resolve(), args.observer_build.resolve(),
            json.loads(args.record_diagnostic.read_text()), args.output.resolve())
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (ValueError, RuntimeError, KeyError, TypeError, OSError) as error:
        print(json.dumps({**blocked_status(), "error": str(error)}, indent=2, sort_keys=True)); return 2


if __name__ == "__main__": raise SystemExit(main())
