#!/usr/bin/env python3
"""Owned raw-PTY fixture. Only bounded fixture controls are accepted."""
from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import sys
import termios
import time
import tty
from four_pane_evidence import descriptor_flags_match
import terminal_bench_pacing as pacing

RATE = 4_000_000
QUANTUM = 40_000
PERIOD_NS = 10_000_000
LINE = b"neutral pane output 0123456789abcdefghijklmnopqrstuvwxyz ABCD\r\n"
SETUP_COLORS = ((40, 160, 80), (200, 60, 80), (40, 100, 200), (160, 100, 40))
RESET = b"\x1b[0m\x1b[?25h\x1b[?1049l"


def atomic_json(path, value):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("x") as stream:
        json.dump(value, stream, separators=(",", ":"))
        stream.write("\n")
    os.replace(temporary, path)


def payload(offset, count):
    start = offset % len(LINE)
    return (LINE * ((start + count + len(LINE) - 1) // len(LINE)))[start:start + count]


def grid():
    size = os.get_terminal_size(0)
    return {"columns": size.columns, "rows": size.lines}


def restore_terminal(input_fd, output_fd, original_mode, original_flags):
    cleanup = {"unexpectedInputBytes": 0, "ttyFlagsOriginal": original_mode[:4],
               "descriptorFlagsOriginal": original_flags}
    try:
        termios.tcsetattr(input_fd, termios.TCSANOW, original_mode)
        after = termios.tcgetattr(input_fd)
        with_pending = list(original_mode)
        with_pending[3] |= termios.PENDIN
        if after != original_mode and after == with_pending:
            # Resolve Darwin's raw-to-canonical pending state with one bounded
            # nonblocking read. Bytes invalidate cleanup; none are flushed.
            os.set_blocking(input_fd, False)
            try:
                pending = os.read(input_fd, 65536)
                cleanup["unexpectedInputBytes"] = len(pending)
                cleanup["canonicalPendingRead"] = "bytes" if pending else "eof"
            except BlockingIOError:
                cleanup["canonicalPendingRead"] = "EAGAIN"
            after = termios.tcgetattr(input_fd)
        cleanup["ttyFlagsRestored"] = after[:4]
        cleanup["modeDifferenceIndices"] = [i for i in range(len(original_mode)) if after[i] != original_mode[i]]
        cleanup["termiosRestored"] = after == original_mode and cleanup["unexpectedInputBytes"] == 0
    except (OSError, termios.error) as error:
        cleanup.update(termiosRestored=False, termiosRestoredError=str(error))
    for fd in (input_fd, output_fd):
        try:
            fcntl.fcntl(fd, fcntl.F_SETFL, original_flags[str(fd)])
        except OSError as error:
            cleanup.setdefault("descriptorErrors", []).append(str(error))
    restored = {}
    for fd in (input_fd, output_fd):
        try:
            restored[str(fd)] = fcntl.fcntl(fd, fcntl.F_GETFL)
        except OSError as error:
            cleanup.setdefault("descriptorErrors", []).append(str(error))
    cleanup["descriptorFlagsRestored"] = restored
    cleanup["descriptorStatusPlatform"] = sys.platform
    cleanup["stdinRestored"] = descriptor_flags_match(original_flags[str(input_fd)], restored.get(str(input_fd)), sys.platform)
    cleanup["stdoutRestored"] = descriptor_flags_match(original_flags[str(output_fd)], restored.get(str(output_fd)), sys.platform)
    return cleanup


def fill(rgb):
    return f"\x1b[48;2;{rgb[0]};{rgb[1]};{rgb[2]}m\x1b[2J\x1b[H".encode()


def marker(sequence):
    size = grid()
    rgb = (48 + sequence % 16 * 11, 48 + sequence // 16 % 16 * 11, 211)
    return (f"\x1b[{max(1, size['rows'] // 2)};{max(1, size['columns'] // 2 - 4)}H"
            f"\x1b[48;2;{rgb[0]};{rgb[1]};{rgb[2]}m        \x1b[0m").encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--socket-directory", required=True, type=Path)
    parser.add_argument("--run-token", required=True)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600 or not re.fullmatch(r"[a-f0-9]{32}", args.run_token):
        parser.error("timeout must be 1...600 seconds and token must be 32 hex digits")
    if args.socket_directory.is_symlink() or not args.socket_directory.is_dir():
        parser.error("socket directory must be the existing owned directory")
    try:
        args.output.mkdir(mode=0o700)
        slot = 0
        atomic_json(args.output / "claim.json", {"runToken": args.run_token})
    except FileExistsError:
        if (args.output.is_symlink() or not args.output.is_dir()
                or json.loads((args.output / "claim.json").read_text()).get("runToken") != args.run_token):
            parser.error("existing fixture directory does not belong to this run")
        slot = None
        for index in range(1, 4):
            try:
                with (args.output / f"slot-{index}.claim").open("x") as stream:
                    stream.write(str(os.getpid()))
                slot = index
                break
            except FileExistsError:
                pass
        if slot is None:
            parser.error("all four fixture roles are already claimed")

    started = time.monotonic_ns()
    deadline = started + int(args.timeout * 1e9)
    saved = termios.tcgetattr(0)
    original_flags = {str(fd): fcntl.fcntl(fd, fcntl.F_GETFL) for fd in (0, 1)}
    socket_path = args.socket_directory / f"w-{os.getpid()}.sock"
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(socket_path))
    os.chmod(socket_path, 0o600)
    server.listen(4)
    server.setblocking(False)
    metadata = {"schemaVersion": 1, "pid": os.getpid(), "parentPID": os.getppid(),
                "workerSourceSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "pacingSourceSHA256": hashlib.sha256(Path(pacing.__file__).read_bytes()).hexdigest(),
                "pacingPolicy": pacing.PACING_POLICY,
                "runToken": args.run_token, "slot": slot, "role": "marker" if slot == 0 else "busy",
                "ttyPath": os.ttyname(0), "socketPath": str(socket_path), "initialGrid": grid(),
                "startedMonotonicNs": started, "requestedBytesPerSecond": 0 if slot == 0 else RATE,
                "quantumBytes": QUANTUM, "periodNs": PERIOD_NS,
                "payloadPeriodSHA256": hashlib.sha256(LINE).hexdigest(), "payloadPeriodHex": LINE.hex()}
    offers, writes, received, geometry = [], [], [], []
    setup_keys = []
    pending = memoryview(b"")
    completed = 0
    active_start = None
    active_grid = None
    next_due = None
    sequence = 0
    running = True
    mode = "setup"
    stop_reason = None
    repaint_received_ns = None
    hold_exit = False

    def stop(reason):
        nonlocal running, stop_reason
        running = False
        if stop_reason is None:
            stop_reason = reason

    def resized(*_):
        nonlocal repaint_received_ns
        # Preserve signal receipt time even if the write loop handles it later.
        repaint_received_ns = time.monotonic_ns()

    def control_write(data):
        remaining = memoryview(data)
        until = min(deadline, time.monotonic_ns() + 500_000_000)
        while remaining and running and time.monotonic_ns() < until:
            try:
                count = os.write(1, remaining)
                if count <= 0:
                    raise OSError(errno.EIO, "empty terminal write")
                remaining = remaining[count:]
            except BlockingIOError:
                select.select([], [1], [], 0.01)
            except InterruptedError:
                continue
        if remaining:
            stop("control-write-timeout")

    def status():
        return {"ok": True, "pid": os.getpid(), "slot": slot, "role": metadata["role"],
                "runToken": args.run_token, "mode": mode, "grid": grid(),
                "setupKeys": setup_keys, "receivedCount": len(received),
                "activeStartNs": active_start, "completedBytes": completed}

    def control(connection):
        nonlocal mode, active_start, active_grid, next_due, hold_exit
        connection.settimeout(0.2)
        raw = bytearray()
        while not raw.endswith(b"\n") and len(raw) <= 4096:
            chunk = connection.recv(4096)
            if not chunk:
                break
            raw.extend(chunk)
        try:
            request = json.loads(raw)
            if request.get("runToken") != args.run_token:
                raise ValueError("wrong run token")
            operation = request.get("op")
            if operation == "status":
                response = status()
            elif operation == "arm" and mode == "setup":
                target = request.get("startNs")
                now = time.monotonic_ns()
                if type(target) is not int or not now + 20_000_000 <= target <= now + 5_000_000_000:
                    raise ValueError("arm needs a future monotonic start within five seconds")
                active_grid = grid()
                mode = "armed"
                active_start = target
                next_due = target
                control_write(b"\x1b[0m\x1b[38;2;170;170;170m\x1b[48;2;16;16;16m\x1b[2J\x1b[H")
                if slot == 0:
                    control_write(marker(0))
                response = status()
            elif operation == "stop":
                if type(request.get("holdExit", False)) is not bool:
                    raise ValueError("holdExit must be a boolean")
                hold_exit = request.get("holdExit", False)
                response = status()
                stop("control-stop")
            else:
                raise ValueError("unknown operation or invalid fixture state")
        except (ValueError, TypeError) as error:
            response = {"ok": False, "error": str(error)}
        connection.sendall(json.dumps(response).encode() + b"\n")

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, lambda number, _: stop("signal-" + signal.Signals(number).name))
    signal.signal(signal.SIGWINCH, resized)
    pacer = None
    try:
        if slot != 0:
            pacer = pacing.CriticalTimer()
        tty.setraw(0)
        os.set_blocking(1, False)
        control_write(b"\x1b[?1049h\x1b[?25l" + fill(SETUP_COLORS[slot]))
        metadata["readyMonotonicNs"] = time.monotonic_ns()
        atomic_json(args.output / f"worker-{slot}.json", metadata)
        if slot == 0:
            atomic_json(args.output / "ready.json", {**metadata, **metadata["initialGrid"]})
        while running and time.monotonic_ns() < deadline:
            now = time.monotonic_ns()
            if repaint_received_ns is not None:
                geometry.append({"monotonicNs": repaint_received_ns, "grid": grid()})
                repaint_received_ns = None
                if mode == "setup":
                    control_write(fill(SETUP_COLORS[slot]))
                elif slot == 0:
                    control_write(marker(sequence))
            if mode == "armed" and now >= active_start:
                mode = "active"
            if slot != 0 and mode == "active" and now >= next_due and not pending:
                index = len(offers)
                offset = index * QUANTUM
                offers.append([index, active_start + index * PERIOD_NS, now, offset, QUANTUM])
                pending = memoryview(payload(offset, QUANTUM))
                # Late service does not create a catch-up burst or drop bytes.
                next_due = now + PERIOD_NS
            wait_ns = min(50_000_000, max(0, deadline - now))
            if mode == "armed":
                wait_ns = min(wait_ns, max(0, active_start - now))
            elif slot != 0 and mode == "active" and not pending:
                wait_ns = min(wait_ns, max(0, next_due - now))
                # Service controls immediately when ready. Otherwise wait on a
                # strict one-shot timer; select's coalesced timeout can turn a
                # 10 ms offer period into 12+ ms even with no app backpressure.
                ready, _, _ = select.select([0, server], [], [], 0)
                if not ready:
                    pacer.wait_until(min(deadline, next_due))
                    continue
                wait_ns = 0
            readable, writable, _ = select.select([0, server], [1] if pending else [], [], wait_ns / 1e9)
            if server in readable:
                connection, _ = server.accept()
                with connection:
                    try:
                        control(connection)
                    except (OSError, TimeoutError):
                        pass  # untrusted/incomplete control cannot hang the PTY
            if 0 in readable:
                data = os.read(0, 4096)
                if not data:
                    stop("pty-eof")
                for value in data:
                    if value in (3, 4, ord("q")):
                        stop("input-stop")
                    elif mode == "setup":
                        setup_keys.append(value)
                        if len(setup_keys) > 4096:
                            stop("setup-input-limit")
                    else:
                        stamp = time.monotonic_ns()
                        if slot == 0 and value == ord("a") and mode == "active":
                            sequence += 1
                            control_write(marker(sequence))
                            received.append({"sequence": sequence, "byte": value,
                                             "receivedMonotonicNs": stamp,
                                             "repliedMonotonicNs": time.monotonic_ns(), "replied": running})
                        else:
                            received.append({"byte": value, "receivedMonotonicNs": stamp, "unexpected": True})
                        if len(received) > 1000:
                            stop("measured-input-limit")
            if running and pending and 1 in writable:
                before = time.monotonic_ns()
                try:
                    count = os.write(1, pending)
                except BlockingIOError:
                    continue
                except InterruptedError:
                    continue
                after = time.monotonic_ns()
                if count <= 0:
                    raise OSError(errno.EIO, "empty terminal write")
                writes.append([len(offers) - 1, completed, count, before, after])
                completed += count
                pending = pending[count:]
                if len(writes) > 600_000 or len(offers) > 60_001:
                    stop("receipt-limit")
        if stop_reason is None:
            stop("timeout")
    except OSError as error:
        stop("pty-disconnected" if error.errno in (errno.EIO, errno.ENXIO, errno.EBADF) else "os-error")
        metadata["error"] = {"errno": error.errno, "message": str(error)}
    finally:
        if pacer is not None:
            pacer.close()
        metadata["pacingTimerClosed"] = pacer is None or pacer.closed
        stopped = time.monotonic_ns()
        final_grid = None
        try:
            final_grid = grid()
        except OSError:
            pass
        if repaint_received_ns is not None:
            geometry.append({"monotonicNs": repaint_received_ns, "grid": final_grid})
        try:
            os.write(1, RESET)
        except OSError:
            pass
        cleanup = restore_terminal(0, 1, saved, original_flags)
        server.close()
        socket_path.unlink(missing_ok=True)
        final_path = args.output / f"final-{slot}.json"
        atomic_json(final_path, {
            **metadata, "status": "stopped", "stopReason": stop_reason,
            "exitBarrierRequested": hold_exit,
            "stoppedMonotonicNs": stopped, "activeStartNs": active_start,
            "activeGrid": active_grid, "finalGrid": final_grid, "geometryChanges": geometry,
            "setupKeys": setup_keys, "received": received, "offers": offers, "writes": writes,
            "offeredBytes": len(offers) * QUANTUM, "completedBytes": completed,
            "pendingBytes": len(pending), "cleanup": cleanup})
        if hold_exit:
            # Keep the restored PTY alive until every pane has saved its final
            # grid. Exiting the first worker can otherwise close its split and
            # resize the remaining panes during their cleanup.
            final_sha = hashlib.sha256(final_path.read_bytes()).hexdigest()
            release_path = args.output / "exit-release.json"
            exit_record = {"pid": os.getpid(), "slot": slot, "runToken": args.run_token,
                           "status": "release-timeout"}
            until = time.monotonic() + 5
            while time.monotonic() < until:
                if release_path.exists():
                    release_bytes = release_path.read_bytes()
                    release = json.loads(release_bytes)
                    if (release.get("runToken") == args.run_token
                            and release.get("workerPIDs", {}).get(str(slot)) == os.getpid()
                            and release.get("finalSHA256", {}).get(str(slot)) == final_sha):
                        exit_record.update(status="released", releaseMonotonicNs=release["releaseMonotonicNs"],
                                           releaseSHA256=hashlib.sha256(release_bytes).hexdigest())
                        break
                    exit_record["status"] = "invalid-release"
                    break
                time.sleep(.01)
            exit_record["exitingMonotonicNs"] = time.monotonic_ns()
            atomic_json(args.output / f"exit-{slot}.json", exit_record)


if __name__ == "__main__":
    main()
