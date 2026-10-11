#!/usr/bin/env python3
"""Draft raw TTY fixture. Native wheel input must be consumed by scrollback UI.

Imports only the frozen sibling transport helper retained by the controller.
The socket is setup/control only: it never acknowledges a visual scroll.
"""
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
import scroll_protocol
import terminal_bench_worker

from scroll_protocol import GRID, HISTORY_ROWS, payload, validate_token
from terminal_bench_worker import atomic_json, grid, read_reply, write_all


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    validate_token(args.token)
    if args.timeout <= 0 or len(os.fsencode(args.socket)) >= 100:
        parser.error("bounded timeout and a short private socket path are required")
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    if args.socket.exists():
        raise ValueError("refusing to replace an existing control socket")
    fd = 0
    original = termios.tcgetattr(fd)
    original_blocking = os.get_blocking(fd)
    state = {"schemaVersion": 1, "benchmarkKind": "scroll", "status": "starting",
             "pid": os.getpid(), "parentPID": os.getppid(), "ttyPath": os.ttyname(fd),
             "token": args.token, "startedMonotonicNS": time.monotonic_ns(),
             "ttyFlagsOriginal": original[:4],
             "workerSourceSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             "protocolSourceSHA256": hashlib.sha256(Path(scroll_protocol.__file__).read_bytes()).hexdigest(),
             "transportSourceSHA256": hashlib.sha256(Path(terminal_bench_worker.__file__).read_bytes()).hexdigest(),
             "historyRows": HISTORY_ROWS, "unexpectedInputBytes": 0, "gridChecks": []}
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stop_requested = False

    def request_stop(_signal, _frame):
        nonlocal stop_requested
        state["stopReason"] = "signal"
        stop_requested = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    failed = False
    try:
        tty.setraw(fd, when=termios.TCSANOW)
        os.set_blocking(fd, False)
        server.bind(str(args.socket))
        os.chmod(args.socket, 0o600)
        server.listen(1)
        state.update(status="ready", readyMonotonicNS=time.monotonic_ns(),
                     ttyFlagsRaw=termios.tcgetattr(fd)[:4], **grid(fd))
        atomic_json(args.output / "ready.json", state)
        deadline = time.monotonic() + args.timeout
        prepared = False
        while not stop_requested:
            if time.monotonic() >= deadline:
                raise TimeoutError("fixture lifetime expired")
            readable, _, _ = select.select([server, fd], [], [], min(0.1, deadline - time.monotonic()))
            if fd in readable:
                unexpected = os.read(fd, 65536)
                if not unexpected:
                    raise EOFError("owned PTY closed")
                # Do not retain arbitrary keyboard bytes, even in this owned
                # window. A count is enough to invalidate unexpected PTY input.
                state["unexpectedInputBytes"] += len(unexpected)
                raise ValueError("unexpected input reached the raw fixture")
            if server not in readable:
                continue
            with server.accept()[0] as peer:
                peer.settimeout(2)
                request = bytearray()
                while not request.endswith(b"\n") and len(request) <= 2048:
                    part = peer.recv(2048 - len(request))
                    if not part:
                        break
                    request.extend(part)
                command = json.loads(request)
                if not isinstance(command, dict) or set(command) != {"command", "token"} or command["token"] != args.token:
                    raise ValueError("invalid generated control request")
                actual = grid(fd)
                state["gridChecks"].append(actual)
                if command["command"] == "prepare":
                    if prepared or (actual["columns"], actual["rows"]) != GRID:
                        raise ValueError("prepare requires the final grid and occurs exactly once")
                    data = payload(args.token)
                    write_all(fd, data, time.monotonic() + 30)
                    # Cursor movement and exact DSR are setup proof only. This
                    # does not affect cell contents or claim a visible frame.
                    query = b"\x1b[36;1H\x1b[6n"
                    expected = b"\x1b[36;1R"
                    write_all(fd, query, time.monotonic() + 5)
                    try:
                        reply = read_reply(fd, expected, time.monotonic() + 5)
                    except Exception:
                        # The shared validator's raw diagnostic may contain
                        # unexpected keystrokes. Do not export that diagnostic.
                        raise ValueError("generated preparation DSR rejected") from None
                    prepared = True
                    state.update(status="prepared", payloadBytes=len(data),
                                 payloadSHA256=hashlib.sha256(data).hexdigest(),
                                 dsrQueryHex=query.hex(), dsrReplyHex=reply.hex(),
                                 preparedMonotonicNS=time.monotonic_ns())
                    atomic_json(args.output / "prepared.json", state)
                elif command["command"] == "probe":
                    if not prepared or (actual["columns"], actual["rows"]) != GRID:
                        raise ValueError("fixture is unprepared or its grid changed")
                elif command["command"] == "finish":
                    if not prepared:
                        raise ValueError("unprepared fixture cannot finish")
                    stop_requested = True
                    state["stopReason"] = "control-finish"
                else:
                    raise ValueError("unknown generated control request")
                peer.sendall(json.dumps({"ok": True, "status": state["status"],
                                         "grid": actual, "unexpectedInputBytes": 0}).encode() + b"\n")
        state["status"] = "stopped" if prepared and state.get("stopReason") == "control-finish" else "invalid"
    except Exception as error:
        failed = True
        state.update(status="invalid", errorType=type(error).__name__)
    finally:
        state["finishedMonotonicNS"] = time.monotonic_ns()
        try:
            state["gridAfter"] = grid(fd)
            termios.tcsetattr(fd, termios.TCSANOW, original)
            after_mode = termios.tcgetattr(fd)
            expected_with_pending = list(original)
            expected_with_pending[3] |= termios.PENDIN
            if after_mode == expected_with_pending and after_mode != original:
                # Darwin marks the raw->canonical transition as PENDIN until
                # its next read. A single nonblocking read lets the kernel
                # resolve that state; do not mask flags or flush unread input.
                # Any actual bytes still invalidate the owned fixture.
                try:
                    pending = os.read(fd, 65536)
                    state["unexpectedInputBytes"] += len(pending)
                    state["canonicalPendingRead"] = "bytes" if pending else "eof"
                except BlockingIOError:
                    state["canonicalPendingRead"] = "EAGAIN"
                after_mode = termios.tcgetattr(fd)
            state["ttyFlagsRestored"] = after_mode[:4]
            state["modeDifferenceIndices"] = [index for index in range(len(original)) if original[index] != after_mode[index]]
            state["terminalModeRestored"] = after_mode == original
        except (OSError, termios.error) as error:
            state["terminalModeRestored"] = False
            state["modeRestorationErrno"] = error.args[0] if error.args and type(error.args[0]) is int else None
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
