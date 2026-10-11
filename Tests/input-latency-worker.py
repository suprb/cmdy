#!/usr/bin/env python3
"""Raw TTY marker and paced busy-pane fixtures; no shell commands are accepted."""
import argparse
import errno
import json
import os
from pathlib import Path
import select
import signal
import termios
import time
import tty


MAX_SECONDARY_RATE = 20_000_000
MAX_WRITE = 64 * 1024
RESET = b"\x1b[0m\x1b[?25h\x1b[?1049l"
NEUTRAL_LINE = b"background fixture output 0123456789abcdefghijklmnopqrstuvwxyz\r\n"
NEUTRAL_OUTPUT = memoryview((NEUTRAL_LINE * (MAX_WRITE // len(NEUTRAL_LINE) + 1))[:MAX_WRITE])


def color(sequence):
    return 48 + (sequence % 16) * 11, 48 + ((sequence // 16) % 16) * 11, 211


def marker(sequence, mode="full-screen"):
    red, green, blue = color(sequence)
    background_sgr = f"\x1b[48;2;{red};{green};{blue}m"
    if mode == "local-row":
        size = os.get_terminal_size(0)
        row, column = max(1, size.lines // 2), max(1, size.columns // 2 - 4)
        return (f"\x1b[{row};{column}H" + background_sgr + " " * 8 + "\x1b[0m").encode()
    return (background_sgr + "\x1b[2J\x1b[H").encode()


def write_json(path, value):
    """Publish complete readiness/final evidence for the harness's reader."""
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    os.replace(temporary, path)


def write_terminal(data, deadline, keep_running):
    """Finish a small control/marker write without hanging on a full PTY."""
    remaining = memoryview(data)
    while remaining and keep_running() and time.monotonic() < deadline:
        try:
            count = os.write(1, remaining)
            if count == 0:
                raise OSError(errno.EIO, "terminal write made no progress")
            remaining = remaining[count:]
        except BlockingIOError:
            select.select([], [1], [], min(0.05, max(0, deadline - time.monotonic())))
        except InterruptedError:
            continue
    return not remaining


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--secondary-load", type=int, default=0, metavar="BYTES_PER_SECOND")
    parser.add_argument("--marker-mode", choices=("full-screen", "local-row"), default="full-screen")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600:
        parser.error("timeout must be 1...600 seconds")
    if not 0 <= args.secondary_load <= MAX_SECONDARY_RATE:
        parser.error(f"secondary load must be 0...{MAX_SECONDARY_RATE} bytes per second")
    try:
        args.output.mkdir(parents=True, exist_ok=False)
        role = "marker"
    except FileExistsError:
        if args.secondary_load == 0 or args.output.is_symlink() or not args.output.is_dir():
            parser.error("output already exists; a secondary requires a fixture directory and --secondary-load > 0")
        role = "busy"

    saved = termios.tcgetattr(0)
    stdout_was_blocking = os.get_blocking(1)
    size = os.get_terminal_size(0)
    started = time.monotonic()
    started_ns = time.monotonic_ns()
    deadline = started + args.timeout
    metadata = {"pid": os.getpid(), "parentPID": os.getppid(), "role": role,
                "rows": size.lines, "columns": size.columns, "ttyPath": os.ttyname(0),
                "startedMonotonicNs": started_ns, "markerMode": args.marker_mode}
    busy_path = args.output / f"busy-{os.getpid()}.json"
    received = []
    sequence = 0
    bytes_written = 0
    running = True
    repaint = False
    stop_reason = None

    def stop(reason):
        nonlocal running, stop_reason
        running = False
        if stop_reason is None:
            stop_reason = reason

    def signal_stop(signum, _):
        stop("signal-" + signal.Signals(signum).name)

    def resized(*_):
        nonlocal repaint
        repaint = role == "marker"

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, signal_stop)
    signal.signal(signal.SIGWINCH, resized)

    try:
        tty.setraw(0)
        os.set_blocking(1, False)
        initial = b"\x1b[?1049h\x1b[?25l" + (marker(0, args.marker_mode) if role == "marker" else b"\x1b[0m\x1b[2J\x1b[H")
        if not write_terminal(initial, deadline, lambda: running):
            stop("timeout")
        else:
            metadata.update(readyMonotonicNs=time.monotonic_ns(), readyUnixNs=time.time_ns())
            if role == "marker":
                write_json(args.output / "ready.json", metadata)
            else:
                metadata.update(requestedBytesPerSecond=args.secondary_load, status="running",
                                bytesWritten=0)
                write_json(busy_path, metadata)

        # At most 50 ms of output credit and one 64 KiB write per loop. A
        # blocked pane cannot accumulate an unbounded catch-up burst; input
        # and stop signals are serviced even when its output is backpressured.
        rate = args.secondary_load if role == "busy" else 0
        quantum = min(MAX_WRITE, max(1, rate // 100))
        capacity = min(MAX_WRITE, max(1, rate / 20))
        tokens = 0.0
        last_refill = time.monotonic()
        while running:
            now = time.monotonic()
            if now >= deadline:
                stop("timeout")
                break
            if repaint:
                repaint = False
                if not write_terminal(marker(sequence, args.marker_mode), deadline, lambda: running):
                    stop("timeout")
                    break
            if rate:
                tokens = min(capacity, tokens + (now - last_refill) * rate)
                last_refill = now
            can_write = rate and tokens >= quantum
            wait = min(0.05, deadline - now)
            if rate and not can_write:
                wait = min(wait, (quantum - tokens) / rate)
            readable, writable, _ = select.select([0], [1] if can_write else [], [], wait)
            if not running:
                break
            if readable:
                try:
                    data = os.read(0, 4096)
                except BlockingIOError:
                    data = None
                if data == b"":
                    stop("pty-disconnected")
                    break
                for byte in data or b"":
                    if byte in (3, 4, ord("q")):
                        stop({3: "input-CtrlC", 4: "input-CtrlD", ord("q"): "input-q"}[byte])
                        break
                    if role == "marker" and byte == ord("a"):
                        sequence += 1
                        size = os.get_terminal_size(0)
                        received.append({"sequence": sequence, "receivedMonotonicNs": time.monotonic_ns(),
                                         "columns": size.columns, "rows": size.lines})
                        if not write_terminal(marker(sequence, args.marker_mode), deadline, lambda: running):
                            stop("timeout")
                            break
            if running and writable:
                try:
                    count = os.write(1, NEUTRAL_OUTPUT[:min(MAX_WRITE, int(tokens))])
                    if count == 0:
                        stop("pty-disconnected")
                    tokens -= count
                    bytes_written += count
                except (BlockingIOError, InterruptedError):
                    pass
    except OSError as error:
        if error.errno in (errno.EIO, errno.ENXIO, errno.EPIPE):
            stop("pty-disconnected")
        else:
            stop("error-" + str(error))
            raise
    finally:
        stopped_ns = time.monotonic_ns()
        cleanup = {"errors": [], "terminalReset": False, "termiosRestored": False,
                   "stdoutBlockingRestored": False}
        try:
            cleanup["terminalReset"] = write_terminal(RESET, time.monotonic() + 0.1, lambda: True)
            if not cleanup["terminalReset"]:
                cleanup["errors"].append("terminal reset: PTY stayed backpressured")
        except OSError as error:
            cleanup["errors"].append("terminal reset: " + str(error))
        try:
            termios.tcsetattr(0, termios.TCSANOW, saved)
            cleanup["termiosRestored"] = True
        except (OSError, termios.error) as error:
            cleanup["errors"].append("termios restore: " + str(error))
        try:
            os.set_blocking(1, stdout_was_blocking)
            cleanup["stdoutBlockingRestored"] = True
        except OSError as error:
            cleanup["errors"].append("stdout flags restore: " + str(error))

        final = dict(metadata, status="stopped", stopReason=stop_reason or "error",
                     stoppedMonotonicNs=stopped_ns,
                     durationSeconds=(stopped_ns - started_ns) / 1_000_000_000,
                     bytesWritten=bytes_written, cleanup=cleanup)
        if role == "marker":
            # Keep the original receipt/cleanup paths for single-pane drivers.
            write_json(args.output / "received.json", received)
            write_json(args.output / "cleanup.json", dict(final, errors=cleanup["errors"]))
        else:
            final["requestedBytesPerSecond"] = args.secondary_load
            write_json(busy_path, final)


if __name__ == "__main__":
    main()
