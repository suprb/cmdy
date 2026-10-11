#!/usr/bin/env python3
"""Owned startup PTY: retain actual initial geometry and paint the target once.

The native launch clock continues throughout target arrival. No resize,
readiness acknowledgement, timer reset, or second viewport is permitted.
"""
from __future__ import annotations
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import termios
import time
import tty
from startup_grid import Witness

PROTOCOL = "startup-full-generated-viewport-v5"
MAX_SIGNALS = 64
MAX_OBSERVATIONS = 512


def write_json(path, value):
    temporary = path.with_name(path.name + ".next")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"), allow_nan=False)
        stream.write("\n")
    os.replace(temporary, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--columns", type=int, required=True)
    parser.add_argument("--rows", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=25)
    args = parser.parse_args(argv)
    target = (args.columns, args.rows)
    witness = Witness(args.token, *target, 1, 1)
    witness.validate()
    if not 1 <= args.timeout <= 30:
        raise ValueError("worker timeout must be 1...30 seconds")
    directory = args.directory
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("worker directory must be new, private and owned")
    if any(directory.iterdir()):
        raise ValueError("worker output directory is not empty")
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_absolute_time.restype = ctypes.c_uint64
    ticks = system.mach_absolute_time
    saved = termios.tcgetattr(0)
    flags = [os.get_blocking(fd) for fd in (0, 1)]
    wake_read, wake_write = os.pipe()
    for fd in (wake_read, wake_write):
        os.set_blocking(fd, False)
        os.set_inheritable(fd, False)
    old_wakeup = signal.set_wakeup_fd(wake_write, warn_on_full_buffer=False)
    running, signal_overflow, error = True, False, ""
    observations, signals, events = [], [], []
    attempt, selected = None, None
    started = int(ticks())
    deadline = time.monotonic() + args.timeout

    def stop(*_):
        nonlocal running
        running = False

    def winch(*_):
        nonlocal signal_overflow
        if len(signals) >= MAX_SIGNALS:
            signal_overflow = True
            return
        signals.append(dict(receivedTicks=int(ticks())))

    signal.signal(signal.SIGWINCH, winch)
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(number, stop)

    def check_running(*, allow_completed_stop=False):
        if signal_overflow:
            raise ValueError("SIGWINCH record bound exceeded")
        if not running:
            if allow_completed_stop and len(events) == 1:
                return False
            raise ValueError("stopped before target viewport complete")
        if time.monotonic() >= deadline:
            raise TimeoutError("startup diagnostic deadline expired")
        return True

    def observe(reason):
        if len(observations) >= MAX_OBSERVATIONS:
            raise ValueError("grid observation bound exceeded")
        before = int(ticks())
        size = os.get_terminal_size(0)
        after = int(ticks())
        observation = dict(index=len(observations), reason=reason, beforeTicks=before,
            afterTicks=after, columns=size.columns, rows=size.lines)
        observations.append(observation)
        if selected is not None and (size.columns, size.lines) != target:
            raise ValueError("grid changed after first target observation; repaint forbidden")
        return observation

    def snapshot(status):
        # Counters refer to recorded timestamps, not the later JSON serialization
        # time. A signal during a blocked write cannot rewrite its observed count.
        recorded = int(ticks())
        recorded_signals = [dict(value) for value in signals if value["receivedTicks"] <= recorded]
        def counter(tick):
            return sum(value["receivedTicks"] <= tick for value in recorded_signals)
        sampled = []
        for value in observations:
            sampled.append(dict(value, signalCounterBefore=counter(value["beforeTicks"]),
                signalCounterAfter=counter(value["afterTicks"])))
        painted = []
        for value in events:
            painted.append(dict(value, signalCounterAtObserved=counter(value["observedTicks"]),
                signalCounterAtStarted=counter(value["startedTicks"]),
                signalCounter=counter(value["completedTicks"])))
        write_json(directory / "events.json", dict(protocol=PROTOCOL, diagnosticOnly=True,
            token=args.token, pid=os.getpid(), targetGrid=list(target), status=status,
            error=error, signalOverflow=signal_overflow, recordedTicks=recorded,
            firstTargetIndex=selected, gridObservations=sampled, signals=recorded_signals,
            paintAttempt=attempt, events=painted))

    def paint(observation):
        nonlocal attempt, selected
        if attempt is not None:
            raise ValueError("second paint forbidden")
        selected = observation["index"]
        payload = witness.frame_bytes()
        observe("before-write")
        check_running()
        attempt = dict(generation=1, columns=target[0], rows=target[1],
            observedTicks=observation["afterTicks"], startedTicks=int(ticks()),
            offeredBytes=len(payload), completedBytes=0,
            payloadSHA256=hashlib.sha256(payload).hexdigest())
        remaining = memoryview(payload)
        checked_signals = len(signals)
        while remaining:
            check_running()
            if len(signals) != checked_signals:
                observe("signal-during-write")
                checked_signals = len(signals)
            try:
                count = os.write(1, remaining[:65536])
                if count <= 0:
                    raise OSError("empty startup PTY write")
                remaining = remaining[count:]
                attempt["completedBytes"] += count
            except BlockingIOError:
                select.select([], [1], [], .01)
            except InterruptedError:
                pass
        attempt["completedTicks"] = int(ticks())
        observe("after-write")
        events.append(dict(attempt))
        snapshot("painted")

    try:
        tty.setraw(0, when=termios.TCSANOW)
        os.set_blocking(0, False)
        os.set_blocking(1, False)
        initial = observe("initial")
        write_json(directory / "ready.json", dict(token=args.token, pid=os.getpid(), parentPID=os.getppid(),
            executable=str(Path(os.sys.executable).resolve()), ttyPath=os.ttyname(0), startedTicks=started,
            initialColumns=initial["columns"], initialRows=initial["rows"]))
        current = initial
        if (current["columns"], current["rows"]) == target:
            paint(current)
        while running:
            # A stop may arrive after the loop condition. A completed paint
            # still needs final geometry and restoration checks below.
            if not check_running(allow_completed_stop=True):
                break
            ready, _, _ = select.select([0, wake_read], [], [], .1)
            if wake_read in ready:
                try:
                    os.read(wake_read, 4096)
                except BlockingIOError:
                    pass
            if 0 in ready:
                try:
                    data = os.read(0, 4096)
                except BlockingIOError:
                    data = None
                if data is not None:
                    if not data or data == b"q":
                        running = False
                    else:
                        raise ValueError("unexpected input in startup viewport")
            if not running:
                break
            current = observe("wake" if wake_read in ready else "poll")
            if attempt is None and (current["columns"], current["rows"]) == target:
                paint(current)
            elif events and wake_read in ready:
                snapshot("painted")
        if not events:
            raise ValueError("stopped before target viewport complete")
        observe("final")
        if signal_overflow:
            raise ValueError("SIGWINCH record bound exceeded")
    except BaseException as exc:
        error = repr(exc)
    finally:
        restored = False
        try:
            try:
                os.write(1, b"\x1b[0m\x1b[?7h\x1b[?25h")
            except OSError:
                pass
            termios.tcsetattr(0, termios.TCSANOW, saved)
            actual = termios.tcgetattr(0)
            pending = list(saved)
            pending[3] |= termios.PENDIN
            if actual == pending and actual != saved:
                try:
                    if os.read(0, 4096):
                        raise ValueError("unexpected cleanup input")
                except BlockingIOError:
                    pass
                actual = termios.tcgetattr(0)
            restored = actual == saved
        except (OSError, termios.error, ValueError) as exc:
            error += "; restore: " + repr(exc)
        for fd, blocking in zip((0, 1), flags):
            os.set_blocking(fd, blocking)
        signal.set_wakeup_fd(old_wakeup)
        os.close(wake_read)
        os.close(wake_write)
        # Close signal delivery before freezing final evidence. Original process
        # handlers need not be restored: this dedicated worker exits immediately.
        signal.signal(signal.SIGWINCH, signal.SIG_IGN)
        snapshot("failed" if error or not restored else "stopped")
        write_json(directory / "cleanup.json", dict(protocol=PROTOCOL, token=args.token,
            pid=os.getpid(), error=error, termiosRestored=restored,
            flagsRestored=all(os.get_blocking(fd) == value for fd, value in zip((0, 1), flags)),
            finishedTicks=int(ticks()), generation=1 if attempt else 0,
            completedViewport=len(events) == 1))
    return 0 if not error and restored else 1


if __name__ == "__main__":
    raise SystemExit(main())
