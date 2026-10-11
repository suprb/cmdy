"""Public gate integration from explicitly synthetic paste receipts; no GUI."""
import base64
from collections import Counter
import json
from pathlib import Path
import tempfile
import unittest

import parity_gate as gate
from test_paste_evidence import build_records, digest, write

POLICY = json.loads((Path(__file__).parent / "parity-policy.json").read_text())
BINARIES = {"cmdy": "a" * 64, "ghostty": "b" * 64}


def reseal(root, metadata, report):
    folder = root / "runs/00-cmdy"
    write(folder / "observation.json", report)
    run = json.loads((folder / "run.json").read_text())
    run["observationSHA256"] = digest(folder / "observation.json")
    write(folder / "run.json", run)
    record = next(item for item in metadata["runs"] if item["path"] == "runs/00-cmdy")
    record.update(runSHA256=digest(folder / "run.json"),
                  observationSHA256=digest(folder / "observation.json"))
    write(root / "manifest.json", metadata)


class PasteGateTests(unittest.TestCase):
    def test_complete_raw_paste_fills_only_its_two_scenario_metrics(self):
        with tempfile.TemporaryDirectory(prefix="paste-synthetic-gate-") as name:
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
                self.assertEqual((row["scenario"], row["case"]), ("ac-matched", "input/paste"))
                self.assertEqual(row["medianPairedRatio"], 1.0)

    def test_pilot_only_cannot_become_comparative_evidence(self):
        with tempfile.TemporaryDirectory(prefix="paste-synthetic-gate-") as name:
            root = Path(name)
            metadata = build_records(root)
            metadata.update(pilotOnly=True, state="pilot-complete-unpooled")
            write(root / "manifest.json", metadata)
            result = gate.evaluate([root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertIn("pilot-only", result["invalidEvidence"][0]["reason"])
        self.assertTrue(all(row["status"] == "not-measured" for row in result["results"]))

    def test_resealed_last_cell_corruption_rejects_success_summary(self):
        with tempfile.TemporaryDirectory(prefix="paste-synthetic-gate-") as name:
            root = Path(name)
            metadata = build_records(root)
            report = json.loads((root / "runs/00-cmdy/observation.json").read_text())
            sample = report["samples"][0]
            first = sample["stability"]["first"]
            classes = bytearray(base64.b64decode(first["observedCellClasses"], validate=True))
            classes[-1] = (classes[-1] + 1) % 18
            encoded = base64.b64encode(classes).decode("ascii")
            for frame in [first, *sample["frames"]]:
                if frame["displayTicks"] == first["displayTicks"]:
                    frame["observedCellClasses"] = encoded
            reseal(root, metadata, report)
            result = gate.evaluate([root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertIn("observed full-width pixel classes", result["invalidEvidence"][0]["reason"])
        self.assertTrue(all(row["status"] == "not-measured" for row in result["results"]))

    def test_resealed_missing_sample_is_invalid_at_public_entrypoint(self):
        with tempfile.TemporaryDirectory(prefix="paste-synthetic-gate-") as name:
            root = Path(name)
            metadata = build_records(root)
            report = json.loads((root / "runs/00-cmdy/observation.json").read_text())
            report["samples"].pop()
            reseal(root, metadata, report)
            result = gate.evaluate([root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertIn("missing/excess paste samples", result["invalidEvidence"][0]["reason"])

    def test_duplicate_archive_cannot_supply_more_blocks(self):
        with tempfile.TemporaryDirectory(prefix="paste-synthetic-gate-") as name:
            root = Path(name)
            build_records(root)
            result = gate.evaluate([root, root], POLICY, BINARIES)
        self.assertFalse(result["passed"])
        self.assertIn("duplicate case/scenario", result["invalidEvidence"][0]["reason"])

    def test_wrong_candidate_binary_rejects_the_archive(self):
        with tempfile.TemporaryDirectory(prefix="paste-synthetic-gate-") as name:
            root = Path(name)
            build_records(root)
            result = gate.evaluate([root], POLICY, {**BINARIES, "cmdy": "c" * 64})
        self.assertFalse(result["passed"])
        self.assertIn("pinned app binaries differ", result["invalidEvidence"][0]["reason"])


if __name__ == "__main__":
    unittest.main()
