"""Gate failure modes: no GUI, app launches or synthetic performance claims."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import parity_gate as gate


POLICY = {"maximumRatio": 1.0, "confidence": 0.95, "bootstrapResamples": 1000,
          "minimumPairedBlocks": 6, "minimumSamplesPerBlock": {"input": 40, "drain": 20},
          "scenarios": [{"id": "battery-matched", "powerSource": "Battery Power", "profile": "matched"}],
          "cases": [{"id": "drain/lines", "metrics": ["p50", "p95"], "grid": [120, 36]}]}
BINARIES = {"cmdy": "a" * 64, "ghostty": "b" * 64}
POWER = {"source": "Battery Power", "settings": "recorded settings"}
NATIVE = {"ok": True, "lowPowerMode": True, "thermalState": 0, "os": "test OS"}


def evidence(cmdy=None, ghostty=None):
    return {"path": "/evidence", "case": "drain/lines", "kind": "drain", "profile": "matched",
            "power": POWER, "binaries": BINARIES, "grid": [120, 36], "display": 1,
            "font": {"postScriptName": "Menlo-Regular", "sizePoints": 14},
            "fontSHA256": "c" * 64, "displays": [{"displayID": 1}], "hardware": "test hardware",
            "blocks": {block: {"cmdy": cmdy or [8.] * 20, "ghostty": ghostty or [10.] * 20}
                       for block in range(6)}}


class DecisionTests(unittest.TestCase):
    def test_absent_or_small_samples_cannot_pass(self):
        self.assertEqual(gate.assess_ratios([], POLICY)["status"], "insufficient-samples")
        self.assertEqual(gate.assess_ratios([0.5] * 5, POLICY)["status"], "insufficient-samples")
        report = gate.evaluate([], POLICY, BINARIES)
        self.assertFalse(report["passed"])
        self.assertTrue(all(item["status"] == "not-measured" for item in report["results"]))

    def test_behind_and_unresolved_are_distinct_from_a_pass(self):
        self.assertEqual(gate.assess_ratios([1.2] * 6, POLICY)["status"], "behind")
        self.assertEqual(gate.assess_ratios([0.8, 1.2] * 3, POLICY)["status"], "inconclusive")
        self.assertEqual(gate.assess_ratios([0.8] * 6, POLICY)["status"], "pass")
        for invalid in ([float("nan")] * 6, [0.] * 6, [float("inf")] * 6):
            with self.assertRaises(ValueError):
                gate.assess_ratios(invalid, POLICY)

    def test_nearest_rank_does_not_average_middle_samples(self):
        self.assertEqual(gate.percentile([2, 4], 0.5), 2)
        self.assertEqual(gate.percentile(list(range(1, 41)), 0.95), 38)

    def test_fast_median_cannot_hide_a_slow_tail(self):
        item = evidence(cmdy=[8.] * 18 + [20.] * 2)
        with patch.object(gate, "load_evidence", return_value=item):
            report = gate.evaluate([Path("/evidence")], POLICY, BINARIES)
        self.assertFalse(report["passed"])
        self.assertEqual([row["status"] for row in report["results"]], ["pass", "behind"])

    def test_missing_case_remains_red_even_when_existing_case_passes(self):
        policy = copy.deepcopy(POLICY)
        policy["cases"].append({"id": "resize", "metrics": ["p50", "p95"]})
        with patch.object(gate, "load_evidence", return_value=evidence()):
            report = gate.evaluate([Path("/evidence")], policy, BINARIES)
        self.assertFalse(report["passed"])
        self.assertEqual([row["status"] for row in report["results"]], ["pass", "pass", "not-measured", "not-measured"])

    def test_binary_pins_duplicate_evidence_and_invalid_artifacts_fail_closed(self):
        for paths, side_effect, pins in [
            ([Path("/one")], [evidence()], {**BINARIES, "cmdy": "d" * 64}),
            ([Path("/one"), Path("/two")], [evidence(), evidence()], BINARIES),
            ([Path("/one")], [ValueError("failed benchmark")], BINARIES),
        ]:
            with self.subTest(paths=paths, pins=pins), patch.object(gate, "load_evidence", side_effect=side_effect):
                report = gate.evaluate(paths, POLICY, pins)
                self.assertFalse(report["passed"])
                self.assertTrue(report["invalidEvidence"])

    def test_large_sample_count_does_not_replace_independent_blocks(self):
        item = evidence(cmdy=[1.] * 1000, ghostty=[10.] * 1000)
        item["blocks"] = {0: item["blocks"][0]}
        with patch.object(gate, "load_evidence", return_value=item):
            report = gate.evaluate([Path("/one")], POLICY, BINARIES)
        self.assertFalse(report["passed"])
        self.assertEqual(report["results"][0]["status"], "insufficient-samples")

    def test_same_font_file_at_different_sizes_cannot_share_a_scenario(self):
        policy = copy.deepcopy(POLICY)
        policy["cases"].append({"id": "drain/continuous", "metrics": ["p50"], "grid": [120, 36]})
        changed = {**evidence(), "case": "drain/continuous",
                   "font": {"postScriptName": "Menlo-Regular", "sizePoints": 12}}
        with patch.object(gate, "load_evidence", side_effect=[evidence(), changed]):
            report = gate.evaluate([Path("/one"), Path("/two")], policy, BINARIES)
        self.assertFalse(report["passed"])
        self.assertIn("font", report["invalidEvidence"][0]["reason"])

    def test_hidden_regression_tolerance_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "target"):
            gate.evaluate([], {**POLICY, "maximumRatio": 1.05}, BINARIES)

    def test_memory_adapter_uses_separate_cases_and_cannot_hide_an_rss_loss(self):
        policy = copy.deepcopy(POLICY)
        policy["minimumSamplesPerBlock"]["memory"] = 1
        policy["cases"] = [{"id": "memory/idle/" + metric, "metrics": ["bytes"], "grid": [120, 36]}
                           for metric in ("rss", "physical-footprint")]
        items = []
        for metric, cmdy in (("rss", 12.), ("physical-footprint", 8.)):
            items.append({**evidence(cmdy=[cmdy], ghostty=[10.]),
                          "kind": "memory", "metric": "bytes", "case": "memory/idle/" + metric})
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            put(directory / "manifest.json", {"benchmarkKind": "memory"})
            with patch("memory_parity_evidence.load_memory_evidence", return_value=items) as adapter:
                report = gate.evaluate([directory], policy, BINARIES)
                adapter.assert_called_once_with(directory, BINARIES)
        self.assertFalse(report["passed"])
        self.assertEqual(report["invalidEvidence"], [])
        self.assertEqual([row["status"] for row in report["results"]], ["behind", "pass"])

    def test_zero_memory_sampling_cannot_weaken_policy(self):
        policy = copy.deepcopy(POLICY)
        policy["minimumSamplesPerBlock"]["memory"] = 0
        with self.assertRaisesRegex(ValueError, "sampling"):
            gate.evaluate([], policy, BINARIES)

    def test_idle_cpu_zero_has_no_pseudocount_or_hidden_allowance(self):
        for values, status in (([0] * 6, "pass"), ([-1] * 6, "pass"),
                               ([1] * 6, "behind"), ([-1, 1] * 3, "inconclusive")):
            self.assertEqual(gate.assess_cpu_differences(values, POLICY)["status"], status)
        self.assertEqual(gate.assess_cpu_differences([0] * 5, POLICY)["status"], "insufficient-samples")
        with self.assertRaises(ValueError):
            gate.assess_cpu_differences([float("nan")] * 6, POLICY)

    def test_idle_cpu_requires_three_fresh_baselines_and_keeps_zero_comparator(self):
        policy = copy.deepcopy(POLICY)
        policy["minimumSamplesPerBlock"]["cpu"] = 3
        policy["cases"] = [{"id": "idle-cpu", "metrics": ["cpuTime"]}]
        item = {**evidence(), "case": "idle-cpu", "kind": "cpu", "metric": "cpuTime"}
        for cmdy, ghostty, status in (([0] * 3, [0] * 3, "pass"),
                                     ([1] * 3, [0] * 3, "behind"),
                                     ([0], [0], "insufficient-samples")):
            item["blocks"] = {block: {"cmdy": cmdy, "ghostty": ghostty} for block in range(6)}
            with patch.object(gate, "load_evidence", return_value=item):
                report = gate.evaluate([Path("/evidence")], policy, BINARIES)
            self.assertEqual(report["results"][0]["status"], status)
            self.assertNotIn("medianPairedRatio", report["results"][0])
        policy["minimumSamplesPerBlock"]["cpu"] = 1
        with self.assertRaisesRegex(ValueError, "sampling"):
            gate.evaluate([], policy, BINARIES)


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


def raw_drain(directory):
    """Minimal raw protocol transcript, structurally independent of summary."""
    (directory / "tooling").mkdir()
    (directory / "tooling/worker.py").write_text("fixture source\n")
    (directory / "payload.bin").write_bytes(b"A" * 78)
    metadata = {"schemaVersion": 2, "state": "complete", "metric": "raw-PTY-write-to-validated-DSR-response",
                "arguments": {"profile": "matched", "warmups": 1, "samples": 20, "blocks": 6},
                "targetGrid": {"columns": 120, "rows": 36},
                "binaries": {name: {"sha256": value} for name, value in BINARIES.items()},
                "harnessSHA256": {"worker.py": gate.digest(directory / "tooling/worker.py")},
                "fontSHA256": "c" * 64, "powerBefore": {"signature": POWER}, "powerAfter": {"signature": POWER},
                "nativeConditionsBefore": NATIVE, "nativeConditionsAfter": NATIVE,
                "hardware": {"stdout": "test hardware"},
                "workload": {"kind": "lines", "bytes": 78, "sha256": gate.digest(directory / "payload.bin")}}
    put(directory / "manifest.json", metadata)
    put(directory / "summary.json", {"status": "qualified", "metric": metadata["metric"], "inventedMedian": 0.001})
    put(directory / "display-font-permissions.json", {"font": {"postScriptName": "Menlo-Regular"}, "displays": [{"displayID": 1}]})
    grid = {"columns": 120, "rows": 36, "xpixel": 1000, "ypixel": 600}
    for block in range(6):
        for terminal in gate.TERMINALS:
            run = directory / f"runs/{block:02d}-{terminal}"
            config = run / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text("test config\n")
            first = (terminal == "cmdy") == (block % 2 == 0)
            put(run / "launch.json", {"terminal": terminal, "profile": "matched", "environment": {},
                                      "startedMonotonicNS": block * 10 + (0 if first else 1),
                                      "configSHA256": gate.digest(config)})
            put(run / "power.json", {"before": {"signature": POWER}, "after": {"signature": POWER}})
            put(run / "native-conditions.json", {"before": NATIVE, "after": NATIVE})
            put(run / "ready.json", {"payloadSHA256": metadata["workload"]["sha256"],
                                      "payloadBytes": 78, "ttyFlagsRaw": [0, 0, 0, 0, 0, 0]})
            window = {"ok": True, "pid": 123, "frontmostPID": 123,
                      "windows": [{"displayID": 1, "windowID": 42, "onScreen": True, "ownerPID": 123}]}
            put(run / "window-before.json", window)
            put(run / "window-after.json", window)
            for index in range(21):
                footer, reply = gate.expected_reply(36, 120, index)
                duration = 1_000_000_000 if index == 0 else (8_000_000 if terminal == "cmdy" else 10_000_000)
                put(run / f"sample-{index:02d}.json", {
                    "status": "valid", "ok": True, "block": block, "terminal": terminal, "index": index,
                    "sequence": index, "warmup": index == 0, "gridBefore": grid, "gridAfter": grid,
                    "footerHex": footer.hex(), "responseHex": reply.hex(), "expectedResponseHex": reply.hex(),
                    "payloadBytes": 78, "windowBefore": window, "windowAfter": window,
                    "startedMonotonicNS": 1_000_000, "finishedMonotonicNS": 1_000_000 + duration, "elapsedNS": duration})


class RawValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        raw_drain(self.directory)

    def tearDown(self):
        self.temporary.cleanup()

    def test_uses_raw_measured_samples_and_excludes_warmups(self):
        report = gate.evaluate([self.directory], POLICY, BINARIES)
        self.assertTrue(report["passed"])
        self.assertEqual(report["results"][0]["medianPairedRatio"], 0.8)

    def test_missing_sample_is_not_silently_dropped(self):
        (self.directory / "runs/00-cmdy/sample-01.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing/extra"):
            gate.load_evidence(self.directory)

    def test_corrupt_dsr_invalidates_complete_summary(self):
        path = self.directory / "runs/00-cmdy/sample-01.json"
        put(path, {**gate.read(path), "responseHex": "52"})
        with self.assertRaisesRegex(ValueError, "DSR"):
            gate.load_evidence(self.directory)

    def test_focus_loss_invalidates_complete_summary(self):
        path = self.directory / "runs/00-cmdy/sample-01.json"
        value = gate.read(path)
        value["windowAfter"]["frontmostPID"] = 999
        put(path, value)
        with self.assertRaisesRegex(ValueError, "frontmost"):
            gate.load_evidence(self.directory)

    def test_changed_power_and_trace_runs_are_rejected(self):
        path = self.directory / "runs/00-cmdy/power.json"
        value = gate.read(path)
        value["after"]["signature"]["source"] = "AC Power"
        put(path, value)
        with self.assertRaisesRegex(ValueError, "power changed"):
            gate.load_evidence(self.directory)
        metadata_path = self.directory / "manifest.json"
        put(metadata_path, {**gate.read(metadata_path), "diagnostic": True})
        with self.assertRaisesRegex(ValueError, "diagnostic"):
            gate.load_evidence(self.directory)

    def test_missing_or_changed_native_conditions_reject_drain_evidence(self):
        path = self.directory / "runs/00-cmdy/native-conditions.json"
        for change, message in (({"thermalState": 1}, "thermal"),
                                ({"lowPowerMode": False}, "conditions changed")):
            with self.subTest(change=change):
                put(path, {"before": NATIVE, "after": {**NATIVE, **change}})
                with self.assertRaisesRegex(ValueError, message):
                    gate.load_evidence(self.directory)
        path.unlink()
        report = gate.evaluate([self.directory], POLICY, BINARIES)
        self.assertFalse(report["passed"])
        self.assertTrue(report["invalidEvidence"])


def clock_report():
    return {"schemaVersion": 3, "clockSource": "mach_absolute_time", "timebase": {"numer": 125, "denom": 3},
            "samples": [{"sequence": 1, "postBeforeTicks": 1000, "postAfterTicks": 1010,
                         "validationFinishedTicks": 1140, "frame": {"displayTicks": 1120, "callbackTicks": 1100},
                         "eventToFrameMs": 0.005, "captureCallbackLagMs": -20 * 125 / 3 / 1_000_000}]}


class InputClockTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("CMDY_INPUT_CLOCK_SELFTEST"), "optional compiled observer clock transcript")
    def test_native_signed_clock_transcript_matches_python_recomputation(self):
        transcript = gate.read(Path(os.environ["CMDY_INPUT_CLOCK_SELFTEST"]))
        self.assertTrue(transcript["ok"])
        self.assertEqual(transcript["checks"], 14)
        durations = gate.input_frame_durations(transcript["syntheticClockReport"])
        self.assertEqual(durations, [0.005, 0.0075, 0.005, 200 * 125 / 3 / 1_000_000])

    def test_negative_offset_keeps_original_display_endpoint(self):
        report = clock_report()
        self.assertEqual(gate.input_frame_durations(report), [0.005])
        sample = report["samples"][0]
        self.assertLess(sample["frame"]["callbackTicks"], sample["frame"]["displayTicks"])
        for callback in (1120, 1130):
            sample["frame"]["callbackTicks"] = callback
            sample["captureCallbackLagMs"] = (callback - 1120) * 125 / 3 / 1_000_000
            self.assertEqual(gate.input_frame_durations(report), [0.005])

    def test_large_uint64_ticks_are_subtracted_before_float_conversion(self):
        report = clock_report()
        sample = report["samples"][0]
        shift = 0xffffffffffffffff - 3000
        for field in ("postBeforeTicks", "postAfterTicks", "validationFinishedTicks"):
            sample[field] += shift
        for field in ("displayTicks", "callbackTicks"):
            sample["frame"][field] += shift
        self.assertEqual(gate.input_frame_durations(report), [0.005])

    def test_invalid_timebase_and_legacy_reports_fail_closed(self):
        for field, value in (("schemaVersion", 2), ("clockSource", "wall-clock"),
                             ("timebase", {}), ("timebase", {"numer": 1, "denom": 0}),
                             ("timebase", {"numer": True, "denom": 3}),
                             ("timebase", {"numer": 2**32, "denom": 3})):
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "clock"):
                gate.input_frame_durations({**clock_report(), field: value})

    def test_malformed_clock_containers_report_validation_errors(self):
        for report in (None, [], {**clock_report(), "timebase": None},
                       {**clock_report(), "samples": [None]},
                       {**clock_report(), "samples": [{"sequence": 1, "frame": []}]}):
            with self.subTest(report=report), self.assertRaisesRegex(ValueError, "clock"):
                gate.input_frame_durations(report)

    def test_bad_timestamp_types_and_outside_validation_interval_are_rejected(self):
        for field, value in (("postBeforeTicks", 0), ("postBeforeTicks", True),
                             ("postAfterTicks", 999), ("postAfterTicks", 1141),
                             ("validationFinishedTicks", 1119), ("validationFinishedTicks", 2**64),
                             ("displayTicks", 1000), ("displayTicks", 1141),
                             ("callbackTicks", 999), ("callbackTicks", 1141), ("callbackTicks", 1100.0)):
            report = clock_report()
            sample = report["samples"][0]
            container = sample["frame"] if field in sample["frame"] else sample
            container[field] = value
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "clock"):
                gate.input_frame_durations(report)

    def test_forged_duration_or_callback_sign_cannot_qualify(self):
        for field, value in (("eventToFrameMs", 0.0001), ("eventToFrameMs", float("nan")),
                             ("captureCallbackLagMs", 0.0001), ("captureCallbackLagMs", float("inf"))):
            report = clock_report()
            report["samples"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "clock-derived"):
                gate.input_frame_durations(report)

    def test_overlapping_or_duplicate_key_samples_fail_closed(self):
        report = clock_report()
        report["samples"].append(copy.deepcopy(report["samples"][0]))
        with self.assertRaisesRegex(ValueError, "sequence"):
            gate.input_frame_durations(report)
        report["samples"][1]["sequence"] = 2
        with self.assertRaisesRegex(ValueError, "overlapping"):
            gate.input_frame_durations(report)


def raw_input(directory):
    """Synthetic raw transcript; its declared summaries deliberately lie."""
    raw_drain(directory)
    old = gate.read(directory / "manifest.json")
    metadata = {key: old[key] for key in ("binaries", "fontSHA256", "powerBefore", "hardware")}
    metadata.update(schemaVersion=2, markerMode="local-row", metric="synthetic-key-to-WindowServer-frame",
                    profile="matched", panes=1, samplesPerBlock=40, requestedBlocks=6,
                    requestedGrid=[120, 36], machine=gate.read(directory / "display-font-permissions.json"),
                    toolingSHA256=old["harnessSHA256"])
    (directory / "manifest.json").unlink()
    put(directory / "metadata.json", metadata)
    put(directory / "summary.json", {"valid": True, "metric": metadata["metric"], "inventedMedian": 0.001})
    grid = {"columns": 120, "rows": 36, "xpixel": 1000, "ypixel": 600}
    for original in (directory / "runs").iterdir():
        run = directory / original.name
        original.rename(run)
        launch = gate.read(run / "launch.json")
        put(run / "launch.json", {**launch, "appPID": 123})
        duration_ticks = 192_000 if launch["terminal"] == "cmdy" else 240_000
        report = {**clock_report(), "markerMode": "local-row", "pid": 123, "windowID": 42,
                  "environment": NATIVE, "samples": [], "summaryMs": {"median": 0.001, "p95": 0.001}}
        for sequence in range(1, 41):
            before = 1_000_000_000 + sequence * 5_000_000
            display = before + duration_ticks
            report["samples"].append({"sequence": sequence, "postBeforeTicks": before, "postAfterTicks": before + 100,
                "validationFinishedTicks": display + 100, "frame": {"displayTicks": display, "callbackTicks": display - 12},
                "eventToFrameMs": 8.0 if launch["terminal"] == "cmdy" else 10.0, "captureCallbackLagMs": -0.0005})
        put(run / "latency.json", report)
        put(run / "grid-before.json", grid)
        put(run / "grid-after.json", grid)
        put(run / "fixture-stop.json", {"complete": True})
        put(run / "fixture/received.json", [{"sequence": s, **grid} for s in range(1, 41)])


class RawInputClockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        raw_input(self.directory)
        self.policy = {**POLICY, "cases": [{"id": "input/local-row", "metrics": ["p50", "p95"], "grid": [120, 36]}]}

    def tearDown(self):
        self.temporary.cleanup()

    def test_raw_input_uses_ticks_and_accepts_signed_callback_offsets(self):
        result = gate.evaluate([self.directory], self.policy, BINARIES)
        self.assertTrue(result["passed"], result["invalidEvidence"])
        self.assertEqual([row["medianPairedRatio"] for row in result["results"]], [0.8, 0.8])

    def test_altered_duration_and_missing_clock_evidence_are_invalid_not_fast(self):
        path = self.directory / "00-cmdy/latency.json"
        original = gate.read(path)
        for change in ("schema", "timebase", "duration", "callback-sign", "validation"):
            report = copy.deepcopy(original)
            if change == "schema":
                report["schemaVersion"] = 2
            elif change == "timebase":
                del report["timebase"]
            elif change == "duration":
                report["samples"][0]["eventToFrameMs"] = 0.001
            elif change == "callback-sign":
                report["samples"][0]["captureCallbackLagMs"] *= -1
            else:
                del report["samples"][0]["validationFinishedTicks"]
            put(path, report)
            with self.subTest(change=change):
                result = gate.evaluate([self.directory], self.policy, BINARIES)
                self.assertFalse(result["passed"])
                self.assertTrue(result["invalidEvidence"])


if __name__ == "__main__":
    unittest.main()
