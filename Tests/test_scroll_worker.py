"""Owned headless PTY lifecycle/byte tests; never launches a terminal app."""
from __future__ import annotations

import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

from scroll_bench import control
from scroll_protocol import payload

HERE = Path(__file__).resolve().parent
TOKEN = "0123456789abcdef0123456789abcdef"


class OwnedFixture:
    def __init__(self, columns=120, rows=36, lifetime=10):
        self.temporary = tempfile.TemporaryDirectory(prefix="scroll-pty-test-", dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.output = self.root / "fixture"
        self.socket = self.root / "control.sock"
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        os.set_blocking(self.master, False)

        def controlling_tty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen([sys.executable, "-S", str(HERE / "scroll_worker.py"),
            "--output", str(self.output), "--socket", str(self.socket), "--token", TOKEN,
            "--timeout", str(lifetime)], stdin=self.slave, stdout=self.slave, stderr=self.slave,
            preexec_fn=controlling_tty, close_fds=True)
        self.wait_file("ready.json")

    def wait_file(self, name):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            path = self.output / name
            if path.is_file():
                return json.loads(path.read_text())
            if self.process.poll() is not None:
                break
            time.sleep(0.005)
        raise AssertionError(f"owned fixture did not publish {name}")

    def prepare(self, reply=b"\x1b[36;1R", fragmented=False):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(control, self.socket, TOKEN, "prepare", 8)
            data = bytearray()
            deadline = time.monotonic() + 5
            expected = payload(TOKEN) + b"\x1b[36;1H\x1b[6n"
            while not data.endswith(b"\x1b[6n") and time.monotonic() < deadline:
                if select.select([self.master], [], [], 0.05)[0]:
                    data.extend(os.read(self.master, 65536))
                if len(data) > len(expected):
                    raise AssertionError("unexpected generated PTY output")
            if bytes(data) != expected:
                raise AssertionError("generated payload bytes/query differed")
            if fragmented:
                for byte in reply:
                    os.write(self.master, bytes([byte]))
                    time.sleep(0.002)
            else:
                os.write(self.master, reply)
            return bytes(data), pending.result(timeout=8)

    def finish(self):
        control(self.socket, TOKEN, "finish")
        self.process.wait(timeout=5)
        return self.wait_file("final.json")

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        os.close(self.master); os.close(self.slave)
        self.temporary.cleanup()


class WorkerTests(unittest.TestCase):
    def fixture(self, **kwargs):
        value = OwnedFixture(**kwargs)
        self.addCleanup(value.close)
        return value

    def test_exact_payload_fragmented_dsr_and_graceful_mode_restoration(self):
        fixture = self.fixture()
        ready = fixture.wait_file("ready.json")
        self.assertFalse(ready["ttyFlagsRaw"][1] & termios.OPOST)
        data, reply = fixture.prepare(fragmented=True)
        self.assertTrue(reply["ok"])
        prepared = fixture.wait_file("prepared.json")
        self.assertEqual(prepared["payloadSHA256"], hashlib.sha256(payload(TOKEN)).hexdigest())
        self.assertEqual(prepared["payloadBytes"], len(payload(TOKEN)))
        self.assertEqual(prepared["dsrReplyHex"], b"\x1b[36;1R".hex())
        query = b"\x1b[36;1H\x1b[6n"
        self.assertEqual(data[-len(query):], query)
        final = fixture.finish()
        self.assertEqual(fixture.process.returncode, 0)
        self.assertEqual(final["status"], "stopped")
        self.assertTrue(final["terminalModeRestored"] and final["fileFlagsRestored"])
        self.assertEqual(final["ttyFlagsRestored"], fixture.original[:4])
        self.assertEqual(final["modeDifferenceIndices"], [])
        self.assertFalse(fixture.socket.exists())

    def test_probe_is_silent_and_checks_actual_native_grid(self):
        fixture = self.fixture()
        fixture.prepare()
        self.assertTrue(control(fixture.socket, TOKEN, "probe")["ok"])
        self.assertFalse(select.select([fixture.master], [], [], 0.03)[0])
        fcntl.ioctl(fixture.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 120, 0, 0))
        with self.assertRaises((ValueError, OSError)):
            control(fixture.socket, TOKEN, "probe")
        final = fixture.wait_file("final.json")
        self.assertEqual(final["status"], "invalid")
        self.assertEqual(final["gridAfter"]["rows"], 35)

    def test_wrong_dsr_rejects_without_retaining_arbitrary_input(self):
        fixture = self.fixture()
        secret_like = b"OWNED_TEST_UNEXPECTED_INPUT_9f2"
        with self.assertRaises((ValueError, OSError)):
            fixture.prepare(reply=secret_like)
        final = fixture.wait_file("final.json")
        self.assertEqual(final["status"], "invalid")
        self.assertNotIn(secret_like.decode(), (fixture.output / "final.json").read_text())
        self.assertNotIn(secret_like.hex(), (fixture.output / "final.json").read_text())
        self.assertTrue(final["terminalModeRestored"])

    def test_echoed_query_is_not_a_dsr_acknowledgement(self):
        fixture = self.fixture()
        with self.assertRaises((ValueError, OSError)):
            fixture.prepare(reply=b"\x1b[6n")
        self.assertEqual(fixture.wait_file("final.json")["status"], "invalid")

    def test_unsolicited_pty_input_invalidates_and_retains_count_only(self):
        fixture = self.fixture()
        fixture.prepare()
        os.write(fixture.master, b"unrelated-test-keystroke")
        final = fixture.wait_file("final.json")
        self.assertEqual(final["status"], "invalid")
        self.assertEqual(final["unexpectedInputBytes"], len(b"unrelated-test-keystroke"))
        self.assertNotIn("unrelated-test-keystroke", (fixture.output / "final.json").read_text())

    def test_unprepared_finish_and_wrong_grid_cannot_succeed(self):
        for command in ("finish", "prepare"):
            with self.subTest(command=command):
                fixture = self.fixture(rows=35)
                with self.assertRaises((ValueError, OSError)):
                    control(fixture.socket, TOKEN, command)
                self.assertEqual(fixture.wait_file("final.json")["status"], "invalid")

    def test_signal_restores_modes_but_never_claims_valid_cleanup(self):
        fixture = self.fixture()
        fixture.prepare()
        fixture.process.send_signal(signal.SIGTERM)
        fixture.process.wait(timeout=5)
        final = fixture.wait_file("final.json")
        self.assertEqual(final["status"], "invalid")
        self.assertEqual(final["stopReason"], "signal")
        self.assertTrue(final["terminalModeRestored"] and final["fileFlagsRestored"])
        self.assertEqual(final["ttyFlagsRestored"], fixture.original[:4])
        self.assertEqual(final["modeDifferenceIndices"], [])
        self.assertFalse(fixture.socket.exists())

    def test_wrong_nonce_invalidates_control_without_printing_it(self):
        fixture = self.fixture()
        with self.assertRaises((ValueError, OSError)):
            control(fixture.socket, "f" * 32, "prepare")
        final = fixture.wait_file("final.json")
        self.assertEqual(final["status"], "invalid")
        self.assertNotIn("f" * 32, (fixture.output / "final.json").read_text())

    def test_partial_reply_and_extra_response_bytes_never_acknowledge(self):
        for response in (b"\x1b[36;1", b"\x1b[36;1RZ"):
            with self.subTest(response=response):
                fixture = self.fixture()
                with self.assertRaises((ValueError, OSError)):
                    fixture.prepare(reply=response)
                self.assertEqual(fixture.wait_file("final.json")["status"], "invalid")


if __name__ == "__main__":
    unittest.main()
