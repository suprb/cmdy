"""Production file writer + existing private PTY intake; no native app or UI."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from history_export_files import inventory, read_generated_export
from history_export_protocol import expectation
from test_history_export import NONCE, OwnedPTYTests, physical_export

HERE = Path(__file__).resolve().parent


class TemporaryDirectoryRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stage = tempfile.TemporaryDirectory(prefix="cmdy-export-routing-", dir="/private/tmp")
        cls.addClassCleanup(cls.stage.cleanup)
        cls.root = Path(cls.stage.name)
        cls.writer = cls.root / "export-writer"
        cls.sources = [HERE.parent / "App/TerminalTextFile.swift", HERE / "fixtures/history_export_writer.swift"]
        cls.command = ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", *map(str, cls.sources),
                       "-module-cache-path", str(cls.root / "swift-module-cache"), "-o", str(cls.writer)]
        result = subprocess.run(cls.command, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError("standalone production file writer did not compile: " + result.stderr)
        cls.build = dict(command=cls.command, exitCode=result.returncode, reaped=True,
                         sourceSHA256={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in cls.sources},
                         binarySHA256=hashlib.sha256(cls.writer.read_bytes()).hexdigest())
        print("ROUTING_BUILD " + json.dumps(cls.build, sort_keys=True), flush=True)

    def invoke(self, mode, *arguments, temporary=None):
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        if temporary is not None:
            environment["TMPDIR"] = temporary
        return subprocess.run([str(self.writer), mode, *map(str, arguments)], env=environment,
                              capture_output=True, timeout=10)

    def default_export(self, spec, directory):
        # The public writer chooses its ordinary default argument. No injected
        # directory URL and no foundation/user temporary directory is opened.
        payload = directory.parent / "writer-payload.bin"
        payload.write_bytes(physical_export(spec)); payload.chmod(0o600)
        result = self.invoke("default", payload, temporary=str(directory) + "/")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        path = Path(result.stdout.decode("ascii"))
        self.assertEqual(path.parent, directory)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(path.stat().st_nlink, 1)
        return path

    def test_default_call_uses_real_private_TMPDIR_and_strict_intake(self):
        with tempfile.TemporaryDirectory(prefix="cmdy-route-file-", dir="/private/tmp") as name:
            root = Path(name); directory = root / "exports"; directory.mkdir(mode=0o700)
            spec = expectation("primary-1000", NONCE); before = inventory(directory)
            path = self.default_export(spec, directory)
            retained = root / "generated-export.bin"
            proof = read_generated_export(str(path).encode(), directory, before, spec, retained)
            self.assertEqual(proof["validation"]["logicalRows"], 1000)
            self.assertEqual(retained.read_bytes(), physical_export(spec))
            self.assertFalse(path.exists())
            self.assertTrue(proof["cleanup"]["sameInodeOnly"])

    def test_explicit_caller_directory_precedes_invalid_environment(self):
        with tempfile.TemporaryDirectory(prefix="cmdy-route-explicit-", dir="/private/tmp") as name:
            root = Path(name); payload = root / "input.bin"; payload.write_bytes(b"generated\n")
            directory = root / "exports"; directory.mkdir(mode=0o700)
            result = self.invoke("explicit", payload, directory, temporary="relative-invalid")
            self.assertEqual(result.returncode, 0, result.stderr)
            path = Path(result.stdout.decode("ascii"))
            self.assertEqual(path.parent, directory)
            self.assertEqual(path.read_bytes(), payload.read_bytes())

    def test_invalid_missing_unusable_or_symlink_TMPDIR_never_falls_back(self):
        with tempfile.TemporaryDirectory(prefix="cmdy-route-reject-", dir="/private/tmp") as name:
            root = Path(name); payload = root / "input.bin"; payload.write_bytes(b"generated\n")
            target = root / "target"; target.mkdir(mode=0o700)
            alias = root / "alias"; alias.symlink_to(target, target_is_directory=True)
            for value in ("", "relative", "file:///private/tmp", str(root / "missing"), str(payload), str(alias)):
                with self.subTest(value=value):
                    result = self.invoke("default", payload, temporary=value)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(result.stderr, b"owned-export-failed\n")
            self.assertEqual(list(target.iterdir()), [])
            self.assertEqual(payload.read_bytes(), b"generated\n")

    def test_absent_environment_resolves_only_to_foundation_without_file_creation(self):
        resolved = self.invoke("resolve"); foundation = self.invoke("foundation")
        self.assertEqual((resolved.returncode, foundation.returncode), (0, 0))
        self.assertEqual(resolved.stdout, foundation.stdout)

    def test_private_PTY_red_outside_directory_remains_rejected(self):
        def outside(spec, directory):
            sibling = directory.parent / "different-owned-directory"; sibling.mkdir(mode=0o700)
            path = sibling / "generated.txt"; path.write_bytes(physical_export(spec)); path.chmod(0o600)
            return path
        fixture = OwnedPTYTests("test_memory_drain_and_export_share_one_worker_tty_reader")
        fixture.run_worker("primary-1000", drain=True, exporter=outside, reject_outside=True)

    def test_private_PTY_green_receives_default_writer_path_and_reaps(self):
        fixture = OwnedPTYTests("test_memory_drain_and_export_share_one_worker_tty_reader")
        fixture.run_worker("primary-1000", drain=True, exporter=self.default_export)


if __name__ == "__main__":
    unittest.main()
