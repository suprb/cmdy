#!/usr/bin/env python3
"""Compile the public export helper without executing any native mode."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

from history_export_protocol import digest, require

HERE = Path(__file__).resolve().parent
SOURCES = ("BenchKernelAncestry.swift", "resize_action.swift", "history_export_scope.swift", "history_export_key.swift", "resize_frame_observer.swift",
           "resize_generated.swift", "resize_calibration.swift", "history_export_native.swift")
PUBLIC_TOOLING = SOURCES + ("history_export_build.py", "history_export_protocol.py", "history_export_binding.py", "history_export_files.py",
    "history_export_phase.py",
    "history_export_worker.py", "history_export_controller.py", "history_export_evidence.py",
    "bench_ancestry.py", "memory_bench_payloads.py", "resize_protocol.py", "resize_calibration_evidence.py",
    "terminal_bench_worker.py")


def build(output):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    hashes = {name: digest((HERE / name).read_bytes()) for name in PUBLIC_TOOLING}
    binary = output / "history-export-native"
    argv = ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", *(str(HERE / name) for name in SOURCES), "-o", str(binary)]
    with (output / "compile.log").open("xb") as log:
        process = subprocess.Popen(argv, cwd=HERE, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try: code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            process.kill(); code = process.wait()
    value = dict(status="pass" if code == 0 else "failed", command=argv, pid=process.pid,
                 exitCode=code, reaped=True, nativeObservationRun=False, nativeHelperExecuted=False,
                 sourceSHA256={name: hashes[name] for name in SOURCES}, toolingSHA256=hashes,
                 logSHA256=digest((output / "compile.log").read_bytes()))
    if code == 0: value["binarySHA256"] = digest(binary.read_bytes())
    value["sourcesUnchanged"] = all(digest((HERE / name).read_bytes()) == checksum for name, checksum in hashes.items())
    (output / "build.json").write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    require(code == 0 and value["sourcesUnchanged"], "native-helper-build-failed-see-retained-log")
    return value


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument("--output", type=Path, required=True)
    print(json.dumps(build(parser.parse_args().output), indent=2, sort_keys=True))
