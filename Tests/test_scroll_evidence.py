"""Pure tests of measured endpoint, raw guards, profile, and output ownership."""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from competitive_bench import BenchOptions
from scroll_bench import check_power, config_text, discrete_multiplier, main, normalized_config_hash
from scroll_parity_evidence import checked_stability, geometry, load_scroll_evidence, trial_order, tty
from scroll_protocol import viewport_sha256

TOKEN = "0123456789abcdef0123456789abcdef"


def synthetic():
    spec = {"appPID": 100, "workerPID": 101, "windowID": 5, "displayID": 1, "token": TOKEN, "ttyPath": "/dev/ttys999"}
    proof = {"appPID": 100, "windowID": 5, "displayID": 1, "frontmostPID": 100,
             "processStartSeconds": 1000, "processStartMicroseconds": 1,
             "x": 120, "y": 120, "width": 1000, "height": 750}
    report = {"clockBefore": {"absoluteTicks": 1}, "clockAfter": {"absoluteTicks": 1_000_000_000},
              "timebase": {"numer": 1, "denom": 1}, "windowBefore": proof}
    frames = [{"displayTicks": tick, "callbackTicks": tick - 100, "windowQueryFinishedTicks": tick + 200,
               "window": proof, "firstRow": 958, "checkedPixels": 27_216,
               "canonicalRowsSHA256": viewport_sha256(TOKEN, 958)}
              for tick in (10_000_000, 20_000_000, 270_000_000)]
    value = {"frames": frames, "stability": {"first": frames[0], "lastCorrectDisplayTicks": frames[-1]["displayTicks"],
        "laterCorrectDistinctFrames": 2, "validationFinishedTicks": 280_000_000}}
    return value, report, spec


class EvidenceTests(unittest.TestCase):
    def test_callback_before_display_keeps_the_original_endpoint(self):
        value, report, spec = synthetic()
        result = checked_stability(value, report, spec, 27_216, 958)
        self.assertEqual(result["displayTicks"], 10_000_000)
        self.assertLess(result["callbackTicks"], result["displayTicks"])

    def test_cannot_move_endpoint_past_an_earlier_correct_frame(self):
        value, report, spec = synthetic()
        value["stability"]["first"] = value["frames"][1]
        with self.assertRaisesRegex(ValueError, "endpoint moved"):
            checked_stability(value, report, spec, 27_216, 958)

    def test_post_match_wrong_viewport_rejects_even_if_it_returns(self):
        value, report, spec = synthetic()
        bad = deepcopy(value["frames"][1])
        bad["firstRow"] = 957; bad["canonicalRowsSHA256"] = viewport_sha256(TOKEN, 957)
        value["frames"][1] = bad
        with self.assertRaisesRegex(ValueError, "viewport changed"):
            checked_stability(value, report, spec, 27_216, 958)

    def test_callback_delivery_reordering_does_not_move_display_endpoint(self):
        value, report, spec = synthetic()
        value["frames"] = value["frames"][::-1]
        self.assertEqual(checked_stability(value, report, spec, 27_216, 958)["displayTicks"], 10_000_000)

    def test_rejects_one_missing_pixel_and_last_row_digest_change(self):
        for key, replacement in (("checkedPixels", 27_215), ("canonicalRowsSHA256", "a" * 64)):
            with self.subTest(key=key):
                value, report, spec = synthetic()
                value["frames"][2][key] = replacement
                with self.assertRaisesRegex(ValueError, "36-row"):
                    checked_stability(value, report, spec, 27_216, 958)

    def test_rejects_conflicting_duplicate_display_time(self):
        value, report, spec = synthetic()
        duplicate = deepcopy(value["frames"][0]); duplicate.update(firstRow=None, checkedPixels=0, canonicalRowsSHA256=None)
        value["frames"].append(duplicate)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            checked_stability(value, report, spec, 27_216, 958)

    def test_missing_two_distinct_later_frames_is_not_stability(self):
        value, report, spec = synthetic()
        value["frames"][1] = deepcopy(value["frames"][2])
        with self.assertRaisesRegex(ValueError, "distinct stable"):
            checked_stability(value, report, spec, 27_216, 958)

    def test_power_source_changes_and_missing_settings_reject(self):
        good = {"signature": {"source": "AC Power", "settings": "lowpowermode 0"}}
        self.assertEqual(check_power(good, "AC Power"), good["signature"])
        with self.assertRaises(ValueError):
            check_power(good, "Battery Power")
        with self.assertRaises(ValueError):
            check_power({"signature": {"source": "AC Power"}}, "AC Power")

    def test_default_profile_does_not_set_scroll_policy_and_matched_does(self):
        options = BenchOptions(Path("/app/cmdy"), Path("/app/ghostty"), profile="cmdy-defaults")
        for terminal, key in (("cmdy", "scroll-speed"), ("ghostty", "mouse-scroll-multiplier")):
            self.assertNotIn(key, config_text(terminal, options, Path("/generated/cwd")))
            matched = BenchOptions(options.cmdy_bin, options.ghostty_bin, profile="matched")
            self.assertIn(key, config_text(terminal, matched, Path("/generated/cwd")))
        self.assertEqual(discrete_multiplier(["precision:1,discrete:3"]), 3)
        self.assertEqual(discrete_multiplier(["1"]), 1)
        with self.assertRaises(ValueError):
            discrete_multiplier(["precision:1"])

    def test_existing_output_remains_byte_for_byte_untouched(self):
        with tempfile.TemporaryDirectory() as name:
            output = Path(name) / "existing"; output.mkdir()
            sentinel = output / "manifest.json"; sentinel.write_text("do not overwrite\n")
            paths = ["--cmdy-bin", "/missing/cmdy", "--ghostty-bin", "/missing/ghostty", "--observer", "/missing/observer",
                "--window-helper", "/missing/helper", "--cmdy-source-manifest", "/missing/manifest", "--cmdy-source-root", "/missing/root"]
            with self.assertRaises(FileExistsError):
                main(["--output", str(output), "--cmdy-sha256", "a" * 64, "--ghostty-sha256", "b" * 64, "--display-id", "1", *paths])
            self.assertEqual(sentinel.read_text(), "do not overwrite\n")
            self.assertEqual(list(output.iterdir()), [sentinel])

    def test_incomplete_and_calibration_only_cannot_enter_gate(self):
        for state, calibration in (("invalid", False), ("complete", True), ("running", False)):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                (root / "manifest.json").write_text(json.dumps({"schemaVersion": 1, "benchmarkKind": "scroll",
                    "state": state, "diagnostic": False, "calibrationOnly": calibration}))
                with self.assertRaisesRegex(ValueError, "incomplete/diagnostic"):
                    load_scroll_evidence(root)

    def test_raster_hash_and_vertical_gap_are_checked(self):
        value = {"width": 252, "height": 216,
                 "columnSamples": [[6 * col + n for n in (1, 2, 4)] for col in range(42)],
                 "rowBands": [{"lower": 6 * row, "upper": 6 * (row + 1)} for row in range(36)]}
        value["calibrationSHA256"] = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(geometry(value), 27_216)
        value["rowBands"][35]["lower"] += 1
        with self.assertRaisesRegex(ValueError, "gap"):
            geometry(value)

    def test_one_frame_with_lost_foreground_invalidates_the_sample(self):
        value, report, spec = synthetic()
        value["frames"][2]["window"] = {**value["frames"][2]["window"], "frontmostPID": 999}
        with self.assertRaisesRegex(ValueError, "owned PID"):
            checked_stability(value, report, spec, 27_216, 958)

    def test_next_event_cannot_overlap_previous_stability(self):
        def value(start, timestamp):
            return {"ttyBefore": {"startedTicks": start, "finishedTicks": start + 1},
                    "event": {"eventBeforeTicks": start + 2, "eventTimestamp": timestamp},
                    "stability": {"validationFinishedTicks": start + 10},
                    "ttyAfter": {"startedTicks": start + 11, "finishedTicks": start + 12}}
        initial = {"stability": {"validationFinishedTicks": 100}}
        report = {"clockAfter": {"absoluteTicks": 1000}}
        trial_order([value(101, 1), value(114, 2)], initial, report)
        with self.assertRaisesRegex(ValueError, "overlap"):
            trial_order([value(101, 1), value(112, 2)], initial, report)


if __name__ == "__main__":
    unittest.main()
