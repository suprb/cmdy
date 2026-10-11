"""Full-gate integration only. Generated records are never native measurements."""
import json
from pathlib import Path
import tempfile
import unittest

import parity_gate
from test_four_pane_adapter import complete_fixture, save


class FourPaneGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmdy-four-pane-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.policy = json.loads(Path(__file__).with_name("parity-policy.json").read_text())
        self.binaries = {"cmdy": "a" * 64, "ghostty": "b" * 64}

    def evaluate(self, paths=None):
        return parity_gate.evaluate(paths or [self.root], self.policy, self.binaries)

    def test_six_pairs_fill_only_the_four_pane_metrics(self):
        complete_fixture(self.root, blocks=6)
        report = self.evaluate()
        self.assertFalse(report["passed"])
        self.assertEqual(report["invalidEvidence"], [])
        measured = [r for r in report["results"] if r["status"] != "not-measured"]
        self.assertEqual(len(measured), 2)
        self.assertEqual({r["case"] for r in measured}, {"input/four-pane"})
        self.assertEqual({r["metric"] for r in measured}, {"p50", "p95"})
        self.assertEqual({r["status"] for r in measured}, {"pass"})
        self.assertEqual({r["pairedBlocks"] for r in measured}, {6})
        self.assertEqual(len(report["results"]), 140)

    def test_wrong_binary_is_rejected_before_reading_raw_runs(self):
        complete_fixture(self.root)
        self.binaries["cmdy"] = "d" * 64
        report = self.evaluate()
        self.assertEqual(len(report["invalidEvidence"]), 1)
        self.assertIn("binary version", report["invalidEvidence"][0]["reason"])
        self.assertTrue(all(r["status"] == "not-measured" for r in report["results"]))

    def test_duplicate_case_cannot_be_used_to_select_a_winner(self):
        complete_fixture(self.root)
        report = self.evaluate([self.root, self.root])
        self.assertFalse(report["passed"])
        self.assertEqual(len(report["invalidEvidence"]), 1)
        self.assertIn("duplicate case/scenario", report["invalidEvidence"][0]["reason"])

    def test_missing_required_source_is_rejected_even_with_rewritten_manifest(self):
        complete_fixture(self.root)
        path = self.root / "metadata.json"
        metadata = json.loads(path.read_text())
        del metadata["toolingSHA256"]["TerminalInputObserver.swift"]
        save(path, metadata)
        report = self.evaluate()
        self.assertEqual(len(report["invalidEvidence"]), 1)
        self.assertIn("missing required source", report["invalidEvidence"][0]["reason"])

    def test_legacy_observer_is_descriptive_even_in_complete_outer_metadata(self):
        complete_fixture(self.root)
        path = self.root / "00-cmdy/latency.json"
        latency = json.loads(path.read_text())
        latency["schemaVersion"] = 2
        save(path, latency)
        report = self.evaluate()
        self.assertEqual(len(report["invalidEvidence"]), 1)
        self.assertIn("schema-3", report["invalidEvidence"][0]["reason"])


if __name__ == "__main__":
    unittest.main()
