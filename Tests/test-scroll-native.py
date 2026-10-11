#!/usr/bin/env python3
"""Compile the scroll observer and run synthetic Swift checks without GUI access."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from scroll_protocol import viewport_sha256

HERE = Path(__file__).resolve().parent
COMMON = ["BenchKernelAncestry.swift", "ScrollNativeObservation.swift", "ScrollRaster.swift"]
RUNTIME = COMMON + ["ScrollWindowGeometry.swift", "ScrollObservationRuntime.swift"]
TARGETS = [
    ("matcher", COMMON + ["ScrollNativeMatcherTests.swift"], []),
    ("raster-clock", RUNTIME + ["ScrollNativeRasterTests.swift"], ["protocol-vectors.json"]),
    ("capture-status", COMMON + ["ScrollCaptureStatusTests.swift"], []),
    ("event-clock", RUNTIME + ["ScrollNativeEventClockTests.swift"], []),
    ("geometry", ["ScrollWindowGeometry.swift", "ScrollWindowGeometryTests.swift"], []),
    ("scroll-observer", RUNTIME + ["ScrollObserverMain.swift"], None),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(output):
    output.mkdir(parents=True, exist_ok=False)
    sources = {name: sha(HERE / name) for name in sorted(
        {name for _, names, _ in TARGETS for name in names} | {"scroll_protocol.py", Path(__file__).name})}
    token = "0123456789abcdef0123456789abcdef"
    (output / "protocol-vectors.json").write_text(json.dumps({"token": token,
        "viewportSHA256": {str(row): viewport_sha256(token, row) for row in (0, 900, 958, 964)}}))
    record = {"status": "running", "startedUTC": datetime.now(timezone.utc).isoformat(),
              "sourceSHA256": sources, "commands": [], "nativeObservationRun": False}

    def save():
        (output / "results.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

    def run(name, arguments):
        log = output / (name + ".log")
        row = {"name": name, "arguments": arguments}
        record["commands"].append(row)
        with log.open("xb") as stream:
            process = subprocess.Popen(arguments, cwd=HERE, stdin=subprocess.DEVNULL,
                                       stdout=stream, stderr=subprocess.STDOUT)
            row["pid"] = process.pid
            save()
            try:
                row["exitCode"] = process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                process.kill()
                row.update(exitCode=process.wait(), timedOut=True)
                raise
            finally:
                row.update(processExitedAndReaped=process.returncode is not None, logSHA256=sha(log))
                save()
        if row["exitCode"]:
            raise RuntimeError(f"{name} failed; see {log}")
        print(f"PASS {name}", flush=True)

    try:
        for name, names, arguments in TARGETS:
            binary = output / name
            run("build-" + name, ["xcrun", "swiftc", "-O", "-parse-as-library",
                *(str(HERE / item) for item in names), "-o", str(binary)])
            record.setdefault("binarySHA256", {})[name] = sha(binary)
            if arguments is not None:
                run("check-" + name, [str(binary), *(str(output / value) for value in arguments)])
        run("cgrect-encoding", ["xcrun", "swift", "-e",
            'import Foundation; import CoreGraphics; '
            'let data = try JSONEncoder().encode(CGRect(x:129,y:130,width:66,height:20)); '
            'let decoded = try JSONSerialization.jsonObject(with:data) as? [[Double]]; '
            'precondition(decoded == [[129,130],[66,20]]); print("PASS native CGRect Codable shape")'])
        record["sourcesUnchanged"] = all(sha(HERE / name) == value for name, value in sources.items())
        if not record["sourcesUnchanged"]:
            raise RuntimeError("scroll source changed during validation")
        record["status"] = "pass"
    except BaseException as error:
        record.update(status="failed", error=repr(error))
        raise
    finally:
        record["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        save()
    print("PASS synthetic scroll checks and observer compilation; no capture or event posting", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new directory for retained logs and compiled helpers")
    args = parser.parse_args()
    if args.output is not None:
        validate(args.output.expanduser().resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="cmdy-scroll-native-tests-") as temporary:
            validate(Path(temporary) / "validation")


if __name__ == "__main__":
    main()
