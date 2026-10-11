#!/usr/bin/env python3
"""Compile paste recorder and run only synthetic pixels/descriptor checks."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from paste_protocol import expected_receipt, viewport_sha256

HERE = Path(__file__).resolve().parent
COMMON = ["BenchKernelAncestry.swift", "ScrollNativeObservation.swift", "ScrollRaster.swift",
          "ScrollWindowGeometry.swift", "ScrollObservationRuntime.swift", "paste_raster.swift",
          "paste_observation.swift", "paste_apple_event.swift"]
OBSERVER_SOURCES = COMMON + ["paste_observer.swift"]
TEST_SOURCES = COMMON + ["test_paste_native.swift"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(output):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    source_dir = output / "sources"; source_dir.mkdir()
    names = sorted(set(OBSERVER_SOURCES + TEST_SOURCES + ["paste_build.py", "paste_protocol.py", "scroll_protocol.py"]))
    sources = {name: sha(HERE / name) for name in names}
    for name in names:
        shutil.copy2(HERE / name, source_dir / name)
    token = "0123456789abcdef0123456789abcdef"
    (output / "vectors.json").write_text(json.dumps({"token": token,
        "viewportSHA256": {str(row): viewport_sha256(token, row) for row in (0, 900, 958, 964)},
        "payloadSHA256": {str(row): expected_receipt(token, row)["payloadSHA256"] for row in (0, 1, 2, 42)}}))
    record = {"status": "running", "startedUTC": datetime.now(timezone.utc).isoformat(),
              "nativeObservationRun": False, "appleEventsSent": False, "permissionQueriesRun": False,
              "sourceSHA256": sources, "commands": []}

    def save():
        (output / "results.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

    def run(name, command):
        log = output / (name + ".log")
        row = {"name": name, "arguments": command}; record["commands"].append(row)
        with log.open("xb") as stream:
            child = subprocess.Popen(command, cwd=source_dir, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
            row["pid"] = child.pid; save()
            try:
                row["exitCode"] = child.wait(timeout=180)
            except subprocess.TimeoutExpired:
                child.kill(); row.update(exitCode=child.wait(), timedOut=True); raise
            finally:
                row.update(exitedAndReaped=child.returncode is not None, logSHA256=sha(log)); save()
        if row["exitCode"]:
            raise RuntimeError(name + " failed; see " + str(log))
        print("PASS " + name, flush=True)

    try:
        for name, files in (("paste-observer", OBSERVER_SOURCES), ("paste-native-tests", TEST_SOURCES)):
            binary = output / name
            command = ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5",
                       *(str(source_dir / item) for item in files), "-o", str(binary)]
            run("build-" + name, command)
            manifest = {"command": command, "binarySHA256": sha(binary), "nativeObservationRun": False,
                        "sourceSHA256": {item: sources[item] for item in files}}
            (output / (name + "-build.json")).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        run("check-paste-native", [str(output / "paste-native-tests"), str(output / "vectors.json")])
        if not all(sha(HERE / name) == value == sha(source_dir / name) for name, value in sources.items()):
            raise RuntimeError("paste sources changed during compilation/tests")
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
        with tempfile.TemporaryDirectory(prefix="cmdy-paste-headless-") as root:
            build(Path(root) / "build")


if __name__ == "__main__":
    main()
