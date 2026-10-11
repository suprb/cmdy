"""Public gate integration using explicitly synthetic archives; no GUI calls."""
from collections import Counter
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest

import parity_gate as gate
from test_scroll_complete_evidence import build_records, digest, write

POLICY = json.loads((Path(__file__).parent / "parity-policy.json").read_text())
BINARIES = {"cmdy": "a" * 64, "ghostty": "b" * 64}


def reseal(root, metadata, report):
    folder = root / "runs/00-cmdy"
    write(folder / "observation.json", report)
    raw = json.loads((folder / "run.json").read_text())
    raw["observationSHA256"] = digest(folder / "observation.json")
    write(folder / "run.json", raw)
    metadata["runs"][0].update(runSHA256=digest(folder / "run.json"),
                               observationSHA256=digest(folder / "observation.json"))
    write(root / "manifest.json", metadata)


class ScrollGateTests(unittest.TestCase):
    def test_complete_raw_scroll_reaches_gate_without_filling_other_cases(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-gate-") as name:
            root = Path(name)
            build_records(root)
            write(root / "summary.json", {"passed": True, "inventedDurationMS": 0})
            result = gate.evaluate([root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertEqual(result["invalidEvidence"], [])
        self.assertEqual(Counter(row["status"] for row in result["results"]),
                         {"pass": 2, "not-measured": 138})
        for row in result["results"]:
            if row["status"] == "pass":
                self.assertEqual((row["scenario"], row["case"]), ("ac-matched", "scroll"))
                self.assertEqual(row["medianPairedRatio"], 1.0)

    def test_resealed_missing_sample_is_invalid_at_public_entrypoint(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-gate-") as name:
            root = Path(name)
            metadata = build_records(root)
            report = json.loads((root / "runs/00-cmdy/observation.json").read_text())
            report["samples"].pop()
            reseal(root, metadata, report)
            result = gate.evaluate([root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertIn("missing/excess measured", result["invalidEvidence"][0]["reason"])
        self.assertTrue(all(row["status"] == "not-measured" for row in result["results"]))

    def test_calibration_or_wrong_binary_cannot_become_comparative_evidence(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-gate-") as name:
            root = Path(name)
            metadata = build_records(root)
            result = gate.evaluate([root], POLICY, {**BINARIES, "cmdy": "c" * 64})
            self.assertIn("pinned binaries differ", result["invalidEvidence"][0]["reason"])
            metadata["calibrationOnly"] = True
            metadata["state"] = "calibrated-unpooled"
            write(root / "manifest.json", metadata)
            result = gate.evaluate([root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertIn("calibration-only", result["invalidEvidence"][0]["reason"])

    def test_duplicate_scroll_archive_cannot_supply_more_blocks(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-gate-") as name:
            root = Path(name)
            build_records(root)
            result = gate.evaluate([root, root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertIn("duplicate case/scenario", result["invalidEvidence"][0]["reason"])

    def test_resealed_unrepresentable_native_clocks_fail_without_crashing_gate(self):
        with tempfile.TemporaryDirectory(prefix="scroll-synthetic-gate-") as name:
            root = Path(name)
            original_metadata = build_records(root)
            original = json.loads((root / "runs/00-cmdy/observation.json").read_text())
            for container, field, value in (
                    ("timebase", "numer", 2**32), ("timebase", "denom", True),
                    ("clockAfter", "absoluteTicks", 2**64),
                    ("clockAfter", "wallNS", 10**400)):
                with self.subTest(container=container, field=field):
                    metadata, report = deepcopy(original_metadata), deepcopy(original)
                    report[container][field] = value
                    reseal(root, metadata, report)
                    result = gate.evaluate([root], POLICY, BINARIES)
                    self.assertFalse(result["passed"])
                    self.assertEqual(len(result["invalidEvidence"]), 1)


if __name__ == "__main__":
    unittest.main()
