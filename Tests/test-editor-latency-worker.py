#!/usr/bin/env python3
"""Exercise real Vim edits/resize/termination on an owned PTY, without a GUI."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time
import unittest

WORKER = Path(__file__).with_name("editor-latency-worker.py")


@unittest.skipUnless(sys.platform == "darwin" and Path("/usr/share/vim/vim91").is_dir(),
                     "requires the installed macOS Vim 9.1 fixture runtime")
class EditorFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmdy-vim-fixture-test-")
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name) / "fixture"
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
                           "LANG": "en_US.UTF-8", "HOME": self.temporary.name}
            os.execve(sys.executable, [sys.executable, "-B", str(WORKER), "--output",
                                      str(self.output), "--timeout", "8"], environment)
        self.reaped = False
        self.resize(120, 36)
        os.set_blocking(self.fd, False)
        self.bytes = bytearray()
        self.addCleanup(self.close)
        self.until(lambda: (self.output / "ready.json").exists())
        self.until(lambda: b"48;2;48;48;211" in self.bytes)

    def resize(self, columns, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def pump(self):
        if select.select([self.fd], [], [], .02)[0]:
            try:
                self.bytes.extend(os.read(self.fd, 65536))
            except (BlockingIOError, OSError):
                pass

    def until(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while not predicate() and time.monotonic() < deadline:
            self.pump()
        self.assertTrue(predicate(), f"Vim fixture did not reach the required state; generated output tail: {bytes(self.bytes[-700:])!r}")

    def close(self):
        if not self.reaped:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                if os.waitpid(self.pid, os.WNOHANG)[0] == self.pid:
                    self.reaped = True
                    break
                self.pump()
            if not self.reaped:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
                self.reaped = True
        os.close(self.fd)

    def finish(self):
        os.kill(self.pid, signal.SIGTERM)
        self.until(lambda: (self.output / "cleanup.json").exists())
        return json.loads((self.output / "cleanup.json").read_text())

    def test_actual_edits_drive_marker_receipts_and_final_grid(self):
        for sequence in range(1, 5):
            if sequence == 4:
                self.resize(96, 24)
                # Match the GUI harness's untimed layout settling. Draining
                # five already-readable chunks does not wait for SIGWINCH.
                settled = time.monotonic() + .2
                self.until(lambda: time.monotonic() >= settled, timeout=1)
            os.write(self.fd, b"a")
            expected_color = f"48;2;{48 + sequence * 11};48;211".encode()
            self.until(lambda: expected_color in self.bytes)
        cleanup = self.finish()
        receipts = json.loads((self.output / "received.json").read_text())
        self.assertEqual([item["sequence"] for item in receipts], [1, 2, 3, 4])
        self.assertEqual([(item["columns"], item["rows"]) for item in receipts],
                         [(120, 36)] * 3 + [(96, 24)])
        self.assertTrue(all(item["event"] == "TextChangedI" for item in receipts))
        self.assertEqual(cleanup["error"], "")
        self.assertEqual(cleanup["insertedCharacters"], 4)
        self.assertEqual(cleanup["lastValidatedTextSHA256"], hashlib.sha256(b"aaaa").hexdigest())

    def test_unexpected_edit_cannot_become_a_valid_marker_response(self):
        os.write(self.fd, b"b")
        for _ in range(15):
            self.pump()
        cleanup = self.finish()
        self.assertEqual(cleanup["error"], "unexpected edit sequence")
        self.assertEqual(json.loads((self.output / "received.json").read_text()), [])
        self.assertNotIn(b"48;2;59;48;211", self.bytes)


if __name__ == "__main__":
    unittest.main()
