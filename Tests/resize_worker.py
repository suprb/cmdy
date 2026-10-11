#!/usr/bin/env python3
"""Private generated resize worker with exact SIGWINCH and cleanup receipts."""
from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import select
import signal
import socket
import stat
import sys
import termios
import time
import tty

from resize_protocol import (ArmState, GRIDS, HISTORY_BYTES, RESTORE, SEPARATOR_ROWS,
                             check_nonce, digest, frame_bytes, history, sequence_plan)

sys.dont_write_bytecode = True


def atomic_json(path, value):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("x") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
    os.replace(temporary, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--socket-directory", type=Path, required=True)
    parser.add_argument("--capability", required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--paired-block", type=int, choices=range(6))
    parser.add_argument("--calibration-nonce")
    parser.add_argument("--export-directory", type=Path)
    parser.add_argument("--history-growth-guard", action="store_true")
    args = parser.parse_args(argv)
    check_nonce(args.capability); check_nonce(args.nonce)
    paired = args.paired_block is not None
    if args.history_growth_guard and not paired:
        parser.error("history growth guard requires a complete paired batch")
    if paired != (args.calibration_nonce is not None) or paired != (args.export_directory is not None):
        parser.error("paired block, calibration nonce and export directory are required together")
    if paired:
        check_nonce(args.calibration_nonce)
        if args.calibration_nonce == args.nonce:
            parser.error("calibration and measured nonce must be distinct")
    if not 1 <= args.timeout <= 600:
        parser.error("timeout must be within 1...600 seconds")
    owner = args.socket_directory.stat()
    if (args.socket_directory.is_symlink() or not stat.S_ISDIR(owner.st_mode)
            or owner.st_uid != os.getuid() or owner.st_mode & 0o077):
        parser.error("socket directory must be private, existing and owned")
    args.output.mkdir(mode=0o700, exist_ok=False)
    socket_path = args.socket_directory / "resize.sock"
    if len(os.fsencode(socket_path)) >= 104:
        parser.error("Darwin Unix socket path exceeds sockaddr_un capacity")

    # This clock is diagnostic provenance; latency uses native AX/SCK ticks.
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_absolute_time.argtypes = []
    system.mach_absolute_time.restype = ctypes.c_uint64
    ticks = system.mach_absolute_time
    started = time.monotonic_ns()
    deadline = started + int(args.timeout * 1e9)
    saved_termios = termios.tcgetattr(0)
    saved_input_blocking = os.get_blocking(0)
    saved_blocking = os.get_blocking(1)
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(socket_path)); os.chmod(socket_path, 0o600)
    server.listen(1); server.setblocking(False)
    state = ArmState()
    running, mode, error, stop_reason = True, "setup", "", ""
    signal_count, handled_signal_count = 0, 0
    signal_records, writes, events, controls = [], [], [], []
    offered = None
    history_receipt = None
    authorized_signal_count = None
    last_painted_grid = None
    wakeup_read = wakeup_write = previous_wakeup_fd = None
    wakeup_bytes = 0
    batch_started = False
    calibration_events = []
    batch_start = None
    transfer = None
    if paired:
        from resize_history_transfer import Transfer
        transfer = Transfer(args.export_directory, args.output / "history-exports", args.nonce, ticks,
                            history_growth_guard=args.history_growth_guard)
    plan = sequence_plan(args.paired_block) if paired else None
    # A complete paired workload includes two calibration and 42 batch frames
    # (over 4 MiB). Darwin may accept about 1 KiB per nonblocking PTY write, so
    # the diagnostic one-event cap cannot contain its complete write chronology.
    maximum_write_records = 16384 if paired else 4096

    def render_nonce():
        return args.calibration_nonce if paired and not batch_started else args.nonce

    def render_frame(sequence, columns, rows):
        return frame_bytes(render_nonce(), sequence, columns, rows, history_growth_guard=args.history_growth_guard)

    def size():
        value = os.get_terminal_size(0)  # TIOCGWINSZ; never mutates dimensions.
        return value.columns, value.lines

    def stop(reason):
        nonlocal running, stop_reason
        running = False
        if not stop_reason:
            stop_reason = reason

    def winch(*_):
        nonlocal signal_count, error
        signal_count += 1
        if len(signal_records) >= 256:
            error = "SIGWINCH chronology bound exceeded"; stop("signal-overflow")
            return
        signal_records.append(dict(counter=signal_count, receivedTicks=int(ticks())))

    def write_all(payload, label, event=None):
        start = int(ticks())
        end = min(deadline, time.monotonic_ns() + 3_000_000_000)
        remaining = memoryview(payload)
        completed = 0
        while remaining and running:
            if time.monotonic_ns() >= end or len(writes) >= maximum_write_records:
                raise ValueError("bounded-generated-write-did-not-finish")
            try:
                before = int(ticks())
                count = os.write(1, remaining[:65536])
                after = int(ticks())
                if count <= 0:
                    raise OSError(errno.EIO, "empty PTY write")
                write = dict(label=label, sequence=event, beforeTicks=before,
                             afterTicks=after, offset=completed, bytes=count)
                if paired: write["epoch"] = "batch" if batch_started else "calibration"
                writes.append(write)
                remaining = remaining[count:]; completed += count
            except BlockingIOError:
                select.select([], [1], [], 0.01)
            except InterruptedError:
                continue
        if remaining:
            raise RuntimeError("fixture stopped during a partial write")
        return dict(offeredBytes=len(payload), completedBytes=completed,
                    payloadSHA256=digest(payload), startedTicks=start, completedTicks=int(ticks()))

    def status():
        columns, rows = size()
        value = dict(ok=True, pid=os.getpid(), capability=args.capability, mode=mode,
                    grid=dict(columns=columns, rows=rows), signalCounter=signal_count,
                    pending=state.pending, completedEvents=len(events), events=events,
                    history=history_receipt, error=error)
        if paired:
            value.update(batchStarted=batch_started, batchStart=batch_start,
                         calibrationEvents=calibration_events, historyTransfer=transfer.status())
        return value

    def control(connection):
        nonlocal mode, history_receipt, offered, handled_signal_count, last_painted_grid
        nonlocal state, events, calibration_events, batch_started, batch_start
        connection.settimeout(0.25)
        raw = bytearray()
        while not raw.endswith(b"\n") and len(raw) <= 4096:
            part = connection.recv(4096)
            if not part:
                break
            raw.extend(part)
        if len(raw) > 4096 or not raw.endswith(b"\n"):
            raise ValueError("bounded newline-delimited request required")
        request = json.loads(raw)
        if request.get("capability") != args.capability:
            raise ValueError("wrong private fixture capability")
        operation = request.get("op")
        if paired:
            extra = {"sequence", "grid"} if operation == "arm" else {"phase"} if operation == "history-arm" else set()
            if set(request) != {"capability", "op"} | extra:
                raise ValueError("paired-control-fields-differ")
        if len(controls) >= 256:
            raise ValueError("control request bound exceeded")
        control_record = dict(op=operation, receivedTicks=int(ticks()), sequence=request.get("sequence"))
        if paired:
            control_record.update(epoch="batch" if batch_started else "calibration", phase=request.get("phase"))
        controls.append(control_record)
        if operation == "prepare":
            if mode != "setup" or size() != GRIDS[0]:
                raise ValueError("prepare requires fresh primary 120x36")
            corpus = history(args.nonce)
            if len(corpus) != HISTORY_BYTES:
                raise ValueError("history generation length differs")
            with (args.output / "history.bin").open("xb") as stream:
                stream.write(corpus)
            write_all(b"\x1b[0m\x1b[?7h\x1b[?25l\x1b[2J\x1b[H", "prepare-controls")
            history_receipt = write_all(corpus, "history")
            history_receipt["separators"] = write_all(b"\r\n" * SEPARATOR_ROWS, "history-separators")
            if size() != GRIDS[0]:
                raise RuntimeError("native geometry changed during untimed history preload")
            write_all(render_frame(0, *GRIDS[0]), "initial-frame", 0)
            handled_signal_count = signal_count
            last_painted_grid = GRIDS[0]
            mode = "prepared"
        elif operation == "arm":
            if mode != "prepared" or state.pending is not None or offered is not None:
                raise ValueError("fixture must be prepared and idle before arming")
            target = request.get("grid", {})
            dimensions = target.get("columns"), target.get("rows")
            current = size()
            if paired:
                if transfer.active is not None:
                    raise ValueError("resize-cannot-overlap-history-export")
                if batch_started:
                    if len(transfer.completed) != 1 or len(events) >= len(plan):
                        raise ValueError("resize-requires-before-export-and-unfinished-batch")
                    expected = plan[len(events)]
                    expected_sequence = expected["sequence"]
                    expected_grid = (expected["columns"], expected["rows"])
                else:
                    if len(events) >= 2:
                        raise ValueError("exactly-two-calibration-transitions-required")
                    expected_sequence = len(events) + 1
                    expected_grid = GRIDS[(len(events) + 1) % 2]
                if type(request.get("sequence")) is not int or request["sequence"] != expected_sequence or dimensions != expected_grid:
                    raise ValueError("resize-sequence-or-target-deviates-from-plan")
            # Generation is outside the measured native action and completed
            # before ACK; no work request received on this socket can paint.
            payload = render_frame(request.get("sequence"), *dimensions)
            state.arm(request["sequence"], dimensions, current, signal_count)
            offered = dict(sequence=request["sequence"], payload=payload,
                           armedTicks=int(ticks()), sourceGrid=current)
        elif operation == "start-batch" and paired:
            if (mode != "prepared" or batch_started or len(events) != 2
                    or state.pending is not None or offered is not None or size() != GRIDS[0]):
                raise ValueError("batch-requires-complete-round-trip-calibration")
            calibration_events = events
            events = []; state = ArmState(); batch_started = True
            initial_sequence = args.paired_block * 42
            batch_start = dict(sequence=initial_sequence, nonce=args.nonce,
                grid=dict(columns=120, rows=36), calibrationNonce=args.calibration_nonce,
                historyReloaded=False, **write_all(render_frame(initial_sequence, *GRIDS[0]),
                                                   "batch-initial-frame", initial_sequence))
            if size() != GRIDS[0]:
                raise ValueError("geometry-changed-while-starting-batch")
            atomic_json(args.output / "batch-start.json", batch_start)
        elif operation == "history-arm" and paired:
            phase = request.get("phase")
            count = 0 if phase == "before" else 42 if phase == "after" else -1
            if (mode != "prepared" or not batch_started or len(events) != count
                    or state.pending is not None or offered is not None or size() != GRIDS[0]):
                raise ValueError("history-export-requires-quiescent-batch-boundary")
            transfer.arm(phase, args.paired_block * 42 + len(events))
            atomic_json(args.output / ("history-" + phase + "-arm.json"), transfer.active)
        elif operation == "status":
            pass
        elif operation == "finish":
            if state.pending is not None or offered is not None:
                raise ValueError("finish cannot acknowledge an incomplete event")
            if paired and (not batch_started or len(events) != 42 or len(transfer.completed) != 2
                           or transfer.active is not None or size() != GRIDS[0]):
                raise ValueError("finish-requires-complete-batch-and-both-history-exports")
            stop("controller-finish")
        else:
            raise ValueError("unknown private fixture operation")
        connection.sendall(json.dumps(status(), separators=(",", ":")).encode() + b"\n")

    metadata = dict(schemaVersion=1, pid=os.getpid(), parentPID=os.getppid(),
                    role="resize", nonce=args.nonce, socketPath=str(socket_path),
                    ttyPath=os.ttyname(0), startedMonotonicNS=started,
                    startedTicks=int(ticks()), columns=size()[0], rows=size()[1])
    if paired:
        metadata.update(pairedBlock=args.paired_block, calibrationNonce=args.calibration_nonce,
                        temporaryDirectory=str(args.export_directory), historyTransferScope=transfer.status()["scope"],
                        maximumWriteRecords=maximum_write_records)
        if args.history_growth_guard: metadata["historyGrowthGuardRows"] = 4
    try:
        tty.setraw(0, when=termios.TCSANOW)
        os.set_blocking(1, False)
        if paired: os.set_blocking(0, False)
        # Python can restart select after a handled signal. A nonblocking
        # wakeup pipe makes a real SIGWINCH readable immediately; the fixture
        # must not add its polling timeout to the measured terminal response.
        wakeup_read, wakeup_write = os.pipe()
        for fd in (wakeup_read, wakeup_write):
            os.set_blocking(fd, False); os.set_inheritable(fd, False)
        previous_wakeup_fd = signal.set_wakeup_fd(wakeup_write, warn_on_full_buffer=False)
        signal.signal(signal.SIGWINCH, winch)
        signal.signal(signal.SIGTERM, lambda *_: stop("SIGTERM"))
        signal.signal(signal.SIGHUP, lambda *_: stop("SIGHUP"))
        signal.signal(signal.SIGINT, lambda *_: stop("SIGINT"))
        metadata["readyMonotonicNS"] = time.monotonic_ns()
        atomic_json(args.output / "ready.json", metadata)
        while running:
            if time.monotonic_ns() >= deadline:
                stop("timeout"); break
            if paired:
                proof = transfer.poll()
                if proof is not None:
                    atomic_json(args.output / "history-exports" / proof["phase"] / "receipt.json", proof)
            if signal_count != handled_signal_count:
                observed = size()
                observed_ticks = int(ticks())
                fresh = [entry for entry in signal_records if entry["counter"] > handled_signal_count]
                for entry in fresh:
                    entry.update(observedGrid=dict(zip(("columns", "rows"), observed)),
                                 observedTicks=observed_ticks)
                handled_signal_count = signal_count
                had_pending = state.pending is not None
                authorized = state.resize(signal_count, observed)
                if authorized is not None:
                    if offered is None or offered["sequence"] != authorized["sequence"]:
                        raise RuntimeError("authorized resize lost its one offered payload")
                    authorized_signal_count = signal_count
                    event = dict(sequence=authorized["sequence"], grid=dict(zip(("columns", "rows"), observed)),
                                 armedTicks=offered["armedTicks"], sourceGrid=offered["sourceGrid"],
                                 armSignalCounter=authorized["signalCounter"], signalCounter=signal_count,
                                 signalReceivedTicks=fresh[-1]["receivedTicks"], observedTicks=observed_ticks)
                    event.update(write_all(offered["payload"], "resize-frame", authorized["sequence"]))
                    # Repaint itself may not mutate native geometry. Any
                    # further resize signal is retained and fails this event.
                    if size() != observed or signal_count != authorized_signal_count:
                        raise RuntimeError("native geometry changed while repaint was written")
                    if paired: event["epoch"] = "batch" if batch_started else "calibration"
                    events.append(event); offered = None; last_painted_grid = observed
                elif mode == "prepared" and not had_pending and observed != last_painted_grid:
                    raise RuntimeError("unsolicited resize after preparation")
            wait = 0.25
            if paired and transfer.active is not None:
                wait = max(0, min(wait, (transfer.active["deadlineMonotonicNS"] - time.monotonic_ns()) / 1e9))
            readable, _, _ = select.select([server, 0, wakeup_read], [], [], wait)
            if wakeup_read in readable:
                try: wakeup_bytes += len(os.read(wakeup_read, 4096))
                except BlockingIOError: pass
            if 0 in readable:
                data = os.read(0, 4097 if paired else 4096)
                if not data:
                    stop("PTY-EOF")
                elif paired:
                    transfer.receive(data)
                elif any(value in (3, 4, ord("q")) for value in data):
                    stop("terminal-stop")
                else:
                    raise ValueError("unexpected input in generated resize fixture")
            if server in readable:
                connection, _ = server.accept()
                with connection:
                    control(connection)
    except Exception as exc:
        # Paired intake never persists arbitrary received paths or file text in
        # an exception. Only fixed hyphenated guard codes may leave that path.
        error = ((str(exc) if type(exc) is ValueError and str(exc).replace("-", "").isalnum()
                  else type(exc).__name__) if paired else f"{type(exc).__name__}: {exc}")
        stop("error")
    finally:
        if transfer is not None: transfer.close()
        restore = dict(termiosRestored=False, terminalRestoreWritten=False,
                       unexpectedCleanupInputBytes=0, fileFlagsRestored=False,
                       ttyFlagsOriginal=saved_termios[:4], signalWakeupRestored=False,
                       signalPipeClosed=False, signalWakeupBytesRead=wakeup_bytes)
        try:
            if previous_wakeup_fd is not None:
                restore["signalWakeupRestored"] = signal.set_wakeup_fd(previous_wakeup_fd) == wakeup_write
            for fd in (wakeup_read, wakeup_write):
                if fd is not None: os.close(fd)
            restore["signalPipeClosed"] = wakeup_read is not None and wakeup_write is not None
        except OSError as exc:
            restore["signalPipeRestoreError"] = str(exc)
        try:
            restore["terminalRestoreWritten"] = os.write(1, RESTORE) == len(RESTORE)
        except OSError as exc:
            restore["terminalRestoreError"] = str(exc)
        try:
            termios.tcsetattr(0, termios.TCSANOW, saved_termios)
            after = termios.tcgetattr(0)
            restore["ttyFlagsAfterSet"] = after[:4]
            with_pending = list(saved_termios)
            with_pending[3] |= termios.PENDIN
            if after == with_pending and after != saved_termios:
                # Darwin resolves its raw-to-canonical PENDIN state on read.
                # Require exactly that difference before one nonblocking read;
                # never mask flags in the acceptance check or flush input.
                os.set_blocking(0, False)
                try:
                    pending = os.read(0, 65536)
                    restore["unexpectedCleanupInputBytes"] = len(pending)
                    restore["canonicalPendingRead"] = "bytes" if pending else "eof"
                except BlockingIOError:
                    restore["canonicalPendingRead"] = "EAGAIN"
                after = termios.tcgetattr(0)
            restore["ttyFlagsRestored"] = after[:4]
            restore["modeDifferenceIndices"] = [index for index in range(len(after))
                                                if after[index] != saved_termios[index]]
            restore["termiosRestored"] = after == saved_termios
        except (OSError, termios.error) as exc:
            restore["termiosRestoreError"] = str(exc)
        try:
            os.set_blocking(1, saved_blocking)
            os.set_blocking(0, saved_input_blocking)
            restore["fileFlagsRestored"] = (os.get_blocking(1) == saved_blocking
                                             and os.get_blocking(0) == saved_input_blocking)
        except OSError:
            pass
        if (not restore["termiosRestored"] or not restore["fileFlagsRestored"] or restore["unexpectedCleanupInputBytes"]
                or not restore["signalWakeupRestored"] or not restore["signalPipeClosed"]):
            error = (error + "; " if error else "") + "exact terminal mode/file flags or empty cleanup input check failed"
        server.close(); socket_path.unlink(missing_ok=True)
        received_record = dict(events=events, signals=signal_records, writes=writes, controls=controls, history=history_receipt)
        cleanup_record = dict(pid=os.getpid(), parentPID=os.getppid(),
                    nonce=args.nonce, stopReason=stop_reason, error=error,
                    pending=state.pending, uncompletedOfferedSequence=offered and offered["sequence"],
                    finishedTicks=int(ticks()), finishedMonotonicNS=time.monotonic_ns(), **restore)
        if paired:
            received_record.update(calibrationEvents=calibration_events, batchStart=batch_start,
                                   pairedBlock=args.paired_block, historyTransfer=transfer.status())
            cleanup_record.update(pairedBlock=args.paired_block, calibrationEvents=len(calibration_events),
                batchEvents=len(events), historyExports=len(transfer.completed), exportInputBytesRetained=len(transfer.received))
        atomic_json(args.output / "received.json", received_record)
        atomic_json(args.output / "cleanup.json", cleanup_record)
    return 0 if not error and stop_reason == "controller-finish" else 1


if __name__ == "__main__":
    raise SystemExit(main())
