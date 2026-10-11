#!/usr/bin/env python3
"""Real-PTY fixture checks; no terminal app, GUI, or throughput benchmark."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest


WORKER = Path(__file__).with_name("input-latency-worker.py")
RESET = b"\x1b[0m\x1b[?25h\x1b[?1049l"


def marker(sequence):
    red = 48 + (sequence % 16) * 11
    green = 48 + ((sequence // 16) % 16) * 11
    return f"\x1b[48;2;{red};{green};211m\x1b[2J\x1b[H".encode()


class PTYWorker:
    def __init__(self, output, *arguments):
        self.output_dir = output
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.saved_termios = termios.tcgetattr(self.slave)
        self.saved_blocking = os.get_blocking(self.slave)
        self.terminal_bytes = bytearray()
        self.process = subprocess.Popen(
            [sys.executable, "-B", str(WORKER), "--output", str(output), *arguments],
            stdin=self.slave, stdout=self.slave, stderr=subprocess.PIPE,
            close_fds=True)
        os.set_blocking(self.master, False)

    def pump(self, timeout=0.01):
        if self.master is None:
            time.sleep(timeout)
            return
        readable, _, _ = select.select([self.master], [], [], timeout)
        if readable:
            # Bound the test reader's work too, even for the maximum-rate case.
            for _ in range(8):
                try:
                    data = os.read(self.master, 64 * 1024)
                except BlockingIOError:
                    break
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                self.terminal_bytes.extend(data)

    def wait_json(self, name, timeout=3):
        path = self.output_dir / name
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return json.loads(path.read_text())
            if self.process.poll() is not None:
                raise AssertionError(f"worker exited before {name}: {self.process.stderr.read()!r}")
            self.pump()
        raise AssertionError(f"worker did not create {name}")

    def wait_exit(self, timeout=3, drain=True):
        deadline = time.monotonic() + timeout
        while self.process.poll() is None and time.monotonic() < deadline:
            if drain:
                self.pump()
            else:
                time.sleep(0.01)
        if self.process.poll() is None:
            raise AssertionError("worker failed to stop within the fixture deadline")
        if drain:
            self.pump(0)
        return self.process.returncode

    def send(self, data):
        os.write(self.master, data)

    def disconnect(self):
        os.close(self.master)
        self.master = None

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1)
        if self.master is not None:
            os.close(self.master)
        os.close(self.slave)
        self.process.stderr.close()


class InputLatencyWorkerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmdy-input-worker-test-")
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name) / "fixture"

    def launch(self, *arguments):
        worker = PTYWorker(self.output, *arguments)
        self.addCleanup(worker.close)
        return worker

    def assert_restored(self, worker, cleanup):
        self.assertEqual(cleanup["errors"], [])
        self.assertTrue(cleanup["terminalReset"])
        self.assertTrue(cleanup["termiosRestored"])
        self.assertTrue(cleanup["stdoutBlockingRestored"])
        restored = termios.tcgetattr(worker.slave)
        expected = worker.saved_termios.copy()
        # Darwin sets this transient kernel state bit when ICANON is restored,
        # even for a bare setraw/tcsetattr round trip with no worker or input.
        # All actual terminal modes and control characters must still match.
        restored[3] &= ~getattr(termios, "PENDIN", 0)
        expected[3] &= ~getattr(termios, "PENDIN", 0)
        self.assertEqual(restored, expected)
        self.assertEqual(os.get_blocking(worker.slave), worker.saved_blocking)
        self.assertIn(RESET, worker.terminal_bytes)

    def test_marker_preserves_color_receipt_count_and_order(self):
        worker = self.launch()
        ready = worker.wait_json("ready.json")
        self.assertEqual(ready["pid"], worker.process.pid)
        self.assertEqual(ready["role"], "marker")
        self.assertEqual((ready["rows"], ready["columns"]), (24, 80))
        self.assertEqual(ready["ttyPath"], os.ttyname(worker.slave))
        worker.send(b"xaaxaaqaaaa")
        self.assertEqual(worker.wait_exit(), 0)
        receipts = worker.wait_json("received.json")
        self.assertEqual([item["sequence"] for item in receipts], [1, 2, 3, 4])
        times = [item["receivedMonotonicNs"] for item in receipts]
        self.assertEqual(times, sorted(times))
        positions = [worker.terminal_bytes.index(marker(sequence)) for sequence in range(5)]
        self.assertEqual(positions, sorted(positions))
        final = worker.wait_json("cleanup.json")
        self.assertEqual(final["stopReason"], "input-q")
        self.assert_restored(worker, final["cleanup"])

    def test_local_marker_changes_only_eight_cells_on_one_row(self):
        worker = self.launch("--marker-mode", "local-row")
        ready = worker.wait_json("ready.json")
        self.assertEqual(ready["markerMode"], "local-row")
        worker.send(b"aq")
        self.assertEqual(worker.wait_exit(), 0)
        for red in (48, 59):
            expected = f"\x1b[12;36H\x1b[48;2;{red};48;211m        \x1b[0m".encode()
            self.assertIn(expected, worker.terminal_bytes)
        self.assertNotIn(b"\x1b[2J", worker.terminal_bytes)
        self.assertEqual([x["sequence"] for x in worker.wait_json("received.json")], [1])
        self.assert_restored(worker, worker.wait_json("cleanup.json")["cleanup"])

    def test_marker_timeout_restores_terminal_and_saves_empty_receipts(self):
        worker = self.launch("--timeout", "1")
        worker.wait_json("ready.json")
        self.assertEqual(worker.wait_exit(), 0)
        final = worker.wait_json("cleanup.json")
        self.assertEqual(final["stopReason"], "timeout")
        self.assertGreaterEqual(final["durationSeconds"], 1)
        self.assertLess(final["durationSeconds"], 2)
        self.assertEqual(worker.wait_json("received.json"), [])
        self.assert_restored(worker, final["cleanup"])

    def test_secondary_requires_opt_in_and_preserves_primary_evidence(self):
        primary = self.launch("--secondary-load", "32000")
        ready = primary.wait_json("ready.json")
        self.assertEqual(ready["role"], "marker")
        refused = self.launch()
        self.assertNotEqual(refused.wait_exit(), 0)
        self.assertIn(b"secondary requires", refused.process.stderr.read())

        secondary = self.launch("--secondary-load", "32000", "--timeout", "1")
        name = f"busy-{secondary.process.pid}.json"
        busy_ready = secondary.wait_json(name)
        self.assertEqual(busy_ready["role"], "busy")
        self.assertEqual(busy_ready["status"], "running")
        self.assertEqual(busy_ready["pid"], secondary.process.pid)
        self.assertEqual(busy_ready["ttyPath"], os.ttyname(secondary.slave))
        self.assertGreaterEqual(busy_ready["readyMonotonicNs"], busy_ready["startedMonotonicNs"])
        self.assertEqual(secondary.wait_exit(), 0)
        final = secondary.wait_json(name)
        self.assertEqual(final["stopReason"], "timeout")
        self.assertEqual(final["status"], "stopped")
        self.assertEqual(final["requestedBytesPerSecond"], 32000)
        self.assertGreater(final["bytesWritten"], 0)
        self.assertLessEqual(final["bytesWritten"], 32000 * final["durationSeconds"] + 1)
        self.assertNotIn(marker(0), secondary.terminal_bytes)
        self.assert_restored(secondary, final["cleanup"])
        self.assertEqual(primary.wait_json("ready.json"), ready)
        self.assertFalse((self.output / "received.json").exists())
        primary.send(b"aq")
        self.assertEqual(primary.wait_exit(), 0)
        self.assertEqual([item["sequence"] for item in primary.wait_json("received.json")], [1])

    def test_busy_stop_input_and_signal_remain_bounded_without_output_drain(self):
        primary = self.launch()
        primary.wait_json("ready.json")
        for trigger, reason in ((b"q", "input-q"), (b"\x03", "input-CtrlC"),
                                (b"\x04", "input-CtrlD"), (signal.SIGTERM, "signal-SIGTERM")):
            with self.subTest(reason=reason):
                secondary = self.launch("--secondary-load", "20000000")
                name = f"busy-{secondary.process.pid}.json"
                secondary.wait_json(name)
                # Deliberately leave its PTY full before stopping it.
                time.sleep(0.08)
                if isinstance(trigger, bytes):
                    secondary.send(trigger)
                else:
                    secondary.process.send_signal(trigger)
                self.assertEqual(secondary.wait_exit(timeout=1, drain=False), 0)
                final = secondary.wait_json(name)
                self.assertEqual(final["stopReason"], reason)
                self.assertTrue(final["cleanup"]["termiosRestored"])
                self.assertTrue(final["cleanup"]["stdoutBlockingRestored"])
                self.assertGreater(final["bytesWritten"], 0)
                self.assertLessEqual(final["bytesWritten"], 20000000 * final["durationSeconds"] + 1)

    def test_hangup_and_disconnection_preserve_final_evidence(self):
        primary = self.launch()
        primary.wait_json("ready.json")
        primary.send(b"aa")
        deadline = time.monotonic() + 1
        while marker(2) not in primary.terminal_bytes and time.monotonic() < deadline:
            primary.pump()
        self.assertIn(marker(2), primary.terminal_bytes)
        primary.process.send_signal(signal.SIGHUP)
        self.assertEqual(primary.wait_exit(), 0)
        final = primary.wait_json("cleanup.json")
        self.assertEqual(final["stopReason"], "signal-SIGHUP")
        self.assertEqual(len(primary.wait_json("received.json")), 2)
        self.assert_restored(primary, final["cleanup"])

        secondary = self.launch("--secondary-load", "1000")
        name = f"busy-{secondary.process.pid}.json"
        secondary.wait_json(name)
        secondary.disconnect()
        self.assertEqual(secondary.wait_exit(), 0)
        final = secondary.wait_json(name)
        self.assertEqual(final["stopReason"], "pty-disconnected")
        self.assertFalse(final["cleanup"]["terminalReset"])
        self.assertTrue(final["cleanup"]["errors"])

    def test_invalid_bounds_fail_before_creating_evidence(self):
        for arguments in (("--secondary-load", "-1"), ("--secondary-load", "20000001"),
                          ("--timeout", "0"), ("--timeout", "601"), ("--timeout", "nan")):
            with self.subTest(arguments=arguments):
                worker = self.launch(*arguments)
                self.assertNotEqual(worker.wait_exit(), 0)
                self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
