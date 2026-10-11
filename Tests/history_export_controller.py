#!/usr/bin/env python3
"""Untimed public export on an already owned app/worker; never launches an app."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time

from history_export_evidence import validate_resize_pilot, validate_transfer
from history_export_files import read_retained_generated
from history_export_protocol import ACTION, SHORTCUT, digest, expectation, require
from history_export_phase import POLICY, selected_action, validate_phase, validate_phase_cleanup
from history_export_worker import save

HERE = Path(__file__).resolve().parent
KEYBINDING_LINE = f"keybind = {SHORTCUT}={ACTION}\n"


def binding_config(base, *, case=None, verification_policy=None):
    require(isinstance(base, str) and not any(line.strip().startswith("keybind") and SHORTCUT in line
            for line in base.splitlines()), "export-shortcut-already-configured")
    action = selected_action(case, verification_policy)
    return base.rstrip("\n") + "\n" + f"keybind = {SHORTCUT}={action}\n"


def control(ready_or_socket, capability, operation, **fields):
    """One raw-reader worker; memory can call drain with sequence and timeout."""
    ready = ready_or_socket if isinstance(ready_or_socket, dict) else None
    path = ready["socketPath"] if ready else str(ready_or_socket)
    request = dict(capability=capability, op=operation, **fields)
    timeout = float(fields.get("timeout", 2)) + 2
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(timeout); peer.connect(path)
        peer.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        data = bytearray()
        while not data.endswith(b"\n"):
            part = peer.recv(65536)
            require(bool(part) and len(data) + len(part) <= 512 * 1024, "worker-response-incomplete-or-unbounded")
            data.extend(part)
    response = json.loads(data)
    require(response.get("ok") is True and response.get("capability") == capability
            and (ready is None or response.get("pid") == ready["pid"]), "private-worker-identity-or-operation-failed")
    return response


def validate_native_build(executable, path):
    from history_export_build import SOURCES
    value = json.loads(path.read_text())
    require(value["nativeObservationRun"] is False and value["status"] == "pass"
            and value["binarySHA256"] == digest(executable.read_bytes())
            and set(value["sourceSHA256"]) == set(SOURCES), "native-helper-build-binding-differs")
    require(all(digest((HERE / name).read_bytes()) == checksum for name, checksum in value["sourceSHA256"].items()),
            "native-helper-sources-changed")
    return value


def native_request(executable, operation, spec, directory):
    directory.mkdir(mode=0o700)
    save(directory / "spec.json", spec)
    argv = [str(executable), operation, "--spec", str(directory / "spec.json")]
    with (directory / "stderr.log").open("xb") as log:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log)
        try:
            raw, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill(); process.communicate()
            save(directory / "process.json", dict(argv=argv, pid=process.pid, exitCode=process.returncode, reaped=True, timeout=True))
            raise ValueError("native-helper-timeout") from None
    save(directory / "process.json", dict(argv=argv, pid=process.pid, exitCode=process.returncode, reaped=True))
    require(len(raw) <= 1024 * 1024, "native-helper-response-bound")
    value = json.loads(raw)
    save(directory / "response.json", value)
    require(process.returncode == 0 and value.get("ok") is True and value.get("op") == operation,
            "native-helper-rejected-operation")
    return value


def collect_export(executable, build_manifest, request, output, *, viewport=True, finish_worker=True):
    """The caller owns app lifetime, foreground slot, launch profile and reaping.

    Memory uses viewport=False; that result proves actual generated retained
    content and explicitly makes no claim about displayed text or pixels.
    """
    require(type(request["schemaVersion"]) is int and request["schemaVersion"] in (1, 2)
            and request["terminal"] in ("cmdy", "ghostty"), "pilot-request-version-or-terminal")
    phase_enabled = request["schemaVersion"] == 2
    expected = expectation(request["case"], request["nonce"])
    require(not viewport or expected["case"] == "resize", "v2-viewport-observer-is-resize-only")
    ready = request["workerReady"]; capability = request["workerCapability"]
    spec = dict(request["nativeSpec"])
    if phase_enabled:
        require(not viewport and request.get("verificationPolicy") == POLICY
            and spec.get("proofScope") == "generated-file-transport-v2", "verification-controller-is-file-only")
        spec.update(verificationPolicy=POLICY, exportCase=expected["case"])
        selected_action(expected["case"], POLICY)
    else:
        require("verificationPolicy" not in request and "verificationBoundary" not in request,
                "legacy-controller-cannot-borrow-verification-phase")
    require(spec["nonce"] == expected["nonce"] == ready["nonce"] and spec["workerPID"] == ready["pid"]
            and spec["ttyPath"] == ready["ttyPath"], "native-worker-expectation-binding-differs")
    build = validate_native_build(executable, build_manifest)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    save(output / "request.json", request); save(output / "native-build.json", build)
    result = dict(status="failed", qualifying=False, nativeResizeTimingAdmitted=False,
                  appAndWorkerReapingOwnedByCaller=True, foregroundActivated=False, osClipboardAccessed=False)
    success = False
    try:
        state = control(ready, capability, "status")
        require(state["mode"] == "prepared" and state["prepared"]["expectation"] == expected,
                "worker-must-already-have-exact-generated-preparation-or-memory-drain")
        before = native_request(executable, "inspect", spec, output / "before-owner")["owner"]
        spec.update(expectedApp=before["identity"], expectedWorker=before["workerIdentity"])
        before_view = native_request(executable, "observe", spec, output / "before-viewport") if viewport else None
        phase = None
        if phase_enabled:
            phase_reply = control(ready, capability, "verify-history", boundary=request["verificationBoundary"])
            phase = phase_reply["verificationPhase"]
            validate_phase(phase, expected, ready["pid"], phase_reply["prepared"], boundary=request["verificationBoundary"])
            save(output / "worker-verification.json", phase_reply)
        armed = control(ready, capability, "arm"); save(output / "worker-arm.json", armed)
        action = native_request(executable, "post-key", spec, output / "key")
        deadline = time.monotonic() + 5
        while True:
            state = control(ready, capability, "status")
            if state["mode"] == "received": break
            require(state["mode"] == "armed" and time.monotonic() < deadline, "export-receipt-timeout-or-state")
            time.sleep(.025)
        proof = state["proof"]; save(output / "worker-status.json", state)
        after = native_request(executable, "inspect", spec, output / "after-owner")["owner"]
        after_view = native_request(executable, "observe", dict(spec, afterTicks=proof["receiveCompletedTicks"]),
                                   output / "after-viewport") if viewport else None
        retained = Path(request["fixtureDirectory"]) / "generated-export.bin"
        raw = read_retained_generated(retained, expected)
        document = dict(schemaVersion=3 if phase_enabled else 1, terminal=request["terminal"], expectation=expected, nativeSpec=spec,
                        workerReady=ready, workerArm=armed["arm"], action=action, export=proof,
                        beforeOwner=before, afterOwner=after, beforeViewport=before_view, afterViewport=after_view)
        if phase_enabled: document.update(workerPrepared=phase_reply["prepared"], verificationPhase=phase)
        validated = validate_transfer(document, raw)
        fd = os.open(output / "generated-export.bin", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream: stream.write(raw)
        if finish_worker:
            control(ready, capability, "finish")
            cleanup_path = Path(request["fixtureDirectory"]) / "cleanup.json"
            deadline = time.monotonic() + 3
            while not cleanup_path.exists() and time.monotonic() < deadline: time.sleep(.025)
            cleanup = json.loads(cleanup_path.read_text()); save(output / "worker-cleanup.json", cleanup)
            require(cleanup["status"] == "pass", "worker-cleanup-failed")
            if phase_enabled: validate_phase_cleanup(cleanup, phase, armed["arm"])
            if viewport: validated = validate_resize_pilot(document, raw, cleanup)
        require(not viewport or finish_worker, "resize-pilot-requires-worker-cleanup")
        save(output / "document.json", document)
        result.update(validated, workerFinished=finish_worker, rawExportSHA256=digest(raw))
        success = True
    finally:
        if not success:
            try: control(ready, capability, "abort")
            except Exception: pass
        save(output / "result.json", result)
    return result


def validate_pair(cmdy, ghostty):
    rows = []
    for terminal, directory in (("cmdy", cmdy), ("ghostty", ghostty)):
        document = json.loads((directory / "document.json").read_text())
        require(document["terminal"] == terminal, "paired-terminal-order-differs")
        result = validate_resize_pilot(document, read_retained_generated(directory / "generated-export.bin", document["expectation"]),
                                       json.loads((directory / "worker-cleanup.json").read_text()))
        rows.append((document, result))
    require(rows[0][0]["expectation"] == rows[1][0]["expectation"], "paired-generated-workload-differs")
    require(rows[0][0]["nativeSpec"]["pid"] != rows[1][0]["nativeSpec"]["pid"], "paired-app-identities-not-distinct")
    return dict(status="paired-untimed-generated-history-and-viewport-pilot-pass", qualifying=False,
                nativeResizeTimingAdmitted=False, cases=[item[1] for item in rows])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", type=Path)
    parser.add_argument("--native", type=Path)
    parser.add_argument("--native-build", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate-pair", type=Path, nargs=2)
    args = parser.parse_args(argv)
    if args.validate_pair:
        print(json.dumps(validate_pair(*args.validate_pair), indent=2, sort_keys=True)); return 0
    if args.record:
        require(args.native is not None and args.native_build is not None and args.output is not None,
                "explicit-native-build-and-new-output-required")
        require(args.record.stat().st_size <= 1024 * 1024, "pilot-request-bound")
        value = collect_export(args.native, args.native_build, json.loads(args.record.read_text()), args.output)
        print(json.dumps(value, indent=2, sort_keys=True)); return 0
    print(json.dumps(dict(status="prepared-tooling-only", nativePilotRun=False, qualifying=False,
                         publicBinding=KEYBINDING_LINE.strip(), supportedTerminals=["cmdy", "ghostty"]), sort_keys=True))
    return 0


if __name__ == "__main__": raise SystemExit(main())
