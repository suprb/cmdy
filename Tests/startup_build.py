#!/usr/bin/env python3
"""Compile startup capture, run generated tests; never run the native recorder."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from startup_grid_evidence import validate_proof

HERE=Path(__file__).resolve().parent
COMMON=["BenchKernelAncestry.swift","ScrollWindowGeometry.swift","resize_action.swift","resize_frame_observer.swift","resize_generated.swift",
        "startup_grid.swift","startup_state.swift"]
OBSERVER_SOURCES=COMMON+["startup_native.swift"]
PYTHON_SOURCES=["startup_build.py","startup_grid.py","startup_grid_evidence.py","startup_evidence.py",
    "startup_recorder.py","startup_fixture.py","startup_evidence_tests.py","startup_worker_tests.py",
    "bench_ancestry.py","resize_calibration_evidence.py","resize_protocol.py","competitive_bench.py","terminal_bench_worker.py",
    "startup_target_trace.py"]

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def passing_python_count(log):
    # unittest spells real skips in its final "OK (skipped=N)" summary. A
    # passing test name may contain "skipped" (for example a rejected target).
    match=re.search(r"\nRan ([1-9][0-9]*) tests? in [^\n]+\n\s*OK\s*$",log)
    if not match:raise RuntimeError("startup Python tests skipped, failed or incomplete")
    return int(match[1])

def build(output):
    output.mkdir(mode=0o700,parents=True,exist_ok=False)
    names=sorted(set(OBSERVER_SOURCES+PYTHON_SOURCES+["startup_tests.swift","startup_state_tests.swift","TERMINAL-STARTUP-BENCHMARKS.md","parity-policy.json"]))
    record=dict(schemaVersion=1,status="running",qualifying=False,nativeObservationRun=False,applicationLaunches=0,
        sourceSHA256={name:sha(HERE/name) for name in names},commands=[])
    tooling=output/"tooling";tooling.mkdir(mode=0o700)
    for name in names:shutil.copy2(HERE/name,tooling/name)
    if any(sha(tooling/n)!=h for n,h in record["sourceSHA256"].items()):raise RuntimeError("startup source changed during freeze")
    def save():(output/"results.json").write_text(json.dumps(record,indent=2,sort_keys=True)+"\n")
    def run(name,argv,env=None,cwd=None):
        item=dict(name=name,arguments=argv);record["commands"].append(item);save()
        with (output/f"{name}.log").open("xb") as log:
            child=subprocess.Popen(argv,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,env=env,cwd=cwd)
            item["pid"]=child.pid
            try:item["exitCode"]=child.wait(timeout=180)
            except subprocess.TimeoutExpired:child.kill();item["exitCode"]=child.wait();raise
            finally:item["exitedAndReaped"]=child.returncode is not None;item["logSHA256"]=sha(output/f"{name}.log");save()
        if item["exitCode"]:raise RuntimeError(name+" failed; inspect preserved log")
    try:
        run("compiler-version",["/usr/bin/xcrun","swiftc","--version"])
        run("sdk-identity",["/usr/bin/xcrun","--sdk","macosx","--show-sdk-path"])
        for name,sources in (("startup-observer",OBSERVER_SOURCES),("startup-tests",COMMON+["startup_tests.swift","startup_state_tests.swift"])):
            argv=["/usr/bin/xcrun","swiftc","-O","-parse-as-library",*(str(tooling/n) for n in sources),"-o",str(output/name)]
            run("build-"+name,argv)
            (output/f"{name}-build.json").write_text(json.dumps(dict(nativeObservationRun=False,headlessQualified=False,
                binarySHA256=sha(output/name),sourceSHA256={n:record["sourceSHA256"][n] for n in sources},
                toolingSHA256=record["sourceSHA256"],command=argv),indent=2,sort_keys=True)+"\n")
        run("generated-startup-tests",[str(output/"startup-tests"),"--proof-output",str(output/"generated-proof.json")])
        validate_proof(json.loads((output/"generated-proof.json").read_text()),"0123456789abcdef0123456789abcdef")
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE="1",PYTHONPATH=str(tooling),STARTUP_NATIVE_TEST_PROOF=str(output/"generated-proof.json"),
            STARTUP_PTY_TEST_OUTPUT=str(output/"owned-pty"),STARTUP_GENERATED_RAW_OUTPUT=str(output/"generated-raw"))
        run("python-negative-and-pty-tests",[sys.executable,"-B","-m","unittest","-v","startup_evidence_tests","startup_worker_tests"],env,tooling)
        python_log=(output/"python-negative-and-pty-tests.log").read_text()
        record["pythonTests"]=passing_python_count(python_log)
        record["swiftChecks"]=json.loads((output/"generated-startup-tests.log").read_text().splitlines()[-1])["syntheticGridChecks"]
        if any(sha(HERE/n)!=h for n,h in record["sourceSHA256"].items()):raise RuntimeError("startup source changed during tests")
        if any(sha(tooling/n)!=h for n,h in record["sourceSHA256"].items()):raise RuntimeError("frozen source changed during tests")
        for name in ("startup-observer","startup-tests"):
            path=output/f"{name}-build.json";receipt=json.loads(path.read_text());receipt["headlessQualified"]=True
            path.write_text(json.dumps(receipt,indent=2,sort_keys=True)+"\n")
        record.update(status="pass",sourcesUnchanged=True,nativePythonPixelProofAgrees=True,pythonRuntimeSHA256=sha(Path(sys.executable).resolve()),
            observerSHA256=sha(output/"startup-observer"),policyUnchangedSHA256=sha(HERE/"parity-policy.json"))
    except BaseException as error:record.update(status="failed",error=repr(error));raise
    finally:save()
    return record

if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--output",required=True,type=Path)
    args=parser.parse_args();print(json.dumps(build(args.output.resolve()),indent=2,sort_keys=True))
