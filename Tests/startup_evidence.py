"""Independent protocol-v5 startup pixel, native-clock and worker-trace evidence."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path
from bench_ancestry import validate_kernel_ancestry
from resize_calibration_evidence import validate_display_mode
from startup_grid import Witness, canonical
from startup_target_trace import validate as validate_target_trace, PROTOCOL as TARGET_PROTOCOL
from startup_grid_evidence import validate_proof, raster_agrees, bounds, digest, PROTOCOL, FOREGROUND_METHOD

METRIC = "native-spawn-to-first-complete-generated-viewport"
BLOCKER = "startup first-visible requires a fresh native geometry/capture pilot and complete paired admission; diagnostic receipts cannot qualify"

def require(value, message):
    if not value: raise ValueError(message)

def integer(value, name, minimum=0):
    require(type(value) is int and minimum <= value <= (1 << 63)-1, "invalid " + name)
    return value

def signed_ns(end, start, timebase):
    integer(end,"end ticks");integer(start,"start ticks")
    numer=integer(timebase["numer"],"timebase numerator",1)
    denom=integer(timebase["denom"],"timebase denominator",1)
    require(numer<=1_000_000_000 and denom<=1_000_000_000,"implausible clock timebase")
    value=abs(end-start)*numer//denom
    require(value<=(1<<63)-1,"signed nanoseconds overflow")
    return value if end>=start else -value

def validate(record, spec, spec_sha256):
    final_worker_events = record["workerFinalEvents"]
    require(record["schemaVersion"] == 1 and record["qualifying"] is False
        and record["status"] == "diagnostic-only" and record["case"] == "startup/first-visible"
        and record["metric"] == METRIC and record["protocol"] == PROTOCOL,
        "startup record is not an eligible diagnostic")
    require(record["spec"] == spec and record["specSHA256"] == spec_sha256
        and spec["schemaVersion"] == 1 and spec["qualifying"] is False,
        "native launch spec binding differs")
    target = spec["targetGrid"]
    require(isinstance(target, list) and len(target) == 2, "startup target grid missing")
    Witness(spec["token"], target[0], target[1], 1, 1).validate()
    require(spec["captureShowsCursor"] is False, "startup capture must exclude the system cursor")
    require(spec['foregroundMethod'] == FOREGROUND_METHOD, 'startup foreground query method differs')
    mode = validate_display_mode(spec["displayMode"])
    display = bounds(spec["displayBounds"])
    require(spec["thermalState"] == 0 and type(spec["lowPowerMode"]) is bool,
        "startup power/thermal pin missing")
    require(record.get("observerFailure") is None and not record.get("error")
        and record["inputHashesUnchanged"] is True, "startup observer or source failed")
    launch, app, worker = record["launch"], record["appIdentity"], record["workerIdentity"]
    start = integer(launch["beforeTicks"], "launch clock", 1)
    returned = integer(launch["afterTicks"], "launch return", start)
    require(launch["api"] == "posix_spawn" and type(launch["calls"]) is int and launch["calls"] == 1
        and type(launch["result"]) is int and launch["result"] == 0
        and launch["pid"] == app["pid"] and app["executable"] == spec["executable"]
        and worker["executable"] == spec["workerExecutable"], "spawned process identity differs")
    validate_kernel_ancestry(record["ancestry"], app, worker)
    proofs = record["proofs"]
    require(isinstance(proofs, dict) and 1 <= len(proofs) <= 8, "startup proof inventory unbounded/missing")
    decoded = {}
    for key, value in proofs.items():
        require(key == digest(value), "startup proof hash differs")
        decoded[key] = validate_proof(value, spec["token"])
    frames, statuses = record["frames"], record["statuses"]
    require(isinstance(frames,list) and 1 <= len(frames) <= 2000
        and isinstance(statuses,list) and 1 <= len(statuses) <= 2000, "startup chronology missing/unbounded")
    first, latest, prelaunch, references = None, None, None, set()
    settled_since = None
    settled_raster = None
    previous_display = previous_callback = 0
    queries = record['foregroundDiagnostics']
    require(isinstance(queries,list) and 1<=len(queries)<=8000,'startup foreground query inventory missing/unbounded')
    foreground = {}
    for query in queries:
        before,after=query['before'],query['after']
        clocks=[before['startedTicks'],before['finishedTicks'],query['cocoaTicks'],
                after['startedTicks'],after['finishedTicks'],query['queriedTicks']]
        require(all(integer(t,'foreground query clock',1) for t in clocks) and clocks==sorted(clocks)
            and clocks[-1]<=record['finishedTicks'],'startup foreground query clocks differ')
        require(type(query['cocoaPID']) is int and -(2**31)<=query['cocoaPID']<2**31,'invalid diagnostic Cocoa PID')
        for item in (before,after):
            require(type(item['trusted']) is bool and type(item['pid']) is int and -(2**31)<=item['pid']<2**31
                and all(type(item[k]) is int and -(2**31)<=item[k]<2**31 for k in ('queryStatus','pidStatus','timeoutStatus')),
                'invalid foreground API receipt')
        matched=(before['pid']>0 and before['pid']==after['pid'] and all(item['trusted'] and
            item['queryStatus']==item['pidStatus']==item['timeoutStatus']==0 for item in (before,after)))
        require(query['queriedTicks'] not in foreground,'duplicate foreground query receipt')
        foreground[query['queriedTicks']] = (before['pid'] if matched else -1, before['startedTicks'])
    def proof_owner(proof, frame=None, foreground_required=True):
        require(proof.get("proofScope") is None and proof.get("schemaVersion") is None,
                "file-transport proof cannot authorize a startup frame")
        rectangle = bounds(proof["bounds"])
        require(proof["identity"] == app and (not foreground_required or proof["foregroundPID"] == app["pid"])
            and proof["occluded"] is False and proof["displayID"] == spec["displayID"],
            "startup crop process/visibility/display differs")
        integer(proof["windowID"], "owned window", 1)
        tick = integer(proof["queriedTicks"], "ownership clock", 1)
        require(tick in foreground and foreground[tick][0]==proof['foregroundPID'],
                'ownership foreground lacks its exact fresh AX query')
        require(display["x"] <= rectangle["x"] and display["y"] <= rectangle["y"]
            and rectangle["x"]+rectangle["width"] <= display["x"]+display["width"]
            and rectangle["y"]+rectangle["height"] <= display["y"]+display["height"], "owned crop outside display")
        if frame is not None: require(frame["callbackTicks"] <= foreground[tick][1] <= tick <= frame["checkedTicks"],
                                      "ownership clock outside decode")
    for frame in frames:
        stamp = integer(frame["displayTicks"], "frame display", 1)
        callback = integer(frame["callbackTicks"], "frame callback", 1)
        checked = integer(frame["checkedTicks"], "frame checked", callback)
        require(stamp >= previous_display and callback >= previous_callback, "regressing startup frame clock")
        previous_display, previous_callback = stamp, callback
        key, stage = frame.get("proofSHA256"), frame["stage"]
        if stage == "prelaunch":
            require(first is None and stamp < start and checked < start and key is None
                and frame.get("before") is None and frame.get("after") is None, "capture attached after app launch")
            prelaunch = frame
            continue
        if stamp < start:
            require(stage == "prelaunch-late" and key is None, "stale frame supplied a viewport")
            continue
        for side in ("before", "after"):
            if frame.get(side) is not None: proof_owner(frame[side], frame, key is not None)
        if key is None:
            require(stage in ("not-owned-visible", "fixture-incomplete") and first is None,
                    "complete flag lacks pixels or first viewport did not remain complete")
            continue
        require(stage == "complete-generated" and key in decoded and callback >= start,
                "complete startup proof/stage/clock differs")
        value, witness = proofs[key], decoded[key]
        references.add(key)
        require(frame.get("before") is not None and frame.get("after") is not None
            and frame["before"]["windowID"] == frame["after"]["windowID"]
            and frame["before"]["queriedTicks"] <= frame["after"]["queriedTicks"], "window changed around observed viewport")
        raster, window = value["raster"], frame["before"]["bounds"]
        require(raster["width"] == mode["pixelWidth"] and raster["height"] == mode["pixelHeight"],
                "startup raster capture mode differs")
        sx, sy = mode["pixelWidth"]/display["width"], mode["pixelHeight"]/display["height"]
        import math
        for side in ("before", "after"):
            crop = frame[side]["bounds"]
            require(raster["xEdges"][0] > math.ceil((crop["x"]-display["x"])*sx)
                and raster["yEdges"][0] > math.ceil((crop["y"]-display["y"])*sy)
                and raster["xEdges"][-1] < math.floor((crop["x"]+crop["width"]-display["x"])*sx)
                and raster["yEdges"][-1] < math.floor((crop["y"]+crop["height"]-display["y"])*sy),
                "complete viewport perimeter touches or leaves a bracketing owned crop")
        if first is None:
            require((witness.columns,witness.rows,witness.frame_kind) == (*target,1),
                    "first complete viewport has wrong initial grid; later frames cannot replace it")
            first = frame
        else:
            original = proofs[first["proofSHA256"]]
            require(value["witness"] == original["witness"]
                and frame["before"]["windowID"] == first["before"]["windowID"],
                "startup grid/generation/window identity changed after first")
        if window != frame["after"]["bounds"]:
            settled_since = None
            settled_raster = None
        elif (settled_since is None or latest["after"]["bounds"] != window
              or not raster_agrees(raster, settled_raster)):
            settled_since = max(stamp, checked)
            settled_raster = raster
        latest = frame
    require(first is not None and prelaunch is not None and record["firstFrame"] == first
        and record["prelaunchFrame"] == prelaunch and references == set(proofs), "first/prelaunch frame substituted or proof unused")
    complete, previous = [], 0
    final = record["finalProof"]; proof_owner(final)
    for item in statuses:
        callback = integer(item["callbackTicks"], "status callback", previous)
        previous = callback
        stamp = item.get("displayTicks")
        if stamp is not None: integer(stamp,"status display")
        require(type(item["status"]) is int and item["status"] in (0,1,2,4)
            and max(callback,stamp or 0) <= final["queriedTicks"], "startup capture status/deadline failed")
        if item["status"] == 0:
            require((stamp or 0)>0,"complete status lacks display clock"); complete.append((callback,stamp))
        if callback >= first["callbackTicks"] or (stamp or 0) >= first["displayTicks"]:
            require(item["status"] in (0,1),"blank/restarted capture after first viewport")
    keys = [(f["callbackTicks"],f["displayTicks"]) for f in frames]
    require(complete == keys and len(set(keys)) == len(keys),"startup status/frame coverage or duplication differs")
    finished = integer(record["finishedTicks"],"startup validation",1)
    cursors = record["captureExcludedSystemCursors"]
    require(isinstance(cursors,dict) and len(cursors)<=8,"startup cursor exclusion inventory missing/unbounded")
    for key,item in cursors.items():
        require(key==f'{integer(item["ownerPID"],"cursor owner",1)}/{integer(item["windowID"],"cursor window",1)}'
            and type(item["layer"]) is int and item["layer"]==2147483630
            and item["ownerExecutable"]=="/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
            and 1<=integer(item["queries"],"cursor query count",1)<=10000,
            "startup exclusion is not the capture-excluded WindowServer cursor")
        require(start<=integer(item["firstQueryTicks"],"first cursor query",start)
            <=integer(item["lastQueryTicks"],"last cursor query",start)<=finished,
            "startup cursor query lies outside owned launch/validation")
    require(max(returned,*(max(f["displayTicks"],f["checkedTicks"]) for f in frames)) <= final["queriedTicks"] <= finished
        and final["bounds"] == latest["after"]["bounds"] and final["windowID"] == first["before"]["windowID"]
        and record["ancestry"]["finishedTicks"] <= final["queriedTicks"], "startup final guard/ancestry clocks differ")
    tb = record["timebase"]
    metrics = dict(launchToFrameNS=signed_ns(first["displayTicks"],start,tb), launchCallNS=signed_ns(returned,start,tb),
        frameMinusLaunchReturnNS=signed_ns(first["displayTicks"],returned,tb), captureCallbackLagNS=signed_ns(first["callbackTicks"],first["displayTicks"],tb))
    require(all(type(v) is int for v in record["metricsNS"].values()) and metrics == record["metricsNS"]
        and signed_ns(finished,max(first["displayTicks"],first["callbackTicks"]),tb) >= 1_000_000_000
        and settled_since is not None and signed_ns(finished,settled_since,tb) >= 200_000_000
        and 0 <= signed_ns(finished,start,tb) <= 15_000_000_000,"startup metric/stability math differs")
    ready, output = record["workerReady"], record["workerEvents"]
    require(ready["pid"] == output["pid"] == worker["pid"] and ready["token"] == output["token"] == spec["token"]
        and ready["executable"] == worker["executable"] and ready["parentPID"] == worker["parentPID"],"startup worker join differs")
    integer(ready["startedTicks"],"worker start",start)
    tty = record["workerTTY"]
    require(re.fullmatch(r"/dev/ttys[0-9]+",ready["ttyPath"]) is not None and tty["path"] == ready["ttyPath"]
        and tty["pid"] == worker["pid"] and tty["uid"] == worker["uid"] and tty["characterDevice"] is True
        and integer(tty["device"],"TTY device") == integer(tty["processDevice"],"controlling device")
        and integer(tty["processGroup"],"process group",1) == integer(tty["foregroundGroup"],"foreground group",1)
        and tty["grid"] == record["finalTTYGrid"], "startup controlling/foreground PTY differs")
    tty_start=integer(tty["startedTicks"],"TTY lookup",record["ancestry"]["finishedTicks"])
    require(integer(tty["finishedTicks"],"TTY lookup return",tty_start) <= final["queriedTicks"],"TTY lookup outside final guard")
    events, signals = output["events"], output["signals"]
    require(isinstance(events,list) and isinstance(signals,list) and 1 <= len(events) <= 64 and len(signals) <= 64,
        "startup worker chronology unbounded")
    # V5 preserves actual initial geometry and proves exactly one target paint
    # using the native recorder's complete trace after owned worker cleanup.
    target_trace = validate_target_trace(ready, final_worker_events, record["cleanup"]["worker"], spec["token"], target)
    require(output["protocol"] == TARGET_PROTOCOL and output["diagnosticOnly"] is True
        and output["status"] == "painted" and output["error"] == "" and output["signalOverflow"] is False,
        "target-grid snapshot missing")
    require(all(output[key] == final_worker_events[key] for key in
        ("protocol", "diagnosticOnly", "token", "pid", "targetGrid", "firstTargetIndex", "paintAttempt", "events")),
        "paint changed between live proof and cleanup")
    for key in ("gridObservations", "signals"):
        require(output[key] == final_worker_events[key][:len(output[key])], "live trace is not the final trace prefix")
    published = integer(output["recordedTicks"], "live trace publication", events[0]["completedTicks"])
    require(published <= finished <= final_worker_events["recordedTicks"]
        and output["gridObservations"] and output["gridObservations"][-1]["reason"] in ("after-write", "wake", "poll")
        and all(item["afterTicks"] <= published for item in output["gridObservations"])
        and all(item["receivedTicks"] <= published for item in signals), "live/final trace clocks differ")
    for index, signal in enumerate(signals):
        require(integer(signal["receivedTicks"],"SIGWINCH",ready["startedTicks"] if index==0 else signals[index-1]["receivedTicks"]) <= finished,
            "worker signal after final observation")
    last_grid = None; last_signal = -1; last_completed = ready["startedTicks"]
    for index,event in enumerate(events):
        require(type(event["generation"]) is int and event["generation"] == index+1,"worker generation is missing or reordered")
        visible = Witness(spec["token"],event["columns"],event["rows"],event["generation"],1)
        payload = visible.frame_bytes()
        require(integer(event["offeredBytes"],"offered bytes",1) == integer(event["completedBytes"],"completed bytes",1) == len(payload)
            and event["payloadSHA256"] == hashlib.sha256(payload).hexdigest(),"startup generated work differs")
        observed = integer(event["observedTicks"],"worker ioctl",last_completed)
        painted = integer(event["startedTicks"],"worker paint",observed)
        last_completed = integer(event["completedTicks"],"worker write return",painted)
        signal = integer(event["signalCounter"],"worker signal")
        require(signal <= len(signals) and (index==0 or (signal>last_signal and (visible.columns,visible.rows)!=last_grid
            and signals[signal-1]["receivedTicks"] <= observed)),"new viewport lacks real grid/signal change")
        last_signal=signal; last_grid=(visible.columns,visible.rows)
    witness = decoded[first["proofSHA256"]]
    require(events[-1]["generation"] == witness.generation and last_grid == tuple(target)
        and events[-1]["startedTicks"] <= first["displayTicks"] and events[-1]["completedTicks"] <= finished
        and record["finalTTYGrid"] == dict(columns=target[0],rows=target[1]),"first raster and worker paint/grid causality differs")
    cleanup = record["cleanup"]
    require(cleanup["appPID"] == app["pid"] and cleanup["workerPID"] == worker["pid"]
        and cleanup["appReaped"] is True and cleanup["workerGone"] is True,
        "owned startup app/worker cleanup not proved")
    ended = cleanup["worker"]
    require(ended["pid"] == worker["pid"] and ended["token"] == spec["token"] and ended["error"] == ""
        and ended["termiosRestored"] is True and ended["flagsRestored"] is True and ended["generation"] == witness.generation
        and integer(ended["finishedTicks"],"worker cleanup",finished) >= finished,"worker terminal cleanup failed")
    return dict(schemaVersion=1,diagnosticValid=True,qualifying=False,diagnosticOnly=True,workerProtocol=TARGET_PROTOCOL,workerTrace=target_trace,case="startup/first-visible",metric=METRIC,**metrics)

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record",type=Path);parser.add_argument("--spec",type=Path,required=True)
    parser.add_argument("--qualify",action="store_true")
    args=parser.parse_args(argv)
    try:
        if args.qualify: raise ValueError(BLOCKER)
        require(args.record.stat().st_size <= 32*1024*1024 and args.spec.stat().st_size <= 256*1024,"startup metadata unbounded")
        raw=args.spec.read_bytes()
        result=validate(json.loads(args.record.read_text()),json.loads(raw),hashlib.sha256(raw).hexdigest())
    except (ValueError,KeyError,TypeError,OSError) as error:
        print(json.dumps(dict(diagnosticValid=False,qualifying=False,error=str(error)),sort_keys=True));return 2
    print(json.dumps(result,sort_keys=True));return 0

if __name__ == "__main__": raise SystemExit(main())
