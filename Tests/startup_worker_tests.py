"""Owned PTYs and generated workers only; never a terminal application or display."""
import fcntl
import hashlib
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
import threading
import time
import unittest
from startup_grid import Witness

HERE=Path(__file__).resolve().parent
TOKEN="0123456789abcdef0123456789abcdef"

class Fixture:
    def __init__(self,name,timeout=8,drain=True,grid=(98,29),target=(98,29),stop_at_loop_check=False):
        self.temporary=None
        root=os.environ.get("STARTUP_PTY_TEST_OUTPUT")
        if not root:self.temporary=tempfile.TemporaryDirectory(prefix="startup-pty-");root=self.temporary.name
        self.output=Path(root)/name;self.output.mkdir(mode=0o700,parents=True,exist_ok=False)
        self.worker=self.output/"worker";self.worker.mkdir(mode=0o700)
        self.master,slave=pty.openpty();self.saved=termios.tcgetattr(slave)
        fcntl.ioctl(self.master,termios.TIOCSWINSZ,struct.pack("HHHH",grid[1],grid[0],0,0))
        def own_terminal():
            os.setsid();fcntl.ioctl(0,termios.TIOCSCTTY,0);os.tcsetpgrp(0,os.getpgrp())
        command=[sys.executable,"-B",str(HERE/"startup_fixture.py"),"--directory",str(self.worker),
            "--token",TOKEN,"--timeout",str(timeout),"--columns",str(target[0]),"--rows",str(target[1])]
        if stop_at_loop_check:
            # Test-only scheduling injection; the benchmark worker has no hook.
            runner=self.output/"stop_at_loop_check.py"
            runner.write_text("""import ast,os,runpy,signal,sys
from pathlib import Path
source=sys.argv[1];sys.argv=sys.argv[1:]
sys.path.insert(0,str(Path(source).parent))
tree=ast.parse(Path(source).read_text())
loop=next(n for n in ast.walk(tree) if isinstance(n,ast.While) and isinstance(n.test,ast.Name) and n.test.id=='running')
line=loop.body[0].lineno
triggered=False
def trace(frame,event,arg):
 global triggered
 if not triggered and event=='line' and frame.f_code.co_filename==source and frame.f_lineno==line:
  assert frame.f_locals['running'] is True
  triggered=True
  os.kill(os.getpid(),signal.SIGTERM)
  sys.settrace(None)
  return None
 return trace
sys.settrace(trace)
runpy.run_path(source,run_name='__main__')
""")
            command=[sys.executable,"-B",str(runner),*command[2:]]
        self.process=subprocess.Popen(command,stdin=slave,stdout=slave,stderr=slave,preexec_fn=own_terminal,close_fds=True)
        os.close(slave);self.received=bytearray();self.disconnected=False
        self.reader=threading.Thread(target=self.drain,daemon=True) if drain else None
        if self.reader:self.reader.start()
        try:
            self.ready=self.await_json("ready.json")
            if self.ready["pid"]!=self.process.pid or self.ready["parentPID"]!=os.getpid():raise AssertionError("worker identity differs")
        except BaseException:self.close();raise

    def drain(self):
        while not self.disconnected:
            try:
                if not select.select([self.master],[],[],.01)[0]:
                    if self.process.poll() is not None:break
                    continue
                data=os.read(self.master,65536)
                if not data:break
                self.received.extend(data)
                if len(self.received)>4*1024*1024:break
            except (OSError,ValueError):break

    def await_json(self,name,count=None):
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            path=self.worker/name
            if path.is_file():
                value=json.loads(path.read_text())
                if count is None or len(value["events"])==count:return value
            if self.process.poll() is not None:raise AssertionError(f"worker exited before {name}: {bytes(self.received[-1000:])!r}")
            time.sleep(.01)
        raise AssertionError("worker did not publish "+name)

    def signal(self,value):
        if self.process.poll() is None:os.kill(self.process.pid,value)

    def wait(self):
        self.process.wait(timeout=4)
        if self.reader:self.reader.join(timeout=1)
        result=json.loads((self.worker/"cleanup.json").read_text())
        if result["termiosRestored"] and termios.tcgetattr(self.master)!=self.saved:
            raise AssertionError("claimed restored termios differs from original")
        return result

    def close(self):
        self.signal(signal.SIGTERM)
        try:self.process.wait(timeout=4)
        except subprocess.TimeoutExpired:self.process.kill();self.process.wait(timeout=2)
        self.disconnected=True
        if self.reader:self.reader.join(timeout=1)
        os.close(self.master)
        (self.output/"generated-pty-bytes.bin").write_bytes(self.received)
        (self.output/"process.json").write_text(json.dumps(dict(pid=self.process.pid,exitCode=self.process.returncode,
            exitedAndReaped=self.process.returncode is not None,applicationLaunches=0,generatedBytes=len(self.received),
            generatedBytesSHA256=hashlib.sha256(self.received).hexdigest()),sort_keys=True)+"\n")
        if self.temporary:self.temporary.cleanup()
import copy
from startup_target_trace import validate

@unittest.skipUnless(sys.platform == "darwin", "native Mach clock fixture")
class StartupWorkerTests(unittest.TestCase):
    def fixture(self, **kwargs):
        worker = Fixture(self._testMethodName, **kwargs)
        self.addCleanup(worker.close)
        return worker

    def resize(self, worker, columns, rows):
        fcntl.ioctl(worker.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def wait_for(self, condition):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(.005)
        self.fail("bounded condition did not arrive")

    def read_events(self, worker):
        return json.loads((worker.worker / "events.json").read_text())

    def start_reader(self, worker):
        self.assertIsNone(worker.reader)
        worker.reader = threading.Thread(target=worker.drain, daemon=True)
        worker.reader.start()

    def stop_success(self, worker, target=(98, 29)):
        worker.signal(signal.SIGTERM)
        cleanup = worker.wait()
        self.assertEqual(worker.process.returncode, 0, cleanup)
        output = self.read_events(worker)
        result = validate(worker.ready, output, cleanup, TOKEN, target)
        self.assertTrue(result["workerTraceValid"])
        self.assertFalse(result["qualifying"])
        expected = Witness(TOKEN, *target, 1, 1).frame_bytes() + b"\x1b[0m\x1b[?7h\x1b[?25h"
        self.assertEqual(bytes(worker.received), expected)
        for name in ("ready.json", "events.json", "cleanup.json"):
            self.assertEqual((worker.worker / name).stat().st_mode & 0o777, 0o600)
        return output, cleanup

    def assert_failed(self, worker, reason):
        cleanup = worker.wait()
        self.assertNotEqual(worker.process.returncode, 0)
        self.assertIn(reason, cleanup["error"])
        self.assertTrue(cleanup["termiosRestored"])
        self.assertTrue(cleanup["flagsRestored"])
        output = self.read_events(worker)
        self.assertEqual(output["status"], "failed")
        with self.assertRaises(ValueError):
            validate(worker.ready, output, cleanup, TOKEN, (98, 29))
        self.assertLessEqual(len(output["events"]), 1)
        return output, cleanup

    def test_initial_target_paints_once_without_parent_ack(self):
        worker = self.fixture()
        worker.await_json("events.json", 1)
        output, _ = self.stop_success(worker)
        self.assertEqual(output["firstTargetIndex"], 0)
        self.assertEqual(output["signals"], [])

    def test_stop_between_loop_condition_and_check_after_paint_is_clean(self):
        worker = self.fixture(stop_at_loop_check=True)
        worker.await_json("events.json", 1)
        worker.wait()
        output, cleanup = self.stop_success(worker)
        self.assertTrue(cleanup["completedViewport"])
        self.assertEqual(output["gridObservations"][-1]["reason"], "final")

    def test_stop_between_loop_condition_and_check_before_target_fails(self):
        worker = self.fixture(grid=(44, 16), stop_at_loop_check=True)
        output, cleanup = self.assert_failed(worker, "stopped before target viewport complete")
        self.assertEqual(output["events"], [])
        self.assertFalse(cleanup["completedViewport"])

    def test_stop_during_partial_write_cannot_claim_completion(self):
        worker = self.fixture(drain=False)
        self.assertTrue(select.select([worker.master], [], [], 2)[0])
        worker.signal(signal.SIGTERM)
        output, cleanup = self.assert_failed(worker, "stopped before target viewport complete")
        self.assertEqual(output["events"], [])
        self.assertFalse(cleanup["completedViewport"])

    def test_transient_grid_is_retained_and_no_bytes_precede_target(self):
        worker = self.fixture(grid=(44, 16), target=(98, 24))
        self.assertFalse((worker.worker / "events.json").exists())
        self.assertEqual((worker.ready["initialColumns"], worker.ready["initialRows"]), (44, 16))
        time.sleep(.12)
        self.assertEqual(bytes(worker.received), b"")
        self.resize(worker, 98, 24)
        worker.await_json("events.json", 1)
        output, _ = self.stop_success(worker, (98, 24))
        self.assertGreater(output["firstTargetIndex"], 0)
        self.assertLess(worker.ready["startedTicks"], output["events"][0]["observedTicks"])
        self.assertGreaterEqual(len(output["signals"]), 1)

    def test_noop_signals_before_and_after_target_never_repaint(self):
        worker = self.fixture(grid=(44, 16))
        worker.signal(signal.SIGWINCH)
        time.sleep(.05)
        self.assertEqual(bytes(worker.received), b"")
        self.resize(worker, 98, 29)
        worker.await_json("events.json", 1)
        count = len(self.read_events(worker)["signals"])
        worker.signal(signal.SIGWINCH)
        self.wait_for(lambda: len(self.read_events(worker)["signals"]) > count)
        output, _ = self.stop_success(worker)
        self.assertEqual(len(output["events"]), 1)
        self.assertGreater(len(output["signals"]), output["events"][0]["signalCounter"])

    def test_signal_during_blocked_write_keeps_separate_counters(self):
        worker = self.fixture(drain=False)
        self.assertTrue(select.select([worker.master], [], [], 2)[0])
        self.assertFalse((worker.worker / "events.json").exists())
        worker.signal(signal.SIGWINCH)
        time.sleep(.05)
        self.start_reader(worker)
        worker.await_json("events.json", 1)
        output, _ = self.stop_success(worker)
        event = output["events"][0]
        self.assertEqual(event["signalCounterAtObserved"], 0)
        self.assertEqual(event["signalCounterAtStarted"], 0)
        self.assertEqual(event["signalCounter"], 1)
        self.assertTrue(any(value["reason"] == "signal-during-write" for value in output["gridObservations"]))

    def test_grid_change_during_blocked_write_fails_without_repaint(self):
        worker = self.fixture(drain=False)
        self.assertTrue(select.select([worker.master], [], [], 2)[0])
        self.resize(worker, 100, 30)
        output, _ = self.assert_failed(worker, "grid changed after first target")
        self.assertEqual(output["events"], [])
        self.assertLess(output["paintAttempt"]["completedBytes"], output["paintAttempt"]["offeredBytes"])

    def test_grid_change_after_paint_fails_without_repaint(self):
        worker = self.fixture()
        worker.await_json("events.json", 1)
        self.resize(worker, 100, 30)
        output, _ = self.assert_failed(worker, "grid changed after first target")
        self.assertEqual(len(output["events"]), 1)
        expected = Witness(TOKEN, 98, 29, 1, 1).frame_bytes() + b"\x1b[0m\x1b[?7h\x1b[?25h"
        self.assertEqual(bytes(worker.received), expected)

    def test_wrong_grid_deadline_preserves_actual_initial_grid(self):
        worker = self.fixture(timeout=1, grid=(0, 0))
        output, cleanup = self.assert_failed(worker, "deadline expired")
        self.assertEqual((worker.ready["initialColumns"], worker.ready["initialRows"]), (0, 0))
        self.assertEqual(output["events"], [])
        self.assertIsNone(output["firstTargetIndex"])
        self.assertFalse(cleanup["completedViewport"])

    def test_stalled_first_write_cannot_claim_completion(self):
        worker = self.fixture(timeout=1, drain=False)
        output, cleanup = self.assert_failed(worker, "deadline expired")
        self.assertEqual(output["events"], [])
        self.assertFalse(cleanup["completedViewport"])
        self.assertNotIn("completedTicks", output["paintAttempt"])

    def test_q_before_target_is_failure(self):
        worker = self.fixture(grid=(44, 16))
        os.write(worker.master, b"q")
        output, _ = self.assert_failed(worker, "stopped before target viewport complete")
        self.assertIsNone(output["paintAttempt"])

    def test_unexpected_input_is_rejected(self):
        worker = self.fixture()
        worker.await_json("events.json", 1)
        os.write(worker.master, b"\x1b[1;1R")
        self.assert_failed(worker, "unexpected input")

    def test_delivered_signal_overflow_fails_closed(self):
        worker = self.fixture()
        worker.await_json("events.json", 1)
        for count in range(1, 65):
            worker.signal(signal.SIGWINCH)
            self.wait_for(lambda: len(self.read_events(worker)["signals"]) == count)
        worker.signal(signal.SIGWINCH)
        output, _ = self.assert_failed(worker, "SIGWINCH record bound exceeded")
        self.assertTrue(output["signalOverflow"])
        self.assertEqual(len(output["signals"]), 64)

    def test_trace_mutations_fail_independent_validation(self):
        worker = self.fixture(grid=(44, 16))
        self.resize(worker, 98, 29)
        worker.await_json("events.json", 1)
        output, cleanup = self.stop_success(worker)
        ready = worker.ready
        mutations = {
            "replaced initial": lambda r, o, c: r.update(initialColumns=98, initialRows=29),
            "wrong nonce": lambda r, o, c: o.update(token="f" * 32),
            "reordered observation": lambda r, o, c: o["gridObservations"].reverse(),
            "missing observation": lambda r, o, c: o["gridObservations"].pop(0),
            "future observation": lambda r, o, c: o["gridObservations"][0].update(afterTicks=c["finishedTicks"] + 1),
            "counter forged": lambda r, o, c: o["gridObservations"][0].update(signalCounterBefore=64),
            "target skipped": lambda r, o, c: o.update(firstTargetIndex=o["firstTargetIndex"] + 1),
            "extra generation": lambda r, o, c: o["events"].append(copy.deepcopy(o["events"][0])),
            "partial write": lambda r, o, c: o["events"][0].update(completedBytes=1),
            "wrong payload": lambda r, o, c: o["events"][0].update(payloadSHA256="0" * 64),
            "write clock reset": lambda r, o, c: o["events"][0].update(observedTicks=r["startedTicks"]),
            "paint signal forged": lambda r, o, c: o["events"][0].update(signalCounterAtObserved=64),
            "future signal": lambda r, o, c: o["signals"].append(dict(receivedTicks=c["finishedTicks"] + 1)),
            "cleanup missing": lambda r, o, c: c.update(termiosRestored=False),
            "diagnostic marker missing": lambda r, o, c: o.update(diagnosticOnly=False),
            "overflow hidden": lambda r, o, c: o.update(signalOverflow=True),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                r, o, c = copy.deepcopy((ready, output, cleanup))
                mutate(r, o, c)
                with self.assertRaises(ValueError):
                    validate(r, o, c, TOKEN, (98, 29))


if __name__ == "__main__":
    unittest.main(verbosity=2)
