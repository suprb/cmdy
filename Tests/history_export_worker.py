#!/usr/bin/env python3
"""Owned raw-PTY fixture; receives a public exported path, never a shell command."""
from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import socket
import sys
import termios
import time
import tty

# This separately launched fixture imports frozen evidence tooling. Its parent
# interpreter's -B flag is not inherited through the terminal process.
sys.dont_write_bytecode = True

from history_export_files import directory_rejection_metadata, inventory, open_directory, read_generated_export, rejected_input_shape
from history_export_protocol import (CASES, PATH_LIMIT, RECEIVE_SECONDS, digest,
                                     expectation, memory_payload, missing_row_metadata, preparation_bytes, require)
from history_export_phase import POLICY, authorize_arm, authorize_phase, validate_phase
from resize_protocol import RESTORE, check_nonce


def save(path, value):
    temporary = path.with_name("." + path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":")); stream.write("\n")
    os.replace(temporary, path)


def retain_directory_rejection(failure, output, *, nonce, armed_ticks, now):
    """A best-effort fixed error artifact cannot replace the original failure."""
    try:
        value = directory_rejection_metadata(failure)
        if value is None: return False
        if type(nonce) is not str: return False
        check_nonce(nonce)
        finished = now(); pid = os.getpid()
        if (type(armed_ticks) is not int or not 0 < armed_ticks < 1 << 63
                or type(finished) is not int or not armed_ticks <= finished < 1 << 63
                or type(pid) is not int or not 0 < pid < 1 << 31): return False
        save(Path(output) / "directory-rejection.json", dict(value, pid=pid, nonce=nonce,
             armedTicks=armed_ticks, finishedTicks=finished))
        return True
    except Exception:
        return False


def retain_missing_row(failure, output, *, nonce, armed_ticks, now):
    """Persist only validated prefix counts; write failure cannot change rejection."""
    try:
        value = missing_row_metadata(failure)
        if value is None: return False
        if type(nonce) is not str: return False
        check_nonce(nonce)
        finished = now(); pid = os.getpid()
        if (type(armed_ticks) is not int or not 0 < armed_ticks < 1 << 63
                or type(finished) is not int or not armed_ticks <= finished < 1 << 63
                or type(pid) is not int or not 0 < pid < 1 << 31): return False
        save(Path(output) / "missing-generated-row.json", dict(value, pid=pid, nonce=nonce,
             armedTicks=armed_ticks, finishedTicks=finished))
        return True
    except Exception:
        return False


def mach_clock():
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    function = library.mach_absolute_time
    function.argtypes = []; function.restype = ctypes.c_uint64
    return function


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--temporary-directory", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--capability", required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--case", choices=CASES, default="resize")
    parser.add_argument("--payload", type=Path, help="exact generated memory payload; enables one drain on this same TTY reader")
    parser.add_argument("--verification-policy", choices=(POLICY,))
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args(argv)
    check_nonce(args.capability); spec = expectation(args.case, args.nonce)
    require(args.verification_policy is None or args.payload is not None and args.case != "resize",
            "verification-requires-original-memory-payload")
    require(10 <= args.timeout <= 600, "worker-lifetime-outside-bound")
    payload = None
    if args.payload is not None:
        require(args.payload.is_file() and not args.payload.is_symlink()
                and args.payload.stat().st_size <= 4 * 1024 * 1024, "drain-payload-bound")
        payload = args.payload.read_bytes()
        require(payload == memory_payload(spec), "drain-payload-is-not-exact-generated-case")
    require(str(args.temporary_directory) == os.environ.get("TMPDIR", "").rstrip("/"), "registered-TMPDIR-differs")
    os.close(open_directory(args.temporary_directory)); os.close(open_directory(args.socket.parent))
    require(args.socket.parent != args.temporary_directory and len(os.fsencode(args.socket)) < 104,
            "separate-short-private-control-directory-required")
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    now = mach_clock(); original = termios.tcgetattr(0)
    input_blocking, output_blocking = os.get_blocking(0), os.get_blocking(1)
    server = socket.socket(socket.AF_UNIX); server.bind(str(args.socket)); os.chmod(args.socket, 0o600)
    server.listen(1)
    mode, running, error, reason = "ready", True, "", ""
    deadline = time.monotonic() + args.timeout
    received = bytearray(); chunks = []; armed = None; proof = None; prepared = None
    verification = None
    unexpected = 0; controls = []; shape_recorded = False
    started_monotonic = time.perf_counter_ns()

    def grid():
        value = os.get_terminal_size(0)
        return dict(columns=value.columns, rows=value.lines)

    def status():
        value = dict(schemaVersion=1, ok=not error, pid=os.getpid(), capability=args.capability,
                    mode=mode, grid=grid(), error=error, prepared=prepared, arm=armed,
                    proof=proof, unexpectedInputBytes=unexpected)
        if args.verification_policy is not None: value["verificationPhase"] = verification
        return value

    def stop(signum, _frame):
        nonlocal running, reason
        running = False; reason = "signal-" + str(signum)

    def write_all(payload):
        start = int(now()); limit = min(deadline, time.monotonic() + 30); offset = 0
        while offset < len(payload):
            require(running and time.monotonic() < limit, "generated-write-timeout")
            try:
                count = os.write(1, payload[offset:offset + 65536])
                require(count > 0, "generated-write-empty"); offset += count
            except BlockingIOError:
                select.select([], [1], [], .01)
            except InterruptedError:
                continue
        return dict(bytes=len(payload), sha256=digest(payload), startedTicks=start, completedTicks=int(now()))

    try:
        tty.setraw(0, when=termios.TCSANOW); os.set_blocking(0, False); os.set_blocking(1, False)
        for name in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT): signal.signal(name, stop)
        ready = dict(schemaVersion=1, role="history-public-export", pid=os.getpid(), parentPID=os.getppid(),
                     ttyPath=os.ttyname(0), socketPath=str(args.socket), nonce=args.nonce,
                     workerPID=os.getpid(), temporaryDirectory=str(args.temporary_directory), startedTicks=int(now()),
                     startedMonotonicNS=started_monotonic, readyMonotonicNS=time.perf_counter_ns(),
                     payloadBytes=len(payload) if payload is not None else None,
                     payloadSHA256=digest(payload) if payload is not None else None,
                     ttyFlagsBefore=original[:6], ttyFlagsRaw=termios.tcgetattr(0)[:6],
                     onlcrEnabled=bool(termios.tcgetattr(0)[1] & termios.ONLCR),
                     outputPostprocessingEnabled=bool(termios.tcgetattr(0)[1] & termios.OPOST), **grid())
        if args.verification_policy is not None: ready["verificationPolicy"] = args.verification_policy
        save(args.output / "ready.json", ready)
        while running:
            require(time.monotonic() < deadline, "worker-lifetime-expired")
            if mode == "armed" and time.monotonic_ns() >= armed["deadlineMonotonicNS"]:
                # Complete the fixed receive window, rather than accepting a
                # path prefix after one PTY read or inventing a delimiter.
                try:
                    proof = read_generated_export(bytes(received), args.temporary_directory,
                        armed["beforeInventory"], spec, args.output / "generated-export.bin")
                except ValueError as failure:
                    retain_directory_rejection(failure, args.output, nonce=args.nonce,
                        armed_ticks=armed["armedTicks"], now=now)
                    retain_missing_row(failure, args.output, nonce=args.nonce,
                        armed_ticks=armed["armedTicks"], now=now)
                    shape = rejected_input_shape(bytes(received), args.temporary_directory)
                    if shape is not None:
                        save(args.output / "rejected-input-shape.json", dict(
                            pid=os.getpid(), nonce=args.nonce, armedTicks=armed["armedTicks"],
                            finishedTicks=int(now()), chunks=chunks, shape=shape))
                        shape_recorded = True
                    raise
                proof.update(receiveStartedTicks=armed["armedTicks"], receiveCompletedTicks=int(now()),
                             receiveStartedMonotonicNS=armed["armedMonotonicNS"],
                             receiveCompletedMonotonicNS=time.monotonic_ns(),
                             receiveDeadlineMonotonicNS=armed["deadlineMonotonicNS"],
                             receiveWindowSeconds=RECEIVE_SECONDS, chunks=chunks)
                received.clear(); mode = "received"; save(args.output / "export.json", proof)
            wait = .05
            if mode == "armed": wait = max(0, min(wait, (armed["deadlineMonotonicNS"] - time.monotonic_ns()) / 1e9))
            readable, _, _ = select.select([0, server], [], [], wait)
            if 0 in readable:
                data = os.read(0, PATH_LIMIT + 1)
                require(bool(data), "owned-PTY-closed")
                if mode != "armed" or len(received) + len(data) > PATH_LIMIT:
                    unexpected += len(data); received.clear()
                    raise ValueError("unexpected-or-overlong-terminal-input")
                received.extend(data); chunks.append(dict(bytes=len(data), ticks=int(now()), monotonicNS=time.monotonic_ns()))
            if server not in readable: continue
            with server.accept()[0] as peer:
                peer.settimeout(.5); request = bytearray()
                while not request.endswith(b"\n") and len(request) <= 4096:
                    part = peer.recv(4097 - len(request)); require(bool(part), "control-request-incomplete")
                    request.extend(part)
                require(len(request) <= 4096, "control-request-bound")
                value = json.loads(request)
                required = ({"capability", "op", "sequence", "timeout"} if value.get("op") == "drain" else
                            {"capability", "op", "boundary"} if value.get("op") == "verify-history" else {"capability", "op"})
                require(set(value) == required and value["capability"] == args.capability,
                        "control-capability-or-shape-differs")
                operation = value["op"]; require(len(controls) < 256, "control-count-bound")
                controls.append(dict(op=operation, ticks=int(now())))
                require(grid() == dict(columns=120, rows=36), "actual-grid-must-remain-120x36")
                if operation == "prepare":
                    require(mode == "ready" and args.payload is None, "prepare-must-be-singular")
                    prepared = write_all(preparation_bytes(spec))
                    prepared.update(expectation=spec, grid=grid()); mode = "prepared"
                    save(args.output / "prepared.json", prepared)
                elif operation == "drain":
                    require(mode == "ready" and payload is not None, "drain-requires-one-memory-payload")
                    require(type(value["sequence"]) is int and 0 <= value["sequence"] < 1000
                            and type(value["timeout"]) in (int, float) and 1 <= value["timeout"] <= 120,
                            "drain-parameters-outside-bound")
                    # This synchronous call temporarily owns our existing fd0;
                    # there is no second PTY handle, actor, thread or reader.
                    from terminal_bench_worker import drain
                    try: drained = drain(0, payload, value["sequence"], value["timeout"])
                    except Exception: raise ValueError("exact-generated-DSR-drain-failed") from None
                    prepared = dict(expectation=spec, grid=grid(), bytes=len(payload), sha256=digest(payload), drain=drained)
                    mode = "prepared"; save(args.output / "prepared.json", prepared)
                elif operation == "verify-history":
                    contract = authorize_phase(mode, args.verification_policy, spec, prepared, value["boundary"])
                    before = grid(); start_ns = time.perf_counter_ns(); start_ticks = int(now())
                    require(start_ns >= value["boundary"]["finishedMonotonicNS"], "verification-precedes-declared-boundary")
                    control_payload = bytes.fromhex(contract["payloadHex"])
                    response = b""
                    if control_payload:
                        from terminal_bench_worker import write_all as write_control, read_reply
                        limit = min(deadline, time.monotonic() + 5)
                        try:
                            write_control(0, control_payload, limit)
                            response = read_reply(0, bytes.fromhex(contract["expectedReplyHex"]), limit)
                        except Exception:
                            raise ValueError("verification-exact-DSR-failed") from None
                    after = grid(); end_ticks = int(now()); end_ns = time.perf_counter_ns()
                    verification = dict(schemaVersion=1, contract=contract, workerPID=os.getpid(), nonce=args.nonce,
                        drainFinishedMonotonicNS=prepared["drain"]["finishedMonotonicNS"], boundary=value["boundary"],
                        startedTicks=start_ticks, finishedTicks=end_ticks, startedMonotonicNS=start_ns, finishedMonotonicNS=end_ns,
                        gridBefore=before, gridAfter=after, writtenBytes=len(control_payload), responseHex=response.hex())
                    validate_phase(verification, spec, os.getpid(), prepared)
                    mode = "verified"; save(args.output / "verification-phase.json", verification)
                elif operation == "arm":
                    if args.verification_policy is None:
                        require(mode == "prepared", "arm-must-follow-one-preparation")
                    else: authorize_arm(mode, args.verification_policy)
                    before_inventory = inventory(args.temporary_directory)
                    arm_ticks, arm_ns = int(now()), time.monotonic_ns()
                    armed = dict(armedTicks=arm_ticks, armedMonotonicNS=arm_ns,
                                 deadlineMonotonicNS=arm_ns + RECEIVE_SECONDS * 1_000_000_000,
                                 beforeInventory=before_inventory)
                    if args.verification_policy is not None: armed["verificationPhase"] = verification
                    mode = "armed"; save(args.output / "arm.json", armed)
                elif operation == "status": pass
                elif operation == "finish":
                    require(mode == "received" and proof is not None, "finish-requires-complete-export")
                    running = False; reason = "controller-finish"
                elif operation == "abort": running = False; reason = "controller-abort"
                else: raise ValueError("unknown-control-operation")
                response = status()
                if operation == "drain": response.update(prepared["drain"])
                peer.sendall(json.dumps(response, separators=(",", ":")).encode() + b"\n")
    except BaseException as failure:
        # No repr/str from filesystem/JSON exceptions: neither arbitrary input,
        # a rejected path, nor unrecognized contents reach evidence/logs.
        error = str(failure) if type(failure) is ValueError and str(failure).replace("-", "").isalnum() else type(failure).__name__
        reason = "failed"; received.clear()
    finally:
        restore = dict(termiosRestored=False, fileFlagsRestored=False, terminalRestoreWritten=False)
        try: restore["terminalRestoreWritten"] = os.write(1, RESTORE) == len(RESTORE)
        except OSError: pass
        try:
            termios.tcsetattr(0, termios.TCSANOW, original); after = termios.tcgetattr(0)
            pending = list(original); pending[3] |= termios.PENDIN
            if after == pending and after != original:
                try: unexpected += len(os.read(0, PATH_LIMIT + 1))
                except BlockingIOError: pass
                after = termios.tcgetattr(0)
            restore.update(termiosRestored=after == original, ttyFlagsOriginal=original[:4], ttyFlagsAfter=after[:4])
            os.set_blocking(0, input_blocking); os.set_blocking(1, output_blocking)
            restore["fileFlagsRestored"] = os.get_blocking(0) == input_blocking and os.get_blocking(1) == output_blocking
        except (OSError, termios.error): pass
        server.close(); args.socket.unlink(missing_ok=True)
        valid = not error and reason == "controller-finish" and not unexpected and all(restore[key] for key in ("termiosRestored", "fileFlagsRestored", "terminalRestoreWritten"))
        save(args.output / "cleanup.json", dict(schemaVersion=1, status="pass" if valid else "failed", pid=os.getpid(),
             nonce=args.nonce, finishedTicks=int(now()), reason=reason, errorCode=error,
             inputBytesRetained=0, rejectedInputShapeRecorded=shape_recorded,
             unexpectedInputBytes=unexpected, controlSocketRemoved=not args.socket.exists(),
             controls=controls, **restore))
    return 0 if valid else 1


if __name__ == "__main__": raise SystemExit(main())
