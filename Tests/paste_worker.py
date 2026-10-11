#!/usr/bin/env python3
"""Owned raw-TTY paste receiver. Never uses a clipboard or launches an app."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import termios
import time
import tty

import paste_protocol
import scroll_protocol
import terminal_bench_worker
from paste_protocol import (ENABLED_ROW, GRID, SAMPLES, WARMUPS, ExactPasteReceiver,
                            expected_receipt, preparation, viewport_bytes, validate_token)
from terminal_bench_worker import atomic_json, grid, read_reply, write_all


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    validate_token(args.token)
    if not 0 < args.timeout <= 600 or len(os.fsencode(args.socket)) >= 100:
        parser.error("bounded timeout and short private socket path required")
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    if args.socket.exists():
        raise ValueError("refusing to replace existing control socket")
    fd = 0
    original, original_blocking = termios.tcgetattr(fd), os.get_blocking(fd)
    state = {"schemaVersion": 1, "benchmarkKind": "paste", "status": "starting",
             "pid": os.getpid(), "parentPID": os.getppid(), "ttyPath": os.ttyname(fd),
             "token": args.token, "startedMonotonicNS": time.monotonic_ns(),
             "ttyFlagsOriginal": original[:4], "unexpectedInputBytes": 0,
             "acceptedPastes": 0, "offProbeVerified": False, "bracketModeEnabled": False,
             "gridChecks": [], "receipts": [],
             "sourceSHA256": {name: hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest()
                              for name, module in (("paste_worker.py", __import__(__name__)),
                                  ("paste_protocol.py", paste_protocol), ("scroll_protocol.py", scroll_protocol),
                                  ("terminal_bench_worker.py", terminal_bench_worker))}}
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stopping, failed, prepared = False, False, False
    receiver, sequence, receiving_started = None, None, None

    def stop(_signal, _frame):
        nonlocal stopping
        state["stopReason"] = "signal"
        stopping = True

    def response(actual):
        return {"ok": True, "status": state["status"], "grid": actual,
                "unexpectedInputBytes": state["unexpectedInputBytes"],
                "acceptedPastes": state["acceptedPastes"], "offProbeVerified": state["offProbeVerified"],
                "bracketModeEnabled": state["bracketModeEnabled"],
                "armedSequence": sequence, "receivedBytes": receiver.count if receiver else 0}

    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    try:
        tty.setraw(fd, when=termios.TCSANOW)
        os.set_blocking(fd, False)
        server.bind(str(args.socket)); os.chmod(args.socket, 0o600); server.listen(1)
        state.update(status="ready", readyMonotonicNS=time.monotonic_ns(),
                     ttyFlagsRaw=termios.tcgetattr(fd)[:4], **grid(fd))
        atomic_json(args.output / "ready.json", state)
        deadline = time.monotonic() + args.timeout
        while not stopping:
            if time.monotonic() >= deadline:
                raise TimeoutError("fixture lifetime expired")
            readable, _, _ = select.select([server, fd], [], [], min(0.1, deadline - time.monotonic()))
            if fd in readable:
                data = os.read(fd, 65536)
                if not data:
                    raise EOFError("owned PTY closed")
                try:
                    if receiver is None:
                        raise ValueError("input arrived without an armed expected paste")
                    receiving_started = receiving_started or time.monotonic_ns()
                    complete = receiver.feed(data)
                except ValueError:
                    state["unexpectedInputBytes"] += len(data)
                    raise
                if complete:
                    actual = grid(fd)
                    if (actual["columns"], actual["rows"]) != GRID:
                        raise ValueError("native grid changed during paste")
                    record = expected_receipt(args.token, sequence)
                    record.update(receiveStartedMonotonicNS=receiving_started,
                                  verifiedMonotonicNS=time.monotonic_ns(), grid=actual)
                    # This write follows full, exact wire validation. Its local
                    # timestamps do not acknowledge a visible response frame.
                    output = viewport_bytes(args.token, record["responseFirstRow"])
                    record["emitStartedMonotonicNS"] = time.monotonic_ns()
                    write_all(fd, output, time.monotonic() + 10)
                    record["emitFinishedMonotonicNS"] = time.monotonic_ns()
                    state["receipts"].append(record)
                    if sequence == 0:
                        state["offProbeVerified"] = True
                    else:
                        state["acceptedPastes"] = sequence
                    atomic_json(args.output / f"receipt-{sequence:02d}.json", record)
                    receiver, sequence, receiving_started = None, None, None
            if server not in readable:
                continue
            with server.accept()[0] as peer:
                peer.settimeout(2)
                raw = bytearray()
                while not raw.endswith(b"\n") and len(raw) < 2048:
                    part = peer.recv(2048 - len(raw))
                    if not part:
                        break
                    raw.extend(part)
                request = json.loads(raw)
                if not isinstance(request, dict) or set(request) != {"command", "token"} or request["token"] != args.token:
                    raise ValueError("invalid generated control request")
                actual = grid(fd); state["gridChecks"].append(actual)
                if (actual["columns"], actual["rows"]) != GRID:
                    raise ValueError("control requires the exact native grid")
                command = request["command"]
                if command == "prepare":
                    if prepared:
                        raise ValueError("prepare occurs exactly once")
                    output = preparation(args.token)
                    write_all(fd, output, time.monotonic() + 10)
                    query, expected = b"\x1b[36;1H\x1b[6n", b"\x1b[36;1R"
                    write_all(fd, query, time.monotonic() + 5)
                    try:
                        reply = read_reply(fd, expected, time.monotonic() + 5)
                    except Exception:
                        raise ValueError("generated preparation DSR rejected") from None
                    prepared = True
                    state.update(status="prepared", payloadBytes=len(output),
                                 payloadSHA256=hashlib.sha256(output).hexdigest(),
                                 dsrQueryHex=query.hex(), dsrReplyHex=reply.hex(),
                                 preparedMonotonicNS=time.monotonic_ns())
                    atomic_json(args.output / "prepared.json", state)
                elif command == "enable-bracketed":
                    if not prepared or not state["offProbeVerified"] or state["bracketModeEnabled"] or receiver:
                        raise ValueError("bracket mode can only follow the verified off probe")
                    write_all(fd, b"\x1b[?2004h" + viewport_bytes(args.token, ENABLED_ROW), time.monotonic() + 10)
                    state["bracketModeEnabled"] = True
                elif isinstance(command, str) and command.startswith("arm-"):
                    number = command.removeprefix("arm-")
                    if not number.isdecimal() or str(int(number)) != number:
                        raise ValueError("invalid expected paste sequence")
                    next_sequence = int(number)
                    expected_sequence = state["acceptedPastes"] + 1 if state["bracketModeEnabled"] else 0
                    if (not prepared or receiver is not None or next_sequence != expected_sequence
                        or (next_sequence == 0 and state["offProbeVerified"])
                        or next_sequence > WARMUPS + SAMPLES):
                        raise ValueError("paste sequence is unprepared, repeated, or out of order")
                    receiver, sequence = ExactPasteReceiver(args.token, next_sequence), next_sequence
                    receiving_started = None
                elif command == "probe":
                    if not prepared:
                        raise ValueError("unprepared fixture")
                elif command == "finish":
                    if not prepared or receiver or state["acceptedPastes"] != WARMUPS + SAMPLES:
                        raise ValueError("incomplete paste fixture cannot finish")
                    state["stopReason"] = "control-finish"; stopping = True
                else:
                    raise ValueError("unknown generated control request")
                peer.sendall(json.dumps(response(actual)).encode() + b"\n")
        state["status"] = "stopped" if state.get("stopReason") == "control-finish" else "invalid"
    except Exception as error:
        failed = True
        state.update(status="invalid", errorType=type(error).__name__)
    finally:
        state["incompleteSequence"] = sequence
        state["incompleteBytes"] = receiver.count if receiver else 0
        state["finishedMonotonicNS"] = time.monotonic_ns()
        try:
            state["gridAfter"] = grid(fd)
            termios.tcsetattr(fd, termios.TCSANOW, original)
            after_mode = termios.tcgetattr(fd)
            with_pending = list(original); with_pending[3] |= termios.PENDIN
            if after_mode == with_pending and after_mode != original:
                try:
                    pending = os.read(fd, 65536)
                    state["unexpectedInputBytes"] += len(pending)
                    state["canonicalPendingRead"] = "bytes" if pending else "eof"
                except BlockingIOError:
                    state["canonicalPendingRead"] = "EAGAIN"
                after_mode = termios.tcgetattr(fd)
            state["ttyFlagsRestored"] = after_mode[:4]
            state["modeDifferenceIndices"] = [i for i in range(len(original)) if original[i] != after_mode[i]]
            state["terminalModeRestored"] = after_mode == original
        except (OSError, termios.error):
            state["terminalModeRestored"] = False
        try:
            os.set_blocking(fd, original_blocking)
            state["fileFlagsRestored"] = os.get_blocking(fd) == original_blocking
        except OSError:
            state["fileFlagsRestored"] = False
        server.close()
        if args.socket.exists():
            args.socket.unlink()
        if not state.get("terminalModeRestored") or not state.get("fileFlagsRestored") or state["unexpectedInputBytes"]:
            state["status"] = "invalid"
        atomic_json(args.output / "final.json", state)
    return 1 if failed or state["status"] != "stopped" else 0


if __name__ == "__main__":
    raise SystemExit(main())
