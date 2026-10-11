"""Replay sealed native metadata; never launch an application or native helper."""
from copy import deepcopy
import hashlib
import os
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import resize_batch_reader as reader


REPORT = Path(os.environ.get("CMDY_PERFORMANCE_NOTES", Path(__file__).resolve().parents[1] / "docs/performance")) \
    / "results/2026-09-20-resize-batch-integration"


@unittest.skipUnless((REPORT / "archive-manifest.json").is_file(),
                     "resize evidence lives in the private notes; set CMDY_PERFORMANCE_NOTES")
class CompleteResizeBatchReaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        report = REPORT
        manifest = json.loads((report / "archive-manifest.json").read_text())
        archive = report / "cmdy-batch-evidence.tar.gz"
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest["archiveSHA256"]
        cls.temporary = tempfile.TemporaryDirectory(prefix="resize-batch-replay-")
        cls.root = Path(cls.temporary.name)
        with tarfile.open(archive, "r:gz") as stream:
            members = stream.getmembers()
            assert len(members) == len(manifest["files"]) and sum(x.size for x in members) < 64 * 1024 * 1024
            for member in members:
                target = cls.root / member.name
                assert member.isfile() and not Path(member.name).is_absolute() and ".." not in Path(member.name).parts
                raw = stream.extractfile(member).read()
                assert hashlib.sha256(raw).hexdigest() == manifest["files"][member.name]
                target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)

    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()

    def test_complete_native_batch_replays_with_no_competitive_admission(self):
        value = reader.validate_batch(self.root)
        self.assertEqual((value["events"], value["warmups"], value["measuredEvents"]), (42, 2, 40))
        self.assertEqual((value["historyExports"], value["viewportProofs"]), (2, 4))
        self.assertFalse(value["qualifying"]); self.assertFalse(value["performanceAdmission"])

    def test_cross_receipt_mutations_cannot_reuse_individually_valid_events(self):
        mutations = [
            ("batch/request.json", lambda x: x.update(historyGrowthGuardRows=4)),
            ("fixture/ready.json", lambda x: x.update(historyGrowthGuardRows=4)),
            ("batch/request.json", lambda x: x.update(block=1)),
            ("fixture/cleanup.json", lambda x: x.update(historyExports=1)),
            ("fixture/cleanup.json", lambda x: x.update(termiosRestored=False)),
            ("fixture/received.json", lambda x: x["events"].reverse()),
            ("batch/timed/event-10.json", lambda x: x["entry"]["arm"].update(pid=1)),
            ("batch/timed/event-10.json", lambda x: x["planned"].update(warmup=True)),
            ("batch/timed/native/0024.json", lambda x: x.update(sequence=999)),
            ("batch/after-history/document.json", lambda x: x["workerArm"].update(phase="before")),
            ("batch/timed/native/cleanup.json", lambda x: x.update(returncode=-15)),
            ("fixture/received.json", lambda x: x["writes"][0].update(bytes=x["writes"][0]["bytes"]+1)),
        ]
        original = reader.read
        for name, mutate in mutations:
            def changed(path):
                value = deepcopy(original(path))
                if Path(path) == self.root / name: mutate(value)
                return value
            with self.subTest(file=name), patch.object(reader, "read", side_effect=changed), self.assertRaises(ValueError):
                reader.validate_batch(self.root)

    def test_missing_event_file_is_rejected(self):
        source = self.root / "batch/timed/event-41.json"; moved = source.with_suffix(".held")
        source.rename(moved)
        try:
            with self.assertRaisesRegex(ValueError, "event coverage"): reader.validate_batch(self.root)
        finally: moved.rename(source)


if __name__ == "__main__": unittest.main()
