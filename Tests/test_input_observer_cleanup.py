"""Real owned subprocess cancellation; no terminal apps or native event posting."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("input_cleanup_bench", HERE / "input-latency-bench.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class OwnedObserverCleanupTests(unittest.TestCase):
    def test_timeout_reaps_observer_and_retains_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / "observer.json"
            with self.assertRaises(subprocess.TimeoutExpired):
                bench.run_observer([sys.executable, "-c",
                    "import time; print('owned observer started', flush=True); time.sleep(30)"],
                    receipt, timeout=.3)
            record = json.loads(receipt.read_text())
            self.assertTrue(record["reaped"])
            self.assertTrue(record["interrupted"])
            self.assertIn("owned observer started", record["stdout"])
            with self.assertRaises(ProcessLookupError):
                os.kill(record["pid"], 0)

    def test_supervisor_stop_reaps_observer_before_return_and_keeps_other_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            ready, receipt = directory / "ready", directory / "receipt.json"
            generator = directory / "generator.py"
            generator.write_text("import os,sys,time\nfrom pathlib import Path\n"
                                 "Path(sys.argv[1]).write_text(str(os.getpid()))\ntime.sleep(30)\n")
            controller = directory / "controller.py"
            controller.write_text("import importlib.util,sys\nfrom pathlib import Path\n"
                "sys.path.insert(0,sys.argv[1])\n"
                "s=importlib.util.spec_from_file_location('fixture_bench',Path(sys.argv[1])/'input-latency-bench.py')\n"
                "b=importlib.util.module_from_spec(s); s.loader.exec_module(b)\n"
                "try:\n"
                " with b.interruption_guard():\n"
                "  b.run_observer([sys.executable,sys.argv[2],sys.argv[3]],Path(sys.argv[4]))\n"
                "except RuntimeError:\n sys.exit(9)\n")
            other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            process = subprocess.Popen([sys.executable, str(controller), str(HERE), str(generator),
                                        str(ready), str(receipt)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists(), "owned observer did not start")
                pid = int(ready.read_text())
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 9, (stdout, stderr))
                record = json.loads(receipt.read_text())
                self.assertEqual(record["pid"], pid)
                self.assertTrue(record["reaped"])
                self.assertTrue(record["interrupted"])
                self.assertIn("signal 15", record["error"])
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
                self.assertIsNone(other.poll())
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)
                other.terminate()
                other.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
