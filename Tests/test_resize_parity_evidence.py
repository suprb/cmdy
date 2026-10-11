"""Campaign admission boundaries and gate dispatch; no GUI or native processes."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import parity_gate as gate
import resize_parity_evidence as reader
from test_parity_gate import BINARIES, POLICY, evidence


def plan():
    return dict(cases=reader.expected_cases(), nativeAppLaunches=24, pairsPerProfile=6,
        eventsPerApp=42, warmupsPerApp=2, measuredEventsPerApp=40, historyGrowthGuardRows=4,
        fixtureVariant="explicit-four-row-history-growth-guard-v1", performanceAdmission=False,
        candidateExecutableSHA256=BINARIES["cmdy"], comparatorExecutableSHA256=BINARIES["ghostty"],
        powerSource="AC Power", minimumInitialIdleSeconds=300, lowPowerMode=False, thermalState=0,
        policySHA256=reader.digest(Path(reader.__file__).with_name("parity-policy.json")))


class ResizeCampaignAdmissionTests(unittest.TestCase):
    def test_raw_audit_must_match_planned_power_and_exact_plan(self):
        plan_hash = "a" * 64
        for source, label in (("AC Power", "AC"), ("Battery Power", "battery")):
            value = plan(); value["powerSource"] = source
            reader.validate_plan(value, BINARIES)
            audit = dict(status=f"pass-independent-complete-{label}-resize-campaign-audit",
                         planSHA256=plan_hash)
            reader.validate_raw_audit(audit, value, plan_hash)
            other = "battery" if label == "AC" else "AC"
            for invalid in (dict(audit, status=f"pass-independent-complete-{other}-resize-campaign-audit"),
                            dict(audit, status="pass"), dict(audit, planSHA256="b" * 64)):
                with self.subTest(source=source, invalid=invalid), self.assertRaises(ValueError):
                    reader.validate_raw_audit(invalid, value, plan_hash)
        with self.assertRaises(ValueError):
            reader.validate_raw_audit(audit, dict(value, powerSource="unknown"), plan_hash)

    def test_exact_six_pair_plan_is_required_for_each_profile(self):
        reader.validate_plan(plan(), BINARIES)
        changes = [lambda p: p["cases"].pop(), lambda p: p["cases"].reverse(),
            lambda p: p.update(pairsPerProfile=5), lambda p: p.update(measuredEventsPerApp=39),
            lambda p: p.update(warmupsPerApp=0), lambda p: p.update(historyGrowthGuardRows=True),
            lambda p: p.update(fixtureVariant="private-four-row-growth-guard-v1"),
            lambda p: p.update(fixtureOverlays={}), lambda p: p.update(performanceAdmission=True),
            lambda p: p.update(candidateExecutableSHA256="c"*64),
            lambda p: p.update(minimumInitialIdleSeconds=299), lambda p: p.update(lowPowerMode=True),
            lambda p: p.update(thermalState=1), lambda p: p.update(policySHA256="0"*64)]
        for change in changes:
            value = plan(); change(value)
            with self.subTest(value=value), self.assertRaises(ValueError): reader.validate_plan(value, BINARIES)

    def test_source_snapshot_paths_cannot_leave_campaign(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            for name in ("../outside", "/outside", "nested/../../outside"):
                with self.assertRaises(ValueError): reader.contained(root, name)
            (root / "escape").symlink_to(root.parent)
            with self.assertRaises(ValueError): reader.contained(root, "escape/outside")

    def test_post_run_identity_cannot_claim_it_was_a_pre_run_condition_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); directory = root / "post-campaign-machine"; directory.mkdir()
            (directory / "identity.json").write_text(json.dumps(dict(
                scope="supplementary-post-campaign-machine-identification", capturedBeforeCampaign=True,
                doesNotReplaceNativeConditionsOrPerEventDisplayProof=True)))
            with self.assertRaisesRegex(ValueError, "timing/scope"):
                reader.validate_machine(root, {}, {}, 0, 0, {})

    def test_gate_dispatches_both_profiles_and_still_requires_every_policy_case(self):
        policy = deepcopy(POLICY)
        policy["scenarios"] = [dict(id="ac-matched", powerSource="AC Power", profile="matched"),
                               dict(id="ac-defaults", powerSource="AC Power", profile="cmdy-defaults")]
        policy["cases"] = [dict(id="resize", metrics=["p50", "p95"]), dict(id="input/editor", metrics=["p50", "p95"])]
        items = [dict(evidence(cmdy=[8.]*40, ghostty=[10.]*40), case="resize", kind="input",
                      profile=profile, power=dict(source="AC Power", settings="test only"))
                 for profile in ("matched", "cmdy-defaults")]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / "manifest.json").write_text(json.dumps(dict(benchmarkKind=reader.KIND)))
            with patch.object(reader, "load_resize_evidence", return_value=items) as loader:
                report = gate.evaluate([root], policy, BINARIES)
            loader.assert_called_once_with(root, BINARIES)
            self.assertFalse(report["passed"])
            self.assertEqual([r["status"] for r in report["results"] if r["case"] == "resize"], ["pass"]*4)
            self.assertEqual([r["status"] for r in report["results"] if r["case"] == "input/editor"], ["not-measured"]*4)
            with patch.object(reader, "load_resize_evidence", side_effect=ValueError("missing history")):
                rejected = gate.evaluate([root], policy, BINARIES)
            self.assertFalse(rejected["passed"]); self.assertEqual(len(rejected["invalidEvidence"]), 1)
            self.assertTrue(all(row["status"] == "not-measured" for row in rejected["results"]))


if __name__ == "__main__": unittest.main()
