#!/usr/bin/env python3
"""Fresh-process matched-history memory comparison; launches GUI only from main()."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import termios
import time

HERE = Path(__file__).resolve().parent
SHARED = HERE
sys.dont_write_bytecode = True
sys.path.insert(0, str(SHARED))
from competitive_bench import (BenchOptions, assert_grid, binary_metadata,
    block_order, command_result, power_snapshot, process_identity, sha256, window_command)
from terminal_bench_worker import atomic_json, expected_reply

import memory_bench_payloads as payloads
from memory_parity_evidence import IDLE_CPU_METRIC, idle_cpu_rate
from memory_public_history import (PublicHistorySession, TRANSPORT, MEMORY_TOOLING,
    VISUAL_MEMORY_TRANSPORT, VISUAL_MEMORY_SCOPE, VISUAL_MEMORY_TOOLING)
from history_export_phase import POLICY

GRID = (120, 36)
METRIC = "owned-app RSS and physical footprint with exact retained generated rows"
MEMORY_FIELDS = ("residentBytes", "physicalFootprintBytes", "lifetimeMaximumPhysicalFootprintBytes",
                 "wiredBytes", "pageins", "userTimeNS", "systemTimeNS", "diskReadBytes", "diskWrittenBytes")
TOOLING = MEMORY_TOOLING


def case_order(cases: list[dict], block: int) -> list[dict]:
    if not cases or block < 0:
        raise ValueError("nonempty cases and nonnegative block required")
    # Three cases cover all rotations; reverse on each second set of three.
    offset = block % len(cases)
    ordered = cases[offset:] + cases[:offset]
    return ordered[::-1] if (block // len(cases)) % 2 else ordered


def normalized_rows(data: bytes) -> list[str]:
    rows = [line.rstrip(" ") for line in data.decode("ascii").replace("\r\n", "\n").split("\n")]
    while rows and not rows[0]:
        rows.pop(0)
    while rows and not rows[-1]:
        rows.pop()
    return rows


def expected_history_sha(path: Path) -> str:
    import hashlib
    return hashlib.sha256(("\n".join(normalized_rows(path.read_bytes())) + "\n").encode()).hexdigest()


def check_history(record: dict, expected: Path, rows: int, *, post_sample=False) -> None:
    digest = expected_history_sha(expected)
    if (record.get("ok") is not True or record.get("transport") != (VISUAL_MEMORY_TRANSPORT if post_sample else TRANSPORT)
            or record.get("retainedRows") != rows or record.get("expectedRows") != rows
            or record.get("normalizedSHA256") != digest):
        raise RuntimeError("native generated-history verification failed; case is not normalized")


def native_json(arguments: list[str], timeout: float = 10) -> dict:
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    try:
        record = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        # Helpers have fixed, content-free diagnostics.
        raise RuntimeError(f"native helper did not emit JSON (exit {result.returncode})") from error
    if result.returncode or record.get("ok") is not True:
        failure = RuntimeError(record.get("error", "native helper reported invalid evidence"))
        failure.evidence = record
        raise failure
    return record


def conditions(helper: Path) -> dict:
    started = time.perf_counter_ns()
    value = {"power": power_snapshot(), "native": native_json([str(helper), "conditions"])}
    value.update(startedMonotonicNS=started, finishedMonotonicNS=time.perf_counter_ns())
    return value


def condition_signature(record: dict) -> dict:
    native, power = record["native"], record["power"]
    signature = power["signature"]
    if (not signature.get("source") or not signature.get("settings")
            or type(native.get("lowPowerMode")) is not bool
            or type(native.get("thermalState")) is not int
            or native["thermalState"] != 0
            or any(power[key].get("returncode") != 0 for key in ("battery", "settings", "thermal"))):
        raise RuntimeError("power/thermal evidence unavailable or thermal state is not nominal")
    return {"powerSource": signature["source"], "powerSettings": signature["settings"],
            "lowPowerMode": native["lowPowerMode"], "thermalState": native["thermalState"],
            "physicalMemoryBytes": native["physicalMemoryBytes"], "processorCount": native["processorCount"],
            "os": native["os"]}


def require_conditions(record: dict, reference: dict) -> None:
    if condition_signature(record) != reference:
        raise RuntimeError("power/thermal/machine conditions changed; do not pool these runs")


def wait_until(deadline: float) -> None:
    while time.monotonic() < deadline:
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))


def check_layout(session: TerminalSession, display: int, reference: list[dict] | None = None) -> dict:
    state = session.window()  # Strict; never activates after setup.
    assert_grid(session.grid(), GRID)
    if state["windows"][0]["displayID"] != display:
        raise RuntimeError("owned window left the required display")
    if reference is not None and state["windows"] != reference:
        raise RuntimeError("owned window bounds/visibility changed during sampled case")
    return state


def ownership_chain(session: TerminalSession) -> list[dict]:
    """Retain the exact public parent chain checked for this launched worker."""
    worker_pid, worker_identity = session.worker_identity
    pid, chain, seen = worker_pid, [], set()
    for _ in range(32):
        if pid <= 1 or pid in seen:
            raise RuntimeError("fixture parent chain did not reach the owned app")
        seen.add(pid)
        identity = process_identity(pid)
        response = command_result(["/bin/ps", "-p", str(pid), "-o", "ppid="])
        if not identity or response.get("returncode") != 0:
            raise RuntimeError("fixture ancestry disappeared during verification")
        parent = int(response["stdout"])
        if process_identity(pid) != identity:
            raise RuntimeError("fixture ancestry identity changed during verification")
        chain.append({"pid": pid, "parentPID": parent, "startIdentity": identity})
        if pid == session.app_pid:
            if chain[0]["startIdentity"] != worker_identity or session.process.poll() is not None:
                raise RuntimeError("owned app/fixture launch identity changed")
            return chain
        pid = parent
    raise RuntimeError("fixture ancestry exceeded the bounded lookup")


def memory_sample(helper: Path, pid: int, expected_start: int | None) -> dict:
    arguments = [str(helper), str(pid)]
    if expected_start is not None:
        arguments.append(str(expected_start))
    started = time.perf_counter_ns()
    value = native_json(arguments)
    finished = time.perf_counter_ns()
    if (value.get("pid") != pid or value.get("uid") != os.getuid()
            or value.get("processStartTicks", 0) <= 0
            or (expected_start is not None and value["processStartTicks"] != expected_start)
            or not started <= value.get("startedMonotonicNS", -1) <= finished
            or value.get("sampleElapsedNS", -1) < 0
            or any(type(value.get(key)) is not int or value[key] < 0 for key in MEMORY_FIELDS)
            or value.get("residentBytes", 0) == 0 or value.get("physicalFootprintBytes", 0) == 0):
        raise RuntimeError("process identity/accounting/clock validation failed")
    value.update(hostStartedMonotonicNS=started, hostFinishedMonotonicNS=finished)
    return value


def summarize(records: list[dict], blocks: int, block_start: int = 0) -> dict:
    result = {"metric": METRIC, "status": "valid-normalized-history", "blocks": blocks, "cases": {}}
    if block_start:
        result["blockStart"] = block_start
    for case in sorted({item["case"] for item in records}):
        selected = [item for item in records if item["case"] == case]
        if (len(selected) != blocks * 2 or any(item.get("status") != "valid" for item in selected)
                or {(item["block"], item["terminal"]) for item in selected}
                    != {(block, terminal) for block in range(block_start, block_start + blocks) for terminal in ("cmdy", "ghostty")}):
            raise ValueError("every case needs a valid fresh process for both terminals in every block")
        case_summary = {}
        for terminal in ("cmdy", "ghostty"):
            runs = [item for item in selected if item["terminal"] == terminal]
            values = {}
            for field in ("residentBytes", "physicalFootprintBytes"):
                before = [item["samples"][1]["app"][field] for item in runs]
                after = [item["samples"][-1]["app"][field] for item in runs]
                delta = [right - left for left, right in zip(before, after)]
                values[field] = {"baselineMedian": statistics.median(before),
                                 "settledMedian": statistics.median(after),
                                 "deltaMedian": statistics.median(delta),
                                 "settledMinimum": min(after), "settledMaximum": max(after)}
            values["launchToFixtureReadyNS"] = {
                "median": statistics.median(item["launchProxyNS"] for item in runs),
                "semantics": "raw worker readiness; not shell prompt or visible frame"}
            if all(len(item["samples"]) == 6 and item["samples"][2]["label"] == "settled-idle-cpu-end"
                   for item in runs):
                values["idleCPU"] = {"metric": IDLE_CPU_METRIC,
                    "medianNanosecondsPerSecond": statistics.median(
                        idle_cpu_rate(item["samples"][1]["app"], item["samples"][2]["app"]) for item in runs)}
            case_summary[terminal] = values
        case_summary["pairedBlocks"] = [{"block": block, **{
            field: next(item for item in selected if item["block"] == block and item["terminal"] == "cmdy")
                ["samples"][-1]["app"][field]
                / next(item for item in selected if item["block"] == block and item["terminal"] == "ghostty")
                ["samples"][-1]["app"][field]
            for field in ("residentBytes", "physicalFootprintBytes")}}
            for block in range(block_start, block_start + blocks)]
        result["cases"][case] = case_summary
    if not result["cases"]:
        raise ValueError("no complete cases")
    result["scope"] = "app PID only; fixture accounted separately; excludes WindowServer and shared-process attribution"
    result["limitations"] = ["No process-tree total or GPU ownership attribution.",
        "Same verified content below both configured capacities; capacities themselves are not equalized.",
        "RSS and physical footprint include allocator/cache high-water; neither proves a leak.",
        "Public history export occurs only after all samples in each fresh process.",
        "No first-visible or first-usable shell startup claim."]
    return result


def run_case(args, output: Path, case: dict, block: int, position: int, terminal: str,
             reference: dict) -> dict:
    directory = output / "runs" / f"{block:02d}-{position:02d}-{case['name']}-{terminal}"
    payload = output / "payloads" / case["payload"]
    expected = output / "payloads" / case["expected"]
    options = BenchOptions(args.cmdy_bin, args.ghostty_bin, payload=payload, profile=args.profile,
        font_size=14, timeout=args.timeout, settle_seconds=args.settle_seconds,
        tooling_dir=output / "tooling", diagnostic_frame_trace=args.diagnostic_frame_trace)
    record = {"block": block, "position": position, "case": case["name"], "terminal": terminal,
              "status": "preparing", "profile": args.profile,
              "expectedRows": case["expectedRows"], "activeScreen": case["activeScreen"],
              "priorBurstBytes": case["priorBurstBytes"], "samples": [], "conditions": [],
              "payloadBytes": payload.stat().st_size, "payloadSHA256": sha256(payload),
              "expectedHistorySHA256": expected_history_sha(expected)}
    session = None
    public = None
    original_error = None
    try:
        state = conditions(args.history_helper)
        record["conditions"].append(state)
        require_conditions(state, reference)
        marker = json.loads((output / "payloads/manifest.json").read_text())["generatedMarker"]
        public = PublicHistorySession(options, args.window_helper, terminal, directory,
                                      case["name"], payload, marker, Path(sys.executable).resolve(),
                                      **({"child_umask": 0o077, "verification_policy": POLICY,
                                          "verification_scope": VISUAL_MEMORY_SCOPE}
                                         if getattr(args, "post_sample_history", False) else {}))
        session = public.session
        session.launch()
        launch = json.loads((directory / "launch.json").read_text())
        record["identity"] = {"appPID": session.app_pid, "workerPID": session.worker_identity[0]
            if session.worker_identity else None, "workerLaunchIdentity": session.worker_identity[1]
            if session.worker_identity else None}
        record["launchProxyNS"] = launch["processLaunchToFixtureReadyNS"]
        if not 0 < record["launchProxyNS"] < args.timeout * 1e9:
            raise RuntimeError("launch-to-fixture-ready clocks are invalid")
        if (session.ready.get("payloadSHA256") != record["payloadSHA256"]
                or session.ready.get("payloadBytes") != record["payloadBytes"]
                or not session.worker_identity
                or session.ready["ttyFlagsRaw"][1] & termios.OPOST):
            raise RuntimeError("fixture byte hash, descendant identity or effective raw OPOST state is invalid")
        record["tty"] = {"rawFlags": session.ready["ttyFlagsRaw"], "effectiveOPOST": False,
                         "inactiveONLCRBit": session.ready["onlcrEnabled"]}
        session.window(activate=True)
        session.place_window(120, 120)
        session.fit_grid(GRID, allow_resize=True)
        layout = check_layout(session, args.display_id)
        if getattr(args, "park_pointer_outside_window", False):
            started = time.perf_counter_ns()
            placement = native_json([str(args.window_helper), "park-pointer", str(session.app_pid)])
            pointer = {"hostStartedMonotonicNS": started, "native": placement,
                       "hostFinishedMonotonicNS": time.perf_counter_ns()}
            atomic_json(directory / "pointer-setup.json", pointer)
            record["pointerSetup"] = pointer
            check_layout(session, args.display_id, layout["windows"])
        record["window"] = layout
        record["setupFinishedMonotonicNS"] = time.perf_counter_ns()
        app_start = worker_start = None

        def capture(label: str, requested_offset: float | None = None, drain_finished: int | None = None):
            nonlocal app_start, worker_start
            guard_started = time.perf_counter_ns()
            window_before = check_layout(session, args.display_id, layout["windows"])
            worker_pid = session.worker_identity[0]
            ancestry = ownership_chain(session)
            item = {"label": label, "requestedOffsetSeconds": requested_offset,
                    "guardStartedMonotonicNS": guard_started, "windowBefore": window_before,
                    "gridBefore": session.grid(), "ownershipChain": ancestry,
                    "app": memory_sample(args.memory_helper, session.app_pid, app_start),
                    "worker": memory_sample(args.memory_helper, worker_pid, worker_start)}
            app_start, worker_start = item["app"]["processStartTicks"], item["worker"]["processStartTicks"]
            if drain_finished is not None:
                item["actualOffsetNS"] = item["app"]["startedMonotonicNS"] - drain_finished
                if item["actualOffsetNS"] < 0:
                    raise RuntimeError("post-output memory sample precedes validated DSR completion")
            record["samples"].append(item)
            state = conditions(args.history_helper)
            record["conditions"].append(state)
            require_conditions(state, reference)
            item["conditionsIndex"] = len(record["conditions"]) - 1
            item["windowAfter"] = check_layout(session, args.display_id, layout["windows"])
            item["gridAfter"] = session.grid()
            assert_grid(item["gridBefore"], GRID)
            assert_grid(item["gridAfter"], GRID)
            item["guardFinishedMonotonicNS"] = time.perf_counter_ns()
            atomic_json(directory / "memory.json", record)

        capture("matched-grid-before-settle")
        wait_until(time.monotonic() + args.settle_seconds)
        capture("settled-idle-baseline")
        # The first five seconds were settling. CPU gets its own later interval;
        # it cannot silently include initial resize/render/startup work.
        wait_until(time.monotonic() + args.idle_cpu_seconds)
        capture("settled-idle-cpu-end")
        idle_cpu_rate(record["samples"][1]["app"], record["samples"][2]["app"])
        before_drain = check_layout(session, args.display_id, layout["windows"])
        drain = public.drain(sequence=block, timeout=args.timeout)
        record["drain"] = drain
        drain["windowBefore"] = before_drain
        footer, response = expected_reply(GRID[1], GRID[0], block)
        if (drain.get("payloadBytes") != record["payloadBytes"]
                or drain.get("footerHex") != footer.hex() or drain.get("responseHex") != response.hex()
                or drain.get("expectedResponseHex") != response.hex()
                or drain.get("elapsedNS", 0) <= 0
                or drain["finishedMonotonicNS"] - drain["startedMonotonicNS"] != drain["elapsedNS"]):
            raise RuntimeError("exact DSR response, bytes or monotonic duration is invalid")
        assert_grid(drain["gridBefore"], GRID)
        assert_grid(drain["gridAfter"], GRID)
        drain["windowAfter"] = check_layout(session, args.display_id, before_drain["windows"])
        for offset in args.after_seconds:
            wait_until(drain["finishedMonotonicNS"] / 1e9 + offset)
            capture(f"post-output-{offset:g}s", offset, drain["finishedMonotonicNS"])
        accounting = record["samples"][-1]["app"]
        history = public.verify(args.history_helper, native_json, layout,
                                (accounting["timebaseNumer"], accounting["timebaseDenom"]),
                                **({"verification_boundary": {"kind": "all-memory-samples",
                                    "finishedMonotonicNS": record["samples"][-1]["guardFinishedMonotonicNS"]}}
                                   if getattr(args, "post_sample_history", False) else {}))
        record["historyVerification"] = history
        check_history(history, expected, case["expectedRows"],
                      **({"post_sample": True} if getattr(args, "post_sample_history", False) else {}))
        check_layout(session, args.display_id, layout["windows"])
        public.finish()
        record["status"] = "valid"
        print(f"{case['name']} block {block + 1}: {terminal} "
              f"RSS {record['samples'][-1]['app']['residentBytes'] / 2**20:.2f} MiB, "
              f"{case['expectedRows']} rows verified", flush=True)
        return record
    except BaseException as error:
        original_error = error
        record.update(status="invalid", error=str(error))
        if hasattr(error, "evidence"):
            record["failureEvidence"] = error.evidence
        raise
    finally:
        if public is not None:
            try:
                public.close()
            except BaseException as cleanup_error:
                record["cleanupError"] = str(cleanup_error)
                record["status"] = "invalid"
                if original_error is None:
                    atomic_json(directory / "memory.json", record)
                    raise
        if directory.is_dir():
            atomic_json(directory / "memory.json", record)
        else:
            # A pre-launch condition failure still gets a bounded case record.
            atomic_json(output / f"failed-{block:02d}-{position:02d}-{terminal}.json", record)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--cmdy-bin", type=Path, required=True)
    result.add_argument("--ghostty-bin", type=Path, default=Path("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
    result.add_argument("--window-helper", type=Path, required=True)
    result.add_argument("--memory-helper", type=Path, required=True)
    result.add_argument("--history-helper", type=Path, required=True,
                        help="qualified history_export_native helper; the legacy clipboard helper is unsupported")
    result.add_argument("--post-sample-history", action="store_true",
                        help="opt in to schema 5: fixed post-sample verification with full visual ownership")
    result.add_argument("--park-pointer-outside-window", action="store_true",
                        help="park the pointer outside the owned window before any accounting; preserve all occlusion checks")
    result.add_argument("--blocks", type=int, default=6)
    result.add_argument("--block-start", type=int, default=0,
                        help="global first block; preserves case rotation and app counterbalancing across checkpoints")
    result.add_argument("--payload-marker",
                        help="preregistered 16-hex generated-content marker shared across a checkpoint campaign")
    result.add_argument("--profile", choices=("matched", "cmdy-defaults"), default="matched")
    result.add_argument("--first", choices=("cmdy", "ghostty"), default="cmdy")
    result.add_argument("--cases", nargs="+", choices=("primary-1000", "primary-5000", "alternate-continuous"))
    result.add_argument("--settle-seconds", type=float, default=5)
    result.add_argument("--idle-cpu-seconds", type=float, choices=(5,), default=5)
    result.add_argument("--after-seconds", type=float, nargs="+", default=[0, 1, 5])
    result.add_argument("--timeout", type=float, default=60)
    result.add_argument("--display-id", type=int, default=1)
    result.add_argument("--conditions-reference", type=Path)
    result.add_argument("--diagnostic-frame-trace", action="store_true")
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser()
    args = arguments.parse_args(argv)
    if sys.platform != "darwin":
        arguments.error("macOS required")
    if (not 1 <= args.blocks <= 20 or not 0 <= args.block_start <= 20 - args.blocks
            or args.payload_marker is not None and not re.fullmatch(r"[0-9a-f]{16}", args.payload_marker)
            or not 1 <= args.settle_seconds <= 60
            or not 1 <= args.timeout <= 120 or args.display_id < 1
            or not args.after_seconds or args.after_seconds != sorted(set(args.after_seconds))
            or any(not 0 <= offset <= 60 for offset in args.after_seconds)
            or args.after_seconds[-1] < 1 or args.cases and len(args.cases) != len(set(args.cases))):
        arguments.error("invalid counts, cases or strictly increasing sample offsets")
    if args.park_pointer_outside_window and not args.post_sample_history:
        arguments.error("pointer setup requires the explicit post-sample visual history mode")
    if args.post_sample_history and (args.settle_seconds != 5 or args.after_seconds != [0, 1, 5]):
        arguments.error("post-sample history requires all six original samples at the fixed schedule")
    interpreter_pin = None
    if args.post_sample_history:
        from history_executable_identity import pin_current_interpreter
        interpreter_pin = pin_current_interpreter()
    for key in ("cmdy_bin", "ghostty_bin", "window_helper", "memory_helper", "history_helper"):
        path = getattr(args, key).expanduser().resolve()
        if not path.is_file() or not os.access(path, os.X_OK):
            arguments.error(f"{key} must be separately prepared and executable")
        setattr(args, key, path)
    # This must precede all output writes; even failures cannot overwrite an old run.
    output = args.output.expanduser().resolve()
    args.output = output
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    (output / "runs").mkdir()
    (output / "tooling").mkdir()
    for name in (VISUAL_MEMORY_TOOLING if args.post_sample_history else TOOLING):
        shutil.copy2(SHARED / name, output / "tooling" / name)
    (output / "helpers").mkdir()
    helper_inputs = {}
    for name in ("window_helper", "memory_helper", "history_helper"):
        path = getattr(args, name)
        helper_inputs[name] = str(path)
        frozen = output / "helpers" / name
        shutil.copy2(path, frozen)
        setattr(args, name, frozen)
    records = []
    manifest = {"schemaVersion": 5 if args.post_sample_history else 4, "benchmarkKind": "memory", "status": "preparing", "metric": METRIC,
        "historyTransport": VISUAL_MEMORY_TRANSPORT if args.post_sample_history else TRANSPORT,
        "idleCPUMetric": IDLE_CPU_METRIC,
        "startedUTC": datetime.now(timezone.utc).isoformat(), "diagnostic": args.diagnostic_frame_trace,
        "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()
                      if key not in ("post_sample_history", "park_pointer_outside_window") or value},
        "python": sys.version, "architecture": platform.machine(), "targetGrid": {"columns": 120, "rows": 36},
        "clock": vars(time.get_clock_info("perf_counter")),
        "profile": args.profile, "helperInputs": helper_inputs,
        "profileDescription": "isolated launch; CMDY error help and Extensions off; matched also disables shaders and appearance effects",
        "ghosttyScrollbackLimitBytes": 100_000_000,
        "startupMetric": "launch-to-raw-fixture-ready proxy; geometry fit follows readiness; no visible/shell claim"}
    if args.post_sample_history:
        manifest.update(verificationPolicy=POLICY, verificationScope=VISUAL_MEMORY_SCOPE, childUmask=0o077,
            pythonExecutable=interpreter_pin)
    try:
        if ("mach_absolute_time" not in manifest["clock"]["implementation"]
                or not manifest["clock"]["monotonic"] or manifest["clock"]["adjustable"]):
            raise RuntimeError("Python/native helper must share the monotonic mach_absolute_time clock")
        manifest["binaries"] = {name: binary_metadata(getattr(args, name + "_bin")) for name in ("cmdy", "ghostty")}
        manifest["toolingSHA256"] = {path.name: sha256(path) for path in (output / "tooling").iterdir() if path.is_file()}
        manifest["helperSHA256"] = {name: sha256(getattr(args, name)) for name in
                                    ("window_helper", "memory_helper", "history_helper")}
        manifest["os"] = command_result(["/usr/bin/sw_vers"])
        manifest["hardware"] = command_result(["/usr/sbin/sysctl", "hw.model", "hw.memsize", "hw.physicalcpu",
                                              "hw.logicalcpu", "machdep.cpu.brand_string"])
        probe = window_command(args.window_helper, "probe", 14)
        manifest["displayFontPermissions"] = probe
        if (probe["font"]["postScriptName"] != "Menlo-Regular" or not probe["font"]["file"]
                or not probe["accessibilityTrusted"] or not probe["postEventAuthorized"]
                or args.display_id not in {display["displayID"] for display in probe["displays"]}):
            raise RuntimeError("matching font/display or existing native control permissions unavailable")
        manifest["fontSHA256"] = sha256(Path(probe["font"]["file"]))
        initial = conditions(args.history_helper)
        manifest["initialConditions"] = initial
        reference = condition_signature(initial)
        if args.conditions_reference:
            prior = json.loads(args.conditions_reference.read_text())["signature"]
            require_conditions(initial, prior)
            reference = prior
        atomic_json(output / "conditions-reference.json", {"signature": reference})
        payload_manifest = payloads.create_payloads(output / "payloads", marker=args.payload_marker)
        manifest["payloads"] = payload_manifest
        cases = [case for case in payload_manifest["cases"] if not args.cases or case["name"] in args.cases]
        manifest["preregisteredCases"] = [case["name"] for case in cases]
        manifest["plannedRunOrder"] = [
            {"block": block, "position": position, "case": case["name"], "terminal": terminal}
            for block in range(args.block_start, args.block_start + args.blocks) for position, case in enumerate(case_order(cases, block))
            for terminal in block_order(block, args.first)]
        manifest["status"] = "running"
        atomic_json(output / "manifest.json", manifest)
        for block in range(args.block_start, args.block_start + args.blocks):
            for position, case in enumerate(case_order(cases, block)):
                for terminal in block_order(block, args.first):
                    records.append(run_case(args, output, case, block, position, terminal, reference))
                    atomic_json(output / "records.json", records)
        final_conditions = conditions(args.history_helper)
        manifest["finalConditions"] = final_conditions
        require_conditions(final_conditions, reference)
        for terminal in ("cmdy", "ghostty"):
            if sha256(getattr(args, terminal + "_bin")) != manifest["binaries"][terminal]["sha256"]:
                raise RuntimeError("application binary changed during the comparison")
        for name, expected_hash in manifest["helperSHA256"].items():
            if sha256(getattr(args, name)) != expected_hash:
                raise RuntimeError("frozen native helper changed during the comparison")
        for name, expected_hash in manifest["toolingSHA256"].items():
            if sha256(output / "tooling" / name) != expected_hash:
                raise RuntimeError("frozen source tooling changed during the comparison")
        if args.post_sample_history:
            from history_executable_identity import same_executable_file
            if not same_executable_file(manifest["pythonExecutable"]["path"], manifest["pythonExecutable"]):
                raise RuntimeError("pinned worker interpreter changed during comparison")
        manifest["finalHashesVerified"] = True
        summary = summarize(records, args.blocks, args.block_start)
        summary["diagnostic"] = args.diagnostic_frame_trace
        summary["profile"] = args.profile
        if args.diagnostic_frame_trace:
            summary["status"] = "diagnostic-instrumented"
        atomic_json(output / "summary.json", summary)
        manifest["status"] = "complete"
        return 0
    except BaseException as error:
        manifest.update(status="invalid", error=str(error))
        return 130 if isinstance(error, KeyboardInterrupt) else 1
    finally:
        manifest["completedUTC"] = datetime.now(timezone.utc).isoformat()
        atomic_json(output / "manifest.json", manifest)


if __name__ == "__main__":
    def interrupted(*_):
        raise KeyboardInterrupt("interrupted; only owned fixture/app cleanup will run")
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
