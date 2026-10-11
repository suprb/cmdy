#!/usr/bin/env python3
"""Identical raw-PTY fixture for terminal benchmarks. No terminal-specific API."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import termios
import time
import tty


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def grid(fd: int) -> dict[str, int]:
    rows, columns, xpixel, ypixel = struct.unpack(
        "HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))
    return dict(rows=rows, columns=columns, xpixel=xpixel, ypixel=ypixel)


def expected_reply(rows: int, columns: int, sequence: int) -> tuple[bytes, bytes]:
    """A changing cursor destination rejects a stale reply from an earlier trial."""
    if rows < 4 or columns < 10 or sequence < 0:
        raise ValueError("grid must be at least 10 columns by 4 rows; sequence >= 0")
    row = 2 + sequence % (rows - 1)
    column = 2 + (sequence // (rows - 1)) % (columns - 1)
    return (f"\x1b[{row};{column}H\x1b[6n".encode(),
            f"\x1b[{row};{column}R".encode())


def write_all(fd: int, data: bytes, deadline: float) -> None:
    remaining = memoryview(data)
    while remaining:
        timeout = deadline - time.monotonic()
        if timeout <= 0 or not select.select([], [fd], [], timeout)[1]:
            raise TimeoutError("PTY write timed out")
        try:
            count = os.write(fd, remaining[:65536])
        except BlockingIOError:
            continue
        if count <= 0:
            raise EOFError("PTY closed during write")
        remaining = remaining[count:]


def read_reply(fd: int, expected: bytes, deadline: float) -> bytes:
    """Accept only the complete, exact DSR response, including ESC and final R.

    A bare R, truncated response, echoed CSI 6 n, extra bytes, and a wrong cursor
    destination are failures. No text decoding, regex search, or suffix match.
    """
    reply = bytearray()
    while bytes(reply) != expected:
        timeout = deadline - time.monotonic()
        if timeout <= 0 or not select.select([fd], [], [], timeout)[0]:
            raise TimeoutError(f"incomplete DSR reply: {bytes(reply).hex()}")
        try:
            chunk = os.read(fd, 128)
        except BlockingIOError:
            continue
        if not chunk:
            raise EOFError(f"PTY closed during DSR reply: {bytes(reply).hex()}")
        reply.extend(chunk)
        if not expected.startswith(reply):
            raise ValueError(f"unexpected DSR bytes: {bytes(reply).hex()}; "
                             f"expected {expected.hex()}")
    if select.select([fd], [], [], 0)[0]:
        extra = os.read(fd, 128)
        if extra:
            raise ValueError(f"extra bytes after DSR reply: {extra.hex()}")
    return bytes(reply)


def drain(fd: int, payload: bytes, sequence: int, timeout: float) -> dict:
    before = grid(fd)
    footer, expected = expected_reply(before["rows"], before["columns"], sequence)
    termios.tcflush(fd, termios.TCIFLUSH)
    deadline = time.monotonic() + timeout
    # Reset history/screen and establish parser readiness outside the timer.
    # Raw mode disables ONLCR: both emulators receive the exact payload bytes.
    write_all(fd, b"\x1b[?7h\x1b[0m\x1b[?25l\x1b[3J\x1b[2J\x1b[H\x1b[6n", deadline)
    read_reply(fd, b"\x1b[1;1R", deadline)
    started = time.perf_counter_ns()
    deadline = time.monotonic() + timeout
    write_all(fd, payload, deadline)
    write_all(fd, footer, deadline)
    reply = read_reply(fd, expected, deadline)
    finished = time.perf_counter_ns()
    after = grid(fd)
    if before != after:
        raise ValueError(f"terminal geometry changed during drain: {before} -> {after}")
    return {"sequence": sequence, "elapsedNS": finished - started,
            "startedMonotonicNS": started, "finishedMonotonicNS": finished,
            "payloadBytes": len(payload), "footerHex": footer.hex(),
            "responseHex": reply.hex(), "expectedResponseHex": expected.hex(),
            "gridBefore": before, "gridAfter": after}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    payload = args.payload.read_bytes()
    fd = os.open("/dev/tty", os.O_RDWR | os.O_NONBLOCK)
    saved = termios.tcgetattr(fd)
    server = socket.socket(socket.AF_UNIX)
    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    try:
        tty.setraw(fd, termios.TCSANOW)
        server.bind(args.socket)
        server.listen(1)
        atomic_json(args.directory / "ready.json", {
            "workerPID": os.getpid(), "parentPID": os.getppid(),
            "ttyPath": os.ttyname(fd),
            "readyMonotonicNS": time.perf_counter_ns(), "grid": grid(fd),
            "termProgram": os.environ.get("TERM_PROGRAM"),
            "payloadBytes": len(payload), "payloadSHA256": hashlib.sha256(payload).hexdigest(),
            "ttyFlagsBefore": saved[:6], "ttyFlagsRaw": termios.tcgetattr(fd)[:6],
            "onlcrEnabled": bool(termios.tcgetattr(fd)[1] & termios.ONLCR),
            "outputPostprocessingEnabled": bool(termios.tcgetattr(fd)[1] & termios.OPOST),
            "clock": "time.perf_counter_ns (monotonic)", "socket": args.socket,
        })
        while True:
            connection, _ = server.accept()
            with connection:
                connection.settimeout(5)
                data = bytearray()
                while not data.endswith(b"\n"):
                    chunk = connection.recv(4096)
                    if not chunk or len(data) + len(chunk) > 16384:
                        raise ValueError("invalid control request")
                    data.extend(chunk)
                request = json.loads(data)
                try:
                    command = request["command"]
                    if command == "quit":
                        connection.sendall(b'{"ok": true}\n')
                        return 0
                    if command == "grid":
                        result = {"grid": grid(fd)}
                    elif command == "drain":
                        result = drain(fd, payload, int(request["sequence"]),
                                       float(request.get("timeout", 60)))
                    else:
                        raise ValueError(f"unknown command: {command}")
                    connection.sendall(json.dumps({"ok": True, **result}).encode() + b"\n")
                except Exception as error:
                    connection.sendall(json.dumps({"ok": False, "error": str(error)}).encode() + b"\n")
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)
        os.close(fd)
        server.close()
        Path(args.socket).unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
