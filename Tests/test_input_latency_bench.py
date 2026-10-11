"""Artifact/qualification checks with fake processes; no GUI, builds or timings."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("input_latency_bench", Path(__file__).with_name("input-latency-bench.py"))
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


def power(source="AC Power"):
    return {"signature": {"source": source, "settings": "Battery powermode 1; AC powermode 0"}}


def observer(low=False, thermal=0):
    return {"environment": {"lowPowerMode": low, "thermalState": thermal}}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


class ArtifactValidityTests(unittest.TestCase):
    def test_existing_output_is_untouched_even_when_failure_file_already_exists(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            write(output / "summary.json", {"valid": True, "oldEvidence": "preserve"})
            write(output / "failure.json", {"oldEvidence": "also preserve"})
            before = {path.name: path.read_bytes() for path in output.iterdir()}
            with patch.object(bench, "create_helper") as helper, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(bench.main(["--output", str(output)]), 1)
            helper.assert_not_called()
            self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, before)

    def test_missing_power_conditions_cannot_qualify(self):
        for snapshot in ({}, {"signature": {}}, {"signature": {"source": "", "settings": "x"}},
                         {"signature": {"source": "AC Power", "settings": None}}):
            with self.subTest(snapshot=snapshot), self.assertRaises(RuntimeError):
                bench.ConditionGuard(snapshot)

    def test_power_change_between_individually_stable_blocks_is_rejected(self):
        guard = bench.ConditionGuard(power())
        guard.check_power(power())
        guard.check_power(power())
        with self.assertRaises(RuntimeError):
            guard.check_power(power("Battery Power"))

    def test_observer_policy_must_match_across_blocks_and_reference_profiles(self):
        reference = {"power": power()["signature"], "observer": observer()["environment"]}
        guard = bench.ConditionGuard(power(), reference)
        guard.check_observer(observer())
        for changed in (observer(low=True), observer(thermal=1)):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                guard.check_observer(changed)
        with self.assertRaises(RuntimeError):
            bench.ConditionGuard(power("Battery Power"), reference)

    def test_missing_observer_fields_are_not_assumed_normal(self):
        for report in ({}, {"environment": {"lowPowerMode": False}}, observer(thermal="0")):
            with self.subTest(report=report), self.assertRaises(RuntimeError):
                bench.ConditionGuard(power()).check_observer(report)

    def test_prior_profile_reference_checks_every_raw_run_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write(directory / "summary.json", {"valid": True, "blocks": [{}, {}]})
            write(directory / "metadata.json", {"powerBefore": power()})
            for name in ("00-cmdy", "00-ghostty"):
                write(directory / name / "power.json", {"before": power(), "after": power()})
                write(directory / name / "latency.json", observer())
            result = bench.reference_conditions(directory)
            self.assertEqual(result["observer"], observer()["environment"])
            write(directory / "00-ghostty/power.json", {"before": power("Battery Power"), "after": power("Battery Power")})
            before = (directory / "00-ghostty/power.json").read_bytes()
            with self.assertRaises(RuntimeError):
                bench.reference_conditions(directory)
            self.assertEqual((directory / "00-ghostty/power.json").read_bytes(), before)


class BusyFixtureFinalizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.identities = {2001: "busy1", 2002: "busy2", 2003: "busy3", 1001: "primary"}
        self.session = SimpleNamespace(directory=self.directory, app_pid=1000,
                                       process=Mock(), worker_identity=(1001, "primary"),
                                       busy_worker_identities={pid: value for pid, value in self.identities.items() if pid != 1001})
        self.session.process.poll.return_value = None
        write(self.directory / "fixture/received.json", [])
        write(self.directory / "fixture/cleanup.json", {"pid": 1001, "status": "stopped"})
        self.publish_busy("running")

    def tearDown(self):
        self.temporary.cleanup()

    def publish_busy(self, status="stopped"):
        for pid in self.session.busy_worker_identities:
            write(self.directory / f"fixture/busy-{pid}.json", {
                "pid": pid, "role": "busy", "status": status, "bytesWritten": 1000,
                "durationSeconds": 2, "requestedBytesPerSecond": 2000,
                "readyMonotonicNs": 100, "stoppedMonotonicNs": 500})

    def test_primary_receipt_alone_does_not_end_cleanup_wait(self):
        alive = set(self.identities)
        def finish(_):
            self.publish_busy()
            alive.clear()
        with patch.object(bench, "process_identity", side_effect=lambda pid: self.identities[pid] if pid in alive else None), \
                patch.object(bench, "is_descendant", return_value=True), patch.object(bench.os, "kill") as kill, \
                patch.object(bench.time, "sleep", side_effect=finish) as sleep:
            result = bench.stop_fixtures(self.session)
        self.assertTrue(result["complete"])
        sleep.assert_called_once()
        self.assertEqual(kill.call_count, 4)
        self.assertTrue(all(item["stopped"] and item["originalProcessExited"] for item in result["finalRecords"].values()))

    def test_cleanup_deadline_retains_pending_busy_processes(self):
        with patch.object(bench, "process_identity", side_effect=lambda pid: self.identities[pid]), \
                patch.object(bench, "is_descendant", return_value=True), patch.object(bench.os, "kill"), \
                patch.object(bench.time, "monotonic", side_effect=[0, 0.2, 3.1]), patch.object(bench.time, "sleep"):
            result = bench.stop_fixtures(self.session)
        self.assertFalse(result["complete"])
        self.assertEqual(set(result["pendingPIDs"]), set(self.identities))
        self.assertTrue((self.directory / "fixture-stop.json").is_file())

    def test_cleanup_failure_cannot_mask_measurement_error(self):
        with patch.object(bench, "process_identity", side_effect=RuntimeError("ps failed")), \
                patch.object(bench, "atomic_json", side_effect=OSError("disk full")), patch.object(bench.os, "kill"):
            with self.assertRaisesRegex(ValueError, "original measurement"):
                try:
                    raise ValueError("original measurement")
                finally:
                    result = bench.stop_fixtures(self.session)
        self.assertFalse(result["complete"])
        self.assertTrue(any("disk full" in error for error in result["errors"]))

    def test_achieved_rate_uses_final_actual_bytes_and_duration_for_each_pane(self):
        self.publish_busy()
        summaries = bench.busy_load_summary(self.session, {"startedMonotonicNs": 200, "finishedMonotonicNs": 400})
        self.assertEqual(len(summaries), 3)
        self.assertTrue(all(item["achievedBytesPerSecond"] == 500 for item in summaries))
        self.assertTrue(all(item["requestedBytesPerSecond"] == 2000 for item in summaries))

    def test_zero_output_or_partial_lifetime_cannot_qualify_as_busy(self):
        self.publish_busy()
        path = self.directory / "fixture/busy-2001.json"
        original = json.loads(path.read_text())
        for change in ({"bytesWritten": 0}, {"durationSeconds": 0}, {"status": "running"},
                       {"stoppedMonotonicNs": 300}, {"readyMonotonicNs": 250}):
            write(path, {**original, **change})
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                bench.busy_load_summary(self.session, {"startedMonotonicNs": 200, "finishedMonotonicNs": 400})


if __name__ == "__main__":
    unittest.main()
