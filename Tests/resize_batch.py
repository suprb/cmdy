"""Record one complete diagnostic resize batch in an already owned native app.

The caller owns launch, calibration, power/activity supervision and app cleanup.
This module owns its native observer children. Public parity admission is closed.
"""
from pathlib import Path
import time

from history_export_controller import native_request, validate_native_build
from history_export_evidence import validate_transfer
from history_export_files import read_retained_generated
from history_export_protocol import resize_batch_expectation
from resize_batch_evidence import validate_frozen_view
from resize_calibration_evidence import validate_discovery
from resize_controller import METRIC, expected_event, worker_request
from resize_evidence import validate_document
from resize_protocol import sequence_plan, growth_guard_enabled
from resize_recorder import Native, require, validate_build
from resize_worker import atomic_json


def capture_view(observer, directory, spec, discovery, sequence, *, after_ticks=0):
    directory.mkdir(mode=0o700)
    native = Native(observer, directory, spec); success = False
    try:
        validate_discovery(discovery, native.started)
        value = native.request("verify", sequence=sequence, calibration=discovery["calibration"], afterTicks=after_ticks)
        validate_frozen_view(value, spec["nonce"], sequence, native.started, discovery, after_ticks=after_ticks)
        atomic_json(directory / "viewport.json", value); success = True
        return dict(display=native.started, viewport=value)
    finally:
        native.close(success)


def collect_history(helper, helper_build, request, phase, output):
    """Use the existing public key action and file validator on the sole reader."""
    output.mkdir(mode=0o700)
    ready, capability = request["workerReady"], request["workerCapability"]
    spec = dict(request["nativeSpec"])
    build = validate_native_build(helper, helper_build)
    atomic_json(output / "native-build.json", build)
    before = native_request(helper, "inspect", spec, output / "before-owner")["owner"]
    spec.update(expectedApp=before["identity"], expectedWorker=before["workerIdentity"])
    armed = worker_request(ready, capability, "history-arm", phase=phase)
    atomic_json(output / "worker-arm.json", armed)
    arm = armed["historyTransfer"]["active"]
    require(arm["phase"] == phase, "export phase differs")
    action = native_request(helper, "post-key", spec, output / "key")
    deadline = time.monotonic() + 5
    while True:
        state = worker_request(ready, capability, "status")
        matches = [row for row in state["historyTransfer"]["completed"] if row["phase"] == phase]
        if matches: break
        require(state["historyTransfer"]["active"] == arm and time.monotonic() < deadline,
                "bounded same-lifetime history export failed")
        time.sleep(.1)
    require(len(matches) == 1 and matches[0]["arm"] == arm, "history phase is not singular")
    transfer = matches[0]
    atomic_json(output / "worker-status.json", state)
    after = native_request(helper, "inspect", spec, output / "after-owner")["owner"]
    expected = resize_batch_expectation(request["nonce"], phase, history_growth_guard=growth_guard_enabled(request))
    require(transfer["expectation"] == expected, "history corpus differs")
    raw = read_retained_generated(Path(request["fixtureDirectory"]) / "history-exports" / phase / "generated-export.bin", expected)
    document = dict(schemaVersion=5, terminal=request["terminal"], expectation=expected, nativeSpec=spec,
        workerReady=ready, workerArm=arm, action=action, export=transfer["proof"], beforeOwner=before, afterOwner=after)
    validated = validate_transfer(document, raw)
    path = output / "generated-export.bin"
    with path.open("xb") as stream: stream.write(raw)
    path.chmod(0o600)
    atomic_json(output / "document.json", document); atomic_json(output / "result.json", validated)
    return document


def record_owned_batch(observer, observer_build, helper, helper_build, request, output):
    require(request["schemaVersion"] == 1 and request["qualifying"] is False,
            "explicit diagnostic batch request required")
    plan = sequence_plan(request["block"])
    ready, capability, spec = request["workerReady"], request["workerCapability"], request["nativeSpec"]
    guarded = growth_guard_enabled(request)
    require(guarded == growth_guard_enabled(ready), "batch repaint history guard differs")
    require(spec["nonce"] == ready["nonce"] == request["nonce"] and spec["workerPID"] == ready["pid"]
            and ready["pairedBlock"] == request["block"] and ready["ttyPath"] == spec["ttyPath"],
            "batch worker, nonce or TTY differs")
    build = validate_build(observer, observer_build)
    small, large = request["smallDiscovery"], request["largeDiscovery"]
    require((validate_discovery(small)["columns"], small["calibration"]["rows"]) == (120,36)
            and (validate_discovery(large)["columns"], large["calibration"]["rows"]) == (132,40),
            "batch calibration grids differ")
    output.mkdir(mode=0o700); atomic_json(output / "request.json", request); atomic_json(output / "observer-build.json", build)
    result = dict(status="failed", qualifying=False, performanceAdmission=False, events=0)
    native = None; success = False
    try:
        start_sequence = request["block"] * 42
        pre = capture_view(observer, output / "before-export-viewport", spec, small, start_sequence)
        before = collect_history(helper, helper_build, request, "before", output / "before-history")
        validate_frozen_view(pre["viewport"], request["nonce"], start_sequence, pre["display"], small,
                             before_ticks=before["action"]["beforeTicks"])
        directory = output / "timed"; directory.mkdir(mode=0o700)
        native = Native(observer, directory, spec)
        for discovery in (small,large): validate_discovery(discovery, native.started)
        current = native.request("verify", sequence=start_sequence, calibration=small["calibration"],
                                 afterTicks=before["export"]["receiveCompletedTicks"])
        validate_frozen_view(current, request["nonce"], start_sequence, native.started, small,
                             after_ticks=before["export"]["receiveCompletedTicks"])
        atomic_json(output / "after-before-export-viewport.json", current)
        source = small
        for index, planned in enumerate(plan):
            target = large if planned["columns"] == 132 else small
            source_sequence = start_sequence if index==0 else plan[index-1]["sequence"]
            native.request("arm", sequence=planned["sequence"], sourceSequence=source_sequence,
                           calibration=target["calibration"], sourceCalibration=source["calibration"])
            arm = worker_request(ready, capability, "arm", sequence=planned["sequence"],
                                 grid=dict(columns=planned["columns"], rows=planned["rows"]))
            observed = native.request("go", sequence=planned["sequence"])
            state = worker_request(ready, capability, "status")
            require(state["completedEvents"] == index+1 and len(state["events"]) == index+1,
                    "batch lost or duplicated a worker event")
            document = dict(schemaVersion=1, case="resize", qualifying=False, metric=METRIC,
                nonce=request["nonce"], planned=planned, display=native.started,
                source=source["calibration"], target=target["calibration"],
                sourceDiscovery=source, targetDiscovery=target,
                entry=dict(expected=expected_event(request["nonce"],planned, history_growth_guard=guarded), arm=arm,
                           worker=state["events"][-1], observer=observed))
            if guarded: document["historyGrowthGuardRows"] = 4
            atomic_json(directory / f"event-{index:02d}.json", document)
            validate_document(document)
            result["events"] += 1; source = target
            time.sleep(expected_event(request["nonce"],planned, history_growth_guard=guarded)["postStabilityGapMS"]/1000)
        native.close(True); native = None
        pre_after = capture_view(observer, output / "before-final-export-viewport", spec, small, plan[-1]["sequence"])
        after = collect_history(helper, helper_build, request, "after", output / "after-history")
        validate_frozen_view(pre_after["viewport"], request["nonce"], plan[-1]["sequence"], pre_after["display"], small,
                             before_ticks=after["action"]["beforeTicks"])
        capture_view(observer, output / "after-final-export-viewport", spec, small, plan[-1]["sequence"],
                     after_ticks=after["export"]["receiveCompletedTicks"])
        require(before["export"]["validation"]["normalizedSHA256"] == after["export"]["validation"]["normalizedSHA256"],
                "batch retained history changed")
        atomic_json(output / "worker-finish.json", worker_request(ready, capability, "finish"))
        result.update(status="diagnostic-complete-resize-batch-recorded", warmups=2, measuredEvents=40,
                      historyExports=2, independentlyValidatedEvents=42)
        success = True
    except BaseException as error:
        result["error"] = repr(error); raise
    finally:
        if native is not None: native.close(False)
        atomic_json(output / "result.json", result)
    return result
