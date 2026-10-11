#!/usr/bin/env python3
"""Prepare isolated inputs or record one explicitly requested startup diagnostic."""
from __future__ import annotations
import argparse
import ctypes
import hashlib
import json
import os
import plistlib
import re
from pathlib import Path
from startup_grid_evidence import FOREGROUND_METHOD
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid
from competitive_bench import BenchOptions, launch_environment, terminal_config
from startup_evidence import BLOCKER, validate
from startup_grid import Witness
from resize_calibration_evidence import validate_display_mode

HERE = Path(__file__).resolve().parent
PREPARATION_SOURCES=("startup_recorder.py","startup_fixture.py","startup_grid.py","competitive_bench.py",
    "terminal_bench_worker.py","startup_evidence.py","startup_grid_evidence.py","bench_ancestry.py",
    "resize_calibration_evidence.py","resize_protocol.py","startup_build.py","startup_target_trace.py")

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def require(value, message):
    if not value: raise ValueError(message)
def write(path, value):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,"w") as stream: json.dump(value,stream,indent=2,sort_keys=True);stream.write("\n")

def native_python_executable():
    # Framework Python's bin/python3 launcher execs Python.app. Pin and launch
    # the actual kernel-observed interpreter so readiness and native ownership
    # prove the same executable, not two different files with related names.
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    require(library.proc_pidpath(os.getpid(), buffer, len(buffer)) > 0, 'native Python executable unavailable')
    path = Path(os.fsdecode(buffer.value)).resolve()
    require(path.is_file(), 'native Python executable missing')
    return path

def prepare(directory, terminal, executable, display, profile="matched", token=None, target_grid=(98,29)):
    require(terminal in ("cmdy","ghostty") and profile in ("matched","cmdy-defaults"),"unsupported startup profile")
    token=token or uuid.uuid4().hex
    require(isinstance(target_grid,(tuple,list)) and len(target_grid)==2,"startup target grid missing")
    Witness(token,*target_grid,1,1).validate()
    validate_display_mode(display["displayMode"])
    require(display["thermalState"]==0 and type(display["lowPowerMode"]) is bool,"native display/condition probe required")
    executable=executable.resolve();require(executable.is_file(),"startup executable missing")
    directory=directory.resolve();directory.mkdir(mode=0o700,parents=True,exist_ok=False)
    for name in ("worker","tooling","work","zsh","cmdy-config","xdg-config","xdg-data","xdg-cache","xdg-state"):
        (directory/name).mkdir(mode=0o700)
    (directory/"cmdy-config/extensions").mkdir(mode=0o700)
    for name in ("startup_fixture.py","startup_grid.py"):shutil.copy2(HERE/name,directory/"tooling"/name)
    python=native_python_executable()
    command=[str(python),"-B",str(directory/"tooling/startup_fixture.py"),"--directory",str(directory/"worker"),"--token",token,"--timeout","25",
        "--columns",str(target_grid[0]),"--rows",str(target_grid[1])]
    (directory/"zsh/.zshenv").write_text("unsetopt RCS\nexec "+shlex.join(command)+"\n")
    options=BenchOptions(executable,executable,profile=profile,font_size=14)
    # Preserved request mapping, pending a fresh live pilot for each target.
    # It is never corrected by resizing or choosing a later observed frame.
    config=terminal_config(terminal,options,(target_grid[0]-2,target_grid[1]-1) if terminal=="ghostty" else None,directory/"work")
    config_path=directory/("ghostty.config" if terminal=="ghostty" else "cmdy-config/config")
    config_path.write_text(config)
    write(directory/"cmdy-config/app-update-state.json",{"lastCheck":time.time()})
    environment=launch_environment(dict(os.environ),directory,directory/"work","com.cmdy.startup."+uuid.uuid4().hex)
    arguments=[] if terminal=="cmdy" else ["--config-default-files=false",f"--config-file={config_path}"]
    inputs=[directory/"tooling/startup_fixture.py",directory/"tooling/startup_grid.py",directory/"zsh/.zshenv",config_path,directory/"cmdy-config/app-update-state.json"]
    spec=dict(schemaVersion=1,qualifying=False,token=token,targetGrid=list(target_grid),captureShowsCursor=False,
        foregroundMethod=FOREGROUND_METHOD,
        executable=str(executable),executableSHA256=sha(executable),
        arguments=arguments,environment=environment,cwd=str(directory/"work"),appLog=str(directory/"app.log"),
        workerDirectory=str(directory/"worker"),workerExecutable=str(python),workerExecutableSHA256=sha(python),
        inputFiles={str(p):sha(p) for p in inputs},**{k:display[k] for k in ("displayID","displayMode","displayBounds","lowPowerMode","thermalState")})
    spec_path=directory/"spec.json";write(spec_path,spec)
    manifest=dict(schemaVersion=1,qualifying=False,terminal=terminal,profile=profile,targetGrid=list(target_grid),
        defaultsDomain=environment["CMDY_DEFAULTS_DOMAIN"],
        spec=str(spec_path),specSHA256=sha(spec_path),fixtureCommand=command,
        preparationSources={name:sha(HERE/name) for name in PREPARATION_SOURCES})
    write(directory/"prepared.json",manifest)
    return manifest

def stop_observer(process):
    if process.poll() is None:
        process.terminate()
        try:process.wait(timeout=8)
        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=3)

def native_receipt(path):
    """Classify retained bytes without inventing a native cleanup receipt."""
    receipt=dict(path=str(path),status="missing")
    try:
        if not path.is_file():return {},receipt
        receipt["bytes"]=path.stat().st_size
        require(receipt["bytes"]<=32*1024*1024,"startup raw receipt exceeds bound")
        data=path.read_bytes();receipt["sha256"]=hashlib.sha256(data).hexdigest()
        value=json.loads(data)
        require(isinstance(value,dict),"startup raw receipt is not an object")
        receipt["status"]="retained"
        return value,receipt
    except (ValueError,OSError) as error:
        receipt.update(status="invalid",error=str(error))
        return {},receipt

def cleanup_defaults(spec,manifest,raw):
    if manifest["terminal"]!="cmdy":return dict(complete=True,status="not-applicable")
    domain=spec["environment"]["CMDY_DEFAULTS_DOMAIN"]
    require(re.fullmatch(r"com\.cmdy\.startup\.[0-9a-f]{32}",domain) is not None
        and manifest["defaultsDomain"]==domain,"refusing a defaults domain not owned by this preparation")
    cleanup=raw.get("cleanup",{})
    if cleanup.get("appReaped") is not True or cleanup.get("workerGone") is not True:
        return dict(complete=False,status="deferred",domain=domain,reason="native app/worker cleanup was not proved")
    receipt=dict(complete=False,domain=domain,commands=[])
    def command(operation):
        argv=["/usr/bin/defaults",operation,domain]+(["-"] if operation=="export" else [])
        value=dict(arguments=argv);receipt["commands"].append(value)
        result=subprocess.run(argv,capture_output=True,text=True,timeout=5)
        require(len(result.stdout)+len(result.stderr)<=1_048_576,"owned defaults output exceeds bound")
        value.update(exitCode=result.returncode,stdout=result.stdout,stderr=result.stderr,exitedAndReaped=True)
        return result
    def absent(value):
        return value.returncode!=0 and re.search(r"Domain\s+"+re.escape(domain)+r"\s+does not exist",value.stdout+value.stderr) is not None
    try:
        exported=command("export")
        if absent(exported):receipt.update(complete=True,persisted=False,status="already-absent");return receipt
        require(exported.returncode==0,"owned defaults export failed")
        receipt["persisted"]=True
        require(command("delete").returncode==0,"owned defaults delete failed")
        after = command("export")
        if not absent(after):
            # Current defaults may export an empty plist for an absent suite.
            # Require both that empty dictionary and the exact scoped absence
            # diagnostic from a second delete; an export alone proves nothing.
            require(after.returncode == 0 and not after.stderr.strip()
                and plistlib.loads(after.stdout.encode()) == {}, "owned defaults suite is not empty after deletion")
            gone = command("delete")
            require(gone.returncode == 1 and not gone.stdout.strip()
                and f"Domain ({domain}) not found." in gone.stderr
                and "Defaults have not been changed." in gone.stderr,
                "owned defaults suite absence was not proved")
        receipt.update(complete=True,status="exported-and-deleted")
    except (ValueError,OSError,subprocess.TimeoutExpired) as error:receipt["error"]=str(error)
    return receipt

def record(prepared, observer, build, output):
    from startup_build import OBSERVER_SOURCES
    manifest=json.loads(prepared.read_text());spec_path=Path(manifest["spec"])
    require(manifest["qualifying"] is False and sha(spec_path)==manifest["specSHA256"]
        and set(manifest["preparationSources"])==set(PREPARATION_SOURCES),"startup preparation changed")
    spec=json.loads(spec_path.read_text())
    require(manifest["targetGrid"]==spec["targetGrid"],"prepared target grid differs from frozen launch spec")
    for name,value in manifest["preparationSources"].items():require(sha(HERE/name)==value,"startup preparation source changed")
    for name,value in spec["inputFiles"].items():require(sha(Path(name))==value,"frozen startup input changed")
    require(sha(Path(spec["executable"]))==spec["executableSHA256"],"frozen app bytes changed")
    require(sha(Path(spec["workerExecutable"]))==spec["workerExecutableSHA256"],"frozen worker runtime changed")
    native=json.loads(build.read_text())
    require(native["nativeObservationRun"] is False and native["headlessQualified"] is True and native["binarySHA256"]==sha(observer)
        and set(native["sourceSHA256"])==set(OBSERVER_SOURCES),"startup observer build differs")
    for name,value in native["sourceSHA256"].items():require(sha(HERE/name)==value,"startup observer source changed")
    for name,value in manifest["preparationSources"].items():
        require(native["toolingSHA256"][name]==value,"startup validator/preparation differs from qualified tooling")
    output.mkdir(mode=0o700,parents=True,exist_ok=False)
    write(output/"observer-build.json",native);write(output/"prepared.json",manifest)
    report=dict(schemaVersion=1,qualifying=False,diagnosticValid=False)
    process=None;previous_term=None
    try:
        with (output/"native.log").open("xb") as log:
            process=subprocess.Popen([str(observer),"--spec",str(spec_path),"--output",str(output/"raw.json")],
                stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
            def interrupted(*_):raise KeyboardInterrupt("startup wrapper termination requested")
            previous_term=signal.signal(signal.SIGTERM,interrupted)
            try: code=process.wait(timeout=40)
            except subprocess.TimeoutExpired:
                stop_observer(process)
                raise TimeoutError("startup observer deadline; no diagnostic may qualify")
        raw,receipt=native_receipt(output/"raw.json")
        report["nativeReceipt"]=receipt
        require(code==0,"native startup diagnostic failed; raw receipt "+receipt["status"])
        require(receipt["status"]=="retained","native startup receipt "+receipt["status"])
        report.update(validate(raw,spec,manifest["specSHA256"]))
    except BaseException as error:
        report["error"]=repr(error)
        raise
    finally:
        if process is not None:
            stop_observer(process)
            report["observerPID"]=process.pid;report["observerReaped"]=process.returncode is not None;report["observerExitCode"]=process.returncode
        if previous_term is not None:signal.signal(signal.SIGTERM,previous_term)
        if process is not None and process.returncode is not None:
            raw,receipt=native_receipt(output/"raw.json")
            report["nativeReceipt"]=receipt
            failure={name:raw[name] for name in ("error","observerFailure","serializationError","cleanupError","inputHashError")
                if raw.get(name) is not None}
            if failure:report["nativeFailure"]=failure
            report["ownedDefaultsCleanup"]=cleanup_defaults(spec,manifest,raw)
            if not report["ownedDefaultsCleanup"]["complete"]:
                report["diagnosticValid"]=False
                report["cleanupError"]="owned defaults cleanup remains incomplete; inspect native cleanup first"
        write(output/"result.json",report)
    require(report["diagnosticValid"],"startup diagnostic cleanup failed; raw evidence retained")
    return report

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--prepare",type=Path);p.add_argument("--terminal",choices=("cmdy","ghostty"));p.add_argument("--executable",type=Path)
    p.add_argument("--display",type=Path);p.add_argument("--profile",choices=("matched","cmdy-defaults"),default="matched")
    p.add_argument("--columns",type=int,default=98);p.add_argument("--rows",type=int,default=29)
    p.add_argument("--record-diagnostic",type=Path);p.add_argument("--observer",type=Path);p.add_argument("--observer-build",type=Path);p.add_argument("--output",type=Path)
    p.add_argument("--qualify",action="store_true");p.add_argument("--status",action="store_true")
    args=p.parse_args(argv)
    try:
        if args.qualify:raise ValueError(BLOCKER)
        if args.status or not (args.prepare or args.record_diagnostic):
            print(json.dumps(dict(status="diagnostic-only",qualifying=False,recorderImplemented=True,nativePilotPassed=False,blocker=BLOCKER)));return 0
        require(not(args.prepare and args.record_diagnostic),"select preparation or diagnostic only")
        if args.prepare:
            require(args.terminal and args.executable and args.display,"preparation requires terminal, executable and explicit native display probe")
            result=prepare(args.prepare,args.terminal,args.executable,json.loads(args.display.read_text()),args.profile,
                           target_grid=(args.columns,args.rows))
        else:
            require(args.observer and args.observer_build and args.output,"diagnostic requires observer/build/new output")
            result=record(args.record_diagnostic,args.observer.resolve(),args.observer_build,args.output.resolve())
        print(json.dumps(result,indent=2,sort_keys=True));return 0
    except (ValueError,KeyError,TypeError,OSError,TimeoutError) as error:
        print(json.dumps(dict(status="invalid",qualifying=False,error=str(error)),sort_keys=True));return 2

if __name__ == "__main__":raise SystemExit(main())
