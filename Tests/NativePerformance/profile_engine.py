#!/usr/bin/env python3
"""Profile a frozen native PTY engine. These records never qualify performance."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import termios
import time
import uuid


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_inputs(root: Path, receipt: dict) -> None:
    require(receipt.get("status") == "complete" and receipt.get("diagnosticOnly") is True,
            "require a completed diagnostic probe build")
    for name, expected in receipt["inputs"].items():
        require(sha(root / name) == expected, "frozen input changed: " + name)
    require(sha(Path(receipt["binaryPath"])) == receipt["binarySHA256"], "probe binary changed")


def rpc(path: Path, value: dict, timeout: float = 15) -> dict:
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(timeout)
        connection.connect(str(path))
        connection.sendall(json.dumps(value).encode() + b"\n")
        data = bytearray()
        while not data.endswith(b"\n"):
            chunk = connection.recv(65536)
            if not chunk or len(data) + len(chunk) > 1_048_576:
                raise ValueError("worker closed connection or exceeded response limit")
            data.extend(chunk)
        result = json.loads(data)
        require(result.get("ok") is True, str(result))
        return result


def driver_request(process: subprocess.Popen, value: dict | None = None, timeout: float = 15) -> dict:
    if value is not None:
        process.stdin.write(json.dumps(value).encode() + b"\n")
        process.stdin.flush()
    deadline = time.monotonic() + timeout
    data = bytearray()
    while not data.endswith(b"\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
            raise TimeoutError("engine control response timed out")
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk or len(data) + len(chunk) > 1_048_576:
            raise ValueError("engine exited or exceeded response limit")
        data.extend(chunk)
    result = json.loads(data)
    if value is not None:
        require(result.get("ok") is True, str(result))
    return result


def validate_sample(record: dict, stats: dict, ready: dict, payload: bytes, sequence: int,
                    snapshots: bool = True) -> None:
    footer = bytes.fromhex(record["footerHex"])
    expected = bytes.fromhex(record["expectedResponseHex"])
    require(record["responseHex"] == expected.hex(), "incorrect DSR")
    require(record["elapsedNS"] > 0 and record["elapsedNS"] ==
            record["finishedMonotonicNS"] - record["startedMonotonicNS"], "invalid drain clock")
    require(record["gridBefore"] == record["gridAfter"] == ready["grid"], "PTY grid changed")
    require(record["payloadBytes"] == len(payload), "incomplete offered payload")
    require(stats["bytesReceived"] == len(payload) + len(footer), "incomplete received payload")
    require(sum(stats["chunkSizes"]) == stats["bytesReceived"] and
            all(1 <= value <= 65536 for value in stats["chunkSizes"]), "invalid read accounting")
    require(stats["contentChanges"] == len(stats["chunkSizes"]), "missing feed notification")
    require(stats["responseHexes"] == [expected.hex()], "duplicate or stale reply")
    require(stats["columns"] == 120 and stats["rows"] == 36 and stats["terminationCount"] == 0,
            "incorrect engine geometry or lifecycle")
    require(stats["cursorRow"] == 1 + sequence % 35 and stats["cursorColumn"] == 1 + sequence // 35 % 119,
            "incorrect engine cursor")
    require(stats["diagnosticsEnabled"] is False and stats["snapshotMode"] is snapshots,
            "incorrect diagnostic probe mode")
    captures = stats["snapshotCaptures"]
    require(type(captures) is int and 0 <= captures <= stats["contentChanges"]
            and (snapshots or captures == 0), "snapshot accounting differs from selected probe mode")
    if sequence == 0:
        require(stats["receivedSHA256"] == hashlib.sha256(payload + footer).hexdigest(),
                "stream checksum differs")
    else:
        require("receivedSHA256" not in stats, "full hashing enabled during profiling")


def profile(root: Path, output: Path, build: dict, workload: str, seconds: int, snapshots: bool = True) -> None:
    output.mkdir()
    fixture = output / "fixture"
    fixture.mkdir()
    sock = Path("/private/tmp") / ("cmdy-engine-" + uuid.uuid4().hex[:16] + ".sock")
    payload_path = root / (workload + ".bin")
    payload = payload_path.read_bytes()
    process = sampler = None
    errors = []
    receipt = {"workload": workload, "status": "running", "diagnosticOnly": True,
               "qualifying": False, "sampleSeconds": seconds, "sampleIntervalMilliseconds": 1,
               "snapshotMode": "on" if snapshots else "off",
               "profileScope": "PTY reads and native feed" + (" with probe-specific 1 ms immutable snapshot publication" if snapshots else " without snapshot publication"),
               "modelsNativeAppSnapshotScheduler": False}
    stderr = (output / "driver.stderr").open("xb")
    sample_log = (output / "sample.log").open("xb")
    try:
        verify_inputs(root, build)
        process = subprocess.Popen([build["binaryPath"], sys.executable, str(root / "engine_worker.py"),
                                    str(fixture), str(payload_path), str(sock), "serial-owner-reuse", "on" if snapshots else "off"],
                                   cwd=output, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                   bufsize=0, env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                                 "CMDY_PTY_DIAGNOSTICS": "0"})
        hello = driver_request(process)
        require(hello["snapshotMode"] is snapshots and hello["probeSnapshotCadenceMilliseconds"] == 1,
                "driver snapshot mode differs from requested diagnostic")
        receipt.update(driverPID=process.pid, workerPID=hello["childPID"], hello=hello)
        write(output / "profile.json", receipt)
        deadline = time.monotonic() + 10
        while not (fixture / "ready.json").exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise TimeoutError("PTY worker did not become ready")
            time.sleep(.01)
        ready = json.loads((fixture / "ready.json").read_text())
        require(ready["workerPID"] == hello["childPID"] and ready["parentPID"] == process.pid,
                "worker is not the owned direct child")
        require(ready["grid"]["columns"] == 120 and ready["grid"]["rows"] == 36, "wrong PTY grid")
        require(not (ready["ttyFlagsRaw"][1] & termios.OPOST), "PTY translates output")
        require(ready["payloadBytes"] == len(payload) == 3_000_000 and
                ready["payloadSHA256"] == hashlib.sha256(payload).hexdigest(), "worker payload changed")
        sampled = 0
        with (output / "drains.jsonl").open("x") as records:
            for sequence in range(10000):
                reset = rpc(sock, {"command": "reset", "timeout": 10})
                require(reset["responseHex"] == b"\x1b[1;1R".hex() and reset["grid"] == ready["grid"],
                        "reset not complete before feed window")
                driver_request(process, {"command": "begin", "validation": sequence == 0})
                if sequence == 2:
                    command = ["/usr/bin/sample", str(process.pid), str(seconds), "1", "-file",
                               str(output / "sample.txt")]
                    sampler = subprocess.Popen(command, stdout=sample_log, stderr=subprocess.STDOUT)
                    receipt.update(samplerPID=sampler.pid, sampleCommand=command)
                    write(output / "profile.json", receipt)
                record = rpc(sock, {"command": "drain", "sequence": sequence, "timeout": 10, "skipReset": True})
                stats = driver_request(process, {"command": "stats"})["stats"]
                validate_sample(record, stats, ready, payload, sequence, snapshots)
                record.update(kind="validation" if sequence == 0 else "warmup" if sequence == 1 else "profiled",
                              diagnosticOnly=True, qualifying=False, engine=stats)
                records.write(json.dumps(record, sort_keys=True) + "\n")
                if sequence >= 2:
                    sampled += 1
                    if sampler.poll() is not None:
                        require(sampler.returncode == 0, "sampler failed")
                        break
            else:
                raise TimeoutError("sampler exceeded the bounded drain count")
        require(sampler is not None and sampler.wait(timeout=5) == 0, "sampler did not finish")
        rpc(sock, {"command": "quit"})
        finish = driver_request(process, {"command": "finish"}, timeout=8)
        write(output / "finish.json", finish)
        require(finish["descriptorClosed"] and finish["stats"]["terminationCount"] == 1 and
                finish["stats"]["exitCode"] == 0, "PTY cleanup not complete")
        require(process.wait(timeout=5) == 0, "probe exited unsuccessfully")
        verify_inputs(root, build)
        receipt.update(status="complete", profiledDrains=sampled, sampleSHA256=sha(output / "sample.txt"),
                       drainsSHA256=sha(output / "drains.jsonl"), allBytesAndDSRValidated=True)
    except BaseException as error:
        receipt.update(status="failed_with_evidence_preserved", error=repr(error))
        raise
    finally:
        if sampler is not None and sampler.poll() is None:
            sampler.kill()
            sampler.wait()
        if process is not None and process.poll() is None:
            try:
                if sock.exists():
                    rpc(sock, {"command": "quit"}, timeout=2)
                driver_request(process, {"command": "finish"}, timeout=8)
                process.wait(timeout=5)
            except Exception as error:
                errors.append(repr(error))
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for pipe in (process.stdin, process.stdout) if process is not None else ():
            if pipe and not pipe.closed:
                pipe.close()
        stderr.close()
        sample_log.close()
        sock.unlink(missing_ok=True)
        receipt["cleanup"] = {"driverExitCode": process.returncode if process else None,
                              "samplerExitCode": sampler.returncode if sampler else None, "errors": errors}
        write(output / "profile.json", receipt)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workloads", nargs="+", default=["unicode", "source", "styled"])
    parser.add_argument("--seconds", type=int, default=5)
    parser.add_argument("--snapshots", choices=("on", "off"), default="on",
                        help="probe-specific 1 ms snapshot toggle; does not model the app renderer scheduler")
    args = parser.parse_args()
    root, output = args.probe.resolve(), args.output.resolve()
    build_path = root / "probe-build.json"
    build = json.loads(build_path.read_text())
    verify_inputs(root, build)
    if not 1 <= args.seconds <= 10 or len(set(args.workloads)) != len(args.workloads):
        parser.error("use one through ten seconds and distinct workloads")
    if any(workload not in build["workloads"] for workload in args.workloads):
        parser.error("unknown corpus workload")
    output.mkdir(parents=True, exist_ok=False)
    command = ["/bin/ps", "-axo", "pid,ppid,%cpu,comm"]
    (output / "processes-before.txt").write_bytes(subprocess.check_output(command))
    (output / "power-before.txt").write_bytes(subprocess.check_output(["/usr/bin/pmset", "-g", "batt"]))
    receipt = {"schemaVersion": 1, "status": "running", "diagnosticOnly": True, "qualifying": False,
               "probeBuildSHA256": sha(build_path), "workloads": args.workloads, "snapshotMode": args.snapshots,
               "modelsNativeAppSnapshotScheduler": False,
               "harnessSHA256": sha(Path(__file__)), "loadBefore": os.getloadavg(),
               "limitations": ["No Ghostty or renderer timing; sampling and background work affect durations"]}
    try:
        for workload in args.workloads:
            profile(root, output / workload, build, workload, args.seconds, args.snapshots == "on")
            print("PROFILED " + workload, flush=True)
        require(sha(build_path) == receipt["probeBuildSHA256"], "build receipt changed")
        receipt["status"] = "complete"
    except BaseException as error:
        receipt.update(status="failed_with_evidence_preserved", error=repr(error))
        raise
    finally:
        (output / "processes-after.txt").write_bytes(subprocess.check_output(command))
        (output / "power-after.txt").write_bytes(subprocess.check_output(["/usr/bin/pmset", "-g", "batt"]))
        receipt["loadAfter"] = os.getloadavg()
        write(output / "profiles.json", receipt)


if __name__ == "__main__":
    main()
