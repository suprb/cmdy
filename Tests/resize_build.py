#!/usr/bin/env python3
"""Build the native resize observer and run only generated CPU tests."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from resize_oracle import make_oracle
from resize_calibration_evidence import validate_discovery

HERE = Path(__file__).resolve().parent
COMMON = ["BenchKernelAncestry.swift", "resize_action.swift", "resize_frame_observer.swift",
          "resize_generated.swift", "resize_calibration.swift"]
OBSERVER_SOURCES = COMMON + ["resize_observer.swift"]
TARGETS = [("resize-observer", OBSERVER_SOURCES, None),
           ("resize-matcher-tests", COMMON + ["test_resize_matcher.swift"], []),
           ("resize-calibration-tests", COMMON + ["test_resize_calibration.swift"], ["oracle.json", "calibration.json"])]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(output):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    sources = {name: sha(HERE / name) for name in sorted({name for _, names, _ in TARGETS for name in names}
               | {"resize_build.py", "resize_oracle.py", "resize_protocol.py", "resize_calibration_evidence.py"})}
    (output / "oracle.json").write_text(json.dumps(make_oracle(), indent=2, sort_keys=True) + "\n")
    record = {"status": "running", "startedUTC": datetime.now(timezone.utc).isoformat(),
              "nativeObservationRun": False, "sourceSHA256": sources, "commands": []}

    def save():
        (output / "results.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

    def run(name, command):
        log = output / (name + ".log")
        item = {"name": name, "arguments": command}
        record["commands"].append(item)
        with log.open("xb") as stream:
            child = subprocess.Popen(command, cwd=HERE, stdin=subprocess.DEVNULL,
                                     stdout=stream, stderr=subprocess.STDOUT)
            item["pid"] = child.pid; save()
            try:
                item["exitCode"] = child.wait(timeout=180)
            except subprocess.TimeoutExpired:
                child.kill(); item.update(exitCode=child.wait(), timedOut=True)
                raise
            finally:
                item.update(exitedAndReaped=child.returncode is not None, logSHA256=sha(log)); save()
        if item["exitCode"]:
            raise RuntimeError(name + " failed; see " + str(log))
        print("PASS " + name, flush=True)

    try:
        for name, names, arguments in TARGETS:
            binary = output / name
            command = ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library",
                       *(str(HERE / item) for item in names), "-o", str(binary)]
            run("build-" + name, command)
            manifest = {"command": command, "binarySHA256": sha(binary),
                        "nativeObservationRun": False,
                        "sourceSHA256": {item: sources[item] for item in names}}
            (output / (name + "-build.json")).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            if arguments is not None:
                run("check-" + name, [str(binary), *(str(output / item) for item in arguments)])
        calibration = json.loads((output / "calibration.json").read_text())
        for item in calibration: validate_discovery(item)
        record["independentNativeCalibrationPreimagesValidated"] = len(calibration)
        if not all(sha(HERE / name) == value for name, value in sources.items()):
            raise RuntimeError("resize source changed during compilation/tests")
        record.update(status="pass", sourcesUnchanged=True)
    except BaseException as error:
        record.update(status="failed", error=repr(error)); raise
    finally:
        record["finishedUTC"] = datetime.now(timezone.utc).isoformat(); save()
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output:
        print(build(args.output.resolve()))
    else:
        with tempfile.TemporaryDirectory(prefix="cmdy-resize-headless-") as root:
            build(Path(root) / "build")


if __name__ == "__main__": main()
