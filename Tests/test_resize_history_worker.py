"""Full owned-PTY resize batches and public-file intake; no native app actions."""
from pathlib import Path
import json
import os
import sys
import time
import unittest

from resize_protocol import digest, frame_bytes, history, sequence_plan
from test_resize_worker import Fixture, NONCE


@unittest.skipUnless(sys.platform == "darwin", "worker records native Darwin ticks")
class ResizeHistoryWorkerTests(unittest.TestCase):
    def fixture(self, block=3):
        value = Fixture(self._testMethodName, timeout=35, paired_block=block,
                        history_growth_guard=getattr(self, "guarded", False))
        self.addCleanup(value.close)
        return value

    def prepare_batch(self, worker):
        worker.request("prepare")
        for sequence, target in [(1, (132, 40)), (2, (120, 36))]:
            worker.request("arm", sequence=sequence, grid=dict(zip(("columns", "rows"), target)))
            worker.resize(*target)
            worker.completed(sequence)
        return worker.request("start-batch")

    def export(self, worker, phase, raw=None):
        armed = worker.request("history-arm", phase=phase)
        path = Path(worker.export_directory.name) / (phase + ".txt")
        path.write_bytes(history(NONCE) if raw is None else raw); path.chmod(0o600)
        os.write(worker.master, str(path).encode())
        return armed

    def await_export(self, worker, count):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            value = worker.request("status")
            if len(value["historyTransfer"]["completed"]) == count:
                return value["historyTransfer"]["completed"][-1]
            time.sleep(.1)
        self.fail("fixed export receive interval did not complete")

    def reject(self, worker, op, code, **fields):
        with self.assertRaises((RuntimeError, ConnectionError, OSError)):
            worker.request(op, **fields)
        cleanup = worker.wait()
        self.assertEqual(cleanup["error"], code)
        self.assertEqual(cleanup["exportInputBytesRetained"], 0)
        self.assertEqual(worker.process.returncode, 1)
        self.assertTrue(cleanup["termiosRestored"])

    def test_full_42_transition_batch_preserves_history_and_one_reader_lifetime(self):
        guarded = getattr(self, "guarded", False)
        worker = self.fixture()
        self.assertEqual(worker.ready.get("historyGrowthGuardRows", 0), 4 if guarded else 0)
        start = self.prepare_batch(worker)
        self.assertEqual(start["completedEvents"], 0)
        self.assertEqual(len(start["calibrationEvents"]), 2)
        self.assertFalse(start["batchStart"]["historyReloaded"])
        self.assertEqual(start["batchStart"]["sequence"], 126)
        self.export(worker, "before", history(NONCE) + b"\n" * (85 if guarded else 81))
        before = self.await_export(worker, 1)
        self.assertEqual(before["proof"]["validation"]["logicalRows"], 1000)
        self.assertEqual(before["proof"]["validation"]["trailingEmptyRows"], 86 if guarded else 82)
        for index, event in enumerate(sequence_plan(3)):
            worker.request("arm", sequence=event["sequence"],
                           grid=dict(columns=event["columns"], rows=event["rows"]))
            worker.resize(event["columns"], event["rows"])
            value = worker.completed(index + 1)["events"][-1]
            self.assertEqual(value["payloadSHA256"], digest(frame_bytes(NONCE, event["sequence"], event["columns"], event["rows"], history_growth_guard=guarded)))
            self.assertEqual(value["epoch"], "batch")
        self.export(worker, "after", history(NONCE) + b"\n" * (1093 if guarded else 1005))
        after = self.await_export(worker, 2)
        self.assertEqual(after["sequence"], 168)
        self.assertEqual(after["proof"]["validation"]["trailingEmptyRows"], 1094 if guarded else 1006)
        self.assertEqual(after["proof"]["validation"]["normalizedSHA256"], before["proof"]["validation"]["normalizedSHA256"])
        worker.request("finish")
        cleanup = worker.wait()
        self.assertEqual(worker.process.returncode, 0)
        self.assertEqual((cleanup["calibrationEvents"], cleanup["batchEvents"], cleanup["historyExports"]), (2, 42, 2))
        self.assertEqual(cleanup["exportInputBytesRetained"], 0)
        self.assertEqual(cleanup["pid"], worker.ready["pid"])
        self.assertEqual(bytes(worker.received).count(history(NONCE)), 1)
        received = json.loads((worker.output / "received.json").read_text())
        self.assertEqual([v["sequence"] for v in received["events"]], list(range(127, 169)))
        for event in received["calibrationEvents"]:
            self.assertEqual(event["payloadSHA256"], digest(frame_bytes(NONCE[::-1], event["sequence"], **event["grid"], history_growth_guard=guarded)))
        self.assertEqual(list(Path(worker.export_directory.name).iterdir()), [])

    def test_full_42_transition_batch_with_explicit_growth_guard(self):
        self.guarded = True
        self.test_full_42_transition_batch_preserves_history_and_one_reader_lifetime()

    def test_batch_cannot_start_without_calibration_round_trip(self):
        worker = self.fixture(); worker.request("prepare")
        self.reject(worker, "start-batch", "batch-requires-complete-round-trip-calibration")

    def test_measured_resize_requires_before_export(self):
        worker = self.fixture(); self.prepare_batch(worker)
        self.reject(worker, "arm", "resize-requires-before-export-and-unfinished-batch",
                    sequence=127, grid=dict(columns=132, rows=40))

    def test_resize_cannot_overlap_path_receive_window(self):
        worker = self.fixture(); self.prepare_batch(worker)
        worker.request("history-arm", phase="before")
        self.reject(worker, "arm", "resize-cannot-overlap-history-export",
                    sequence=127, grid=dict(columns=132, rows=40))

    def test_after_export_requires_all_42_events(self):
        worker = self.fixture(); self.prepare_batch(worker)
        self.reject(worker, "history-arm", "history-export-requires-quiescent-batch-boundary", phase="after")

    def test_early_finish_cannot_create_complete_batch(self):
        worker = self.fixture(); self.prepare_batch(worker)
        self.reject(worker, "finish", "finish-requires-complete-batch-and-both-history-exports")

    def test_skipped_calibration_sequence_is_rejected(self):
        worker = self.fixture(); worker.request("prepare")
        self.reject(worker, "arm", "resize-sequence-or-target-deviates-from-plan",
                    sequence=2, grid=dict(columns=132, rows=40))

    def test_corrupt_export_fails_without_retaining_unrecognized_content(self):
        worker = self.fixture(); self.prepare_batch(worker)
        self.export(worker, "before", b"unrecognized-content-must-not-be-retained")
        cleanup = worker.wait()
        self.assertEqual(worker.process.returncode, 1)
        self.assertEqual(cleanup["exportInputBytesRetained"], 0)
        self.assertNotIn("unrecognized-content", json.dumps(cleanup))
        self.assertFalse((worker.output / "history-exports/before/generated-export.bin").exists())
        received = json.loads((worker.output / "received.json").read_text())
        counts = received["historyTransfer"]["failureDiagnostic"]
        self.assertEqual(counts["expectedRowIndex"], 0)
        self.assertEqual(counts["exactExpectedRowSplitLengths"], [])
        self.assertNotIn("unrecognized-content", json.dumps(received))


if __name__ == "__main__": unittest.main()
