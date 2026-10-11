"""A real exec/termination must unwind the recorder without launching any GUI."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

HERE = Path(__file__).resolve().parent


class PasteInterruptionTests(unittest.TestCase):
    def test_sigterm_after_reexec_runs_owned_cleanup_and_marks_run_invalid(self):
        with tempfile.TemporaryDirectory(prefix="paste-interruption-") as temporary:
            root = Path(temporary)
            script = root / "owned-controller.py"
            script.write_text(textwrap.dedent('''
                import ast, json, os, signal, sys, time
                from pathlib import Path
                sys.path.insert(0, sys.argv[1])
                import paste_bench as bench
                root = Path(sys.argv[2])
                phase = sys.argv[3]
                power = {"signature": {"source": "AC Power", "settings": "synthetic"}}
                native = {"ok": True, "lowPowerMode": False, "thermalState": 0, "os": "synthetic"}
                class Session:
                    def __init__(self, options, helper, terminal, directory, grid, **kwargs):
                        self.directory = directory
                        self.cwd = directory / "cwd"; self.cwd.mkdir(parents=True)
                        self.config_path = directory / "cmdy-config/config"
                        for name in bench.registered_configs(terminal):
                            path = directory / name; path.parent.mkdir(parents=True, exist_ok=True)
                            path.write_text("synthetic configuration; never executed")
                    def launch(self):
                        (root / "ready.json").write_text(json.dumps({"pid": os.getpid(), "phase": phase}))
                        time.sleep(30)
                        raise AssertionError("test must interrupt the owned launch")
                    def close(self):
                        (root / "closed.json").write_text(json.dumps({"closed": True, "pid": os.getpid()}))
                def fixture_main():
                    if phase == "outer":
                        os.execv(sys.executable, [sys.executable, "-B", "-S", str(Path(__file__)), sys.argv[1], str(root), "frozen"])
                    bench.TerminalSession = Session
                    bench.power_snapshot = lambda: power
                    bench.window_command = lambda *_args: native
                    options = bench.BenchOptions(root / "never-launched-cmdy", root / "never-launched-ghostty",
                                                profile="cmdy-defaults", tooling_dir=Path(bench.__file__).parent)
                    bench.run_owned(options, None, None, "cmdy", root / "run", "0123456789abcdef0123456789abcdef",
                                    {"powerBefore": power, "nativeBefore": native, "runtime": {"python": {"path": sys.executable}}})
                # Execute the actual CLI guard, including its real signal setup,
                # while replacing only main's native setup with this fixture.
                tree = ast.parse(Path(bench.__file__).read_text())
                entry = tree.body[-1]
                assert isinstance(entry, ast.If)
                exec(compile(ast.Module(body=[entry], type_ignores=[]), bench.__file__, "exec"),
                     {"__name__": "__main__", "main": fixture_main, "signal": signal})
            '''))
            with (root / "controller.log").open("w+") as log:
                process = subprocess.Popen([sys.executable, "-B", "-S", str(script), str(HERE), str(root), "outer"],
                                           stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 10
                    while not (root / "ready.json").exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(.01)
                    log.flush(); log.seek(0)
                    self.assertTrue((root / "ready.json").exists(), log.read())
                    self.assertEqual(json.loads((root / "ready.json").read_text()), {"pid": process.pid, "phase": "frozen"})
                    process.terminate()
                    self.assertNotEqual(process.wait(timeout=10), 0)
                    self.assertTrue((root / "closed.json").exists(), "termination bypassed owned-session cleanup")
                    record = json.loads((root / "run/run.json").read_text())
                    self.assertEqual(record["status"], "invalid")
                    self.assertIn("interrupted", record["error"])
                    self.assertIn("finishedUTC", record)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
