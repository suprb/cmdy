"""Own synthetic PTYs only. No terminal application, clipboard, or GUI launch."""
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

from paste_protocol import (ENABLED_ROW, START, expected_receipt, preparation,
                            response_first_row, viewport_bytes, wire_bytes)
from scroll_bench import control
from terminal_bench_worker import write_all

HERE = Path(__file__).resolve().parent
TOKEN = "0123456789abcdef0123456789abcdef"


class OwnedPasteFixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="paste-pty-test-", dir="/private/tmp")
        self.root = Path(self.temp.name); self.output = self.root / "fixture"; self.socket = self.root / "control.sock"
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 120, 0, 0))
        os.set_blocking(self.master, False)

        def controlling_tty():
            os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen([sys.executable, "-S", str(HERE / "paste_worker.py"),
            "--output", str(self.output), "--socket", str(self.socket), "--token", TOKEN, "--timeout", "30"],
            stdin=self.slave, stdout=self.slave, stderr=self.slave, preexec_fn=controlling_tty, close_fds=True)
        self.wait_file("ready.json")

    def wait_file(self, name):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            path = self.output / name
            if path.is_file():
                return json.loads(path.read_text())
            if self.process.poll() is not None:
                break
            time.sleep(0.002)
        raise AssertionError("missing owned fixture evidence: " + name)

    def drain_exact(self, expected):
        data = bytearray(); deadline = time.monotonic() + 6
        while len(data) < len(expected) and time.monotonic() < deadline:
            if select.select([self.master], [], [], 0.03)[0]:
                data.extend(os.read(self.master, 65536))
        if bytes(data) != expected:
            raise AssertionError("generated full-width PTY response differs")

    def prepare(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(control, self.socket, TOKEN, "prepare", 8)
            self.drain_exact(preparation(TOKEN) + b"\x1b[36;1H\x1b[6n")
            write_all(self.master, b"\x1b[36;1R", time.monotonic() + 5)
            return pending.result(timeout=8)

    def paste(self, sequence, fragment=65536):
        control(self.socket, TOKEN, f"arm-{sequence}")
        data = wire_bytes(TOKEN, sequence)
        for offset in range(0, len(data), fragment):
            write_all(self.master, data[offset:offset + fragment], time.monotonic() + 5)
        self.drain_exact(viewport_bytes(TOKEN, response_first_row(sequence)))
        return self.wait_file(f"receipt-{sequence:02d}.json")

    def enable(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(control, self.socket, TOKEN, "enable-bracketed", 8)
            self.drain_exact(b"\x1b[?2004h" + viewport_bytes(TOKEN, ENABLED_ROW))
            return pending.result(timeout=8)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=5)
        os.close(self.master); os.close(self.slave); self.temp.cleanup()


class PasteWorkerTests(unittest.TestCase):
    def fixture(self):
        fixture = OwnedPasteFixture(); self.addCleanup(fixture.close); return fixture

    def test_all_exact_pastes_and_final_mode_restoration(self):
        fixture = self.fixture(); fixture.prepare()
        ready = fixture.wait_file("ready.json")
        self.assertFalse(ready["ttyFlagsRaw"][1] & termios.OPOST)
        off = fixture.paste(0, fragment=1); fixture.enable()
        self.assertFalse(off["bracketed"])
        for sequence in range(1, 43):
            actual = fixture.paste(sequence, fragment=101 if sequence == 1 else 65536)
            self.assertEqual({k: actual[k] for k in expected_receipt(TOKEN, sequence)}, expected_receipt(TOKEN, sequence))
            self.assertLessEqual(actual["verifiedMonotonicNS"], actual["emitStartedMonotonicNS"])
        control(fixture.socket, TOKEN, "finish"); fixture.process.wait(timeout=5)
        final = fixture.wait_file("final.json")
        self.assertEqual(fixture.process.returncode, 0)
        self.assertEqual(final["status"], "stopped")
        self.assertEqual(final["acceptedPastes"], 42)
        self.assertEqual(len(final["receipts"]), 43)
        self.assertTrue(final["terminalModeRestored"] and final["fileFlagsRestored"])
        self.assertEqual(final["ttyFlagsRestored"], fixture.original[:4])
        self.assertEqual(final["modeDifferenceIndices"], [])

    def test_unframed_off_probe_rejects_synthesized_brackets(self):
        fixture = self.fixture(); fixture.prepare(); control(fixture.socket, TOKEN, "arm-0")
        write_all(fixture.master, START + wire_bytes(TOKEN, 0), time.monotonic() + 5)
        final = fixture.wait_file("final.json")
        self.assertEqual(final["status"], "invalid")
        self.assertFalse(final["offProbeVerified"])
        self.assertEqual(final["receipts"], [])

    def test_partial_paste_never_outputs_response_or_finishes(self):
        fixture = self.fixture(); fixture.prepare(); fixture.paste(0); fixture.enable()
        control(fixture.socket, TOKEN, "arm-1")
        write_all(fixture.master, wire_bytes(TOKEN, 1)[:-1], time.monotonic() + 5)
        self.assertFalse(select.select([fixture.master], [], [], 0.1)[0])
        with self.assertRaises((ValueError, OSError)):
            control(fixture.socket, TOKEN, "finish")
        final = fixture.wait_file("final.json")
        self.assertEqual(final["acceptedPastes"], 0)
        self.assertEqual(final["status"], "invalid")
        self.assertTrue(final["terminalModeRestored"])

    def test_foreign_input_is_counted_without_retaining_text(self):
        fixture = self.fixture(); fixture.prepare(); control(fixture.socket, TOKEN, "arm-0")
        data = b"UNEXPECTED_SYNTHETIC_INPUT_82"
        write_all(fixture.master, data, time.monotonic() + 5)
        final = fixture.wait_file("final.json")
        self.assertEqual(final["unexpectedInputBytes"], len(data))
        self.assertNotIn(data.decode(), (fixture.output / "final.json").read_text())
        self.assertNotIn(data.hex(), (fixture.output / "final.json").read_text())

    def test_repeated_arm_and_wrong_control_nonce_reject(self):
        for command, token in (("arm-1", TOKEN), ("prepare", "f" * 32)):
            fixture = self.fixture(); fixture.prepare()
            with self.assertRaises((ValueError, OSError)):
                control(fixture.socket, token, command)
            self.assertEqual(fixture.wait_file("final.json")["status"], "invalid")


if __name__ == "__main__":
    unittest.main()
