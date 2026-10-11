"""Compile the exact helper policy with synthetic observations; no native queries."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class WindowSetupPolicyTests(unittest.TestCase):
    def test_generated_native_observations(self):
        here = Path(__file__).resolve().parent
        source = (here / "TerminalBenchWindow.swift").read_text()
        boundary = "#if !CMDY_WINDOW_SETUP_TEST\n"
        self.assertEqual(source.count(boundary), 1)
        # Swift still parses inactive top-level statements in library mode.
        # Compile the unchanged declarations preceding the CLI boundary, then
        # provide the synthetic test entry point. Never invoke the real CLI.
        policy = source.split(boundary)[0]
        with tempfile.TemporaryDirectory(prefix="cmdy-window-setup-test-") as temporary:
            root = Path(temporary)
            declarations = root / "WindowSetupPolicy.swift"
            declarations.write_text(policy)
            binary = root / "window-setup-tests"
            command = ["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library", str(declarations),
                       str(here / "test_terminal_window_setup.swift"), "-o", str(binary)]
            built = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["status"], "passed")
            self.assertGreaterEqual(report["checks"], 50)
            self.assertEqual(report["nativeQueries"], 0)
            self.assertEqual(report["resizeCallsAgainstRealWindows"], 0)
            print(json.dumps({**report, "declarationsSHA256": hashlib.sha256(policy.encode()).hexdigest(),
                              "sourceSHA256": hashlib.sha256(source.encode()).hexdigest()}, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
