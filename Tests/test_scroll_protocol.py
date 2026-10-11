import dataclasses
import unittest

import scroll_protocol as protocol


TOKEN = "0123456789abcdef" * 2
HASH = "a" * 64


def calibration(terminal="cmdy", profile="matched", up=3, down=-3):
    return protocol.WheelCalibration(terminal, profile, up, down, 3, "line", False,
                                     HASH, HASH, HASH, HASH, "valid-unpooled-calibration")


class ScrollProtocolTests(unittest.TestCase):
    def test_each_row_binds_full_nonce_ordinal_and_checksum(self):
        first = protocol.row_symbols(TOKEN, 12)
        self.assertEqual(len(first), 42)
        self.assertEqual(first[0], -1)
        self.assertEqual(first[-1], -2)
        self.assertNotEqual(first, protocol.row_symbols(TOKEN, 13))
        self.assertNotEqual(first, protocol.row_symbols("f" + TOKEN[1:], 12))

    def test_non_generated_token_or_row_rejected(self):
        for token, row in [("name", 0), (TOKEN, -1), (TOKEN, 1000), (TOKEN, True)]:
            with self.assertRaises(ValueError):
                protocol.row_symbols(token, row)

    def test_payload_deterministic_and_primary_screen(self):
        payload = protocol.payload(TOKEN)
        self.assertEqual(payload, protocol.payload(TOKEN))
        self.assertEqual(payload.count(b"\r\n"), 999)
        self.assertIn(b"\x1b[?1049l", payload)
        self.assertNotIn(b"\x1b[?1049h", payload)
        self.assertIn(b"\x1b[3J\x1b[2J\x1b[H", payload)

    def test_viewport_digest_binds_every_generated_row(self):
        self.assertEqual(len(protocol.viewport_rows(958)), 36)
        self.assertNotEqual(protocol.viewport_sha256(TOKEN, 958),
                            protocol.viewport_sha256(TOKEN, 961))
        with self.assertRaises(ValueError):
            protocol.viewport_rows(965)

    def test_fixed_forty_samples_equal_work_and_no_boundary_clamps(self):
        plan = protocol.sample_plan()
        self.assertEqual(len(plan), 40)
        self.assertEqual([p["sequence"] for p in plan], list(range(40)))
        self.assertEqual(sum(p["direction"] < 0 for p in plan), 20)
        for index, sample in enumerate(plan):
            self.assertEqual(abs(sample["afterFirstRow"] - sample["beforeFirstRow"]), 3)
            self.assertEqual(len(sample["expectedRows"]), 36)
            self.assertTrue(0 < sample["afterFirstRow"] < 964)
            if index:
                self.assertEqual(sample["beforeFirstRow"], plan[index - 1]["afterFirstRow"])

    def test_profile_exceptions_do_not_override_defaults_scroll_policy(self):
        self.assertEqual(protocol.profile_overrides("cmdy", "matched"), ["scroll-speed = 1"])
        self.assertEqual(protocol.profile_overrides("ghostty", "matched"),
                         ["mouse-scroll-multiplier = discrete:1"])
        for app in ["cmdy", "ghostty"]:
            self.assertEqual(protocol.profile_overrides(app, "cmdy-defaults"), [])

    def test_matched_requires_identical_event_magnitudes(self):
        protocol.validate_paired_calibration(calibration(), calibration("ghostty"))
        with self.assertRaises(ValueError):
            protocol.validate_paired_calibration(calibration(), calibration("ghostty", up=2, down=-2))

    def test_defaults_can_normalize_one_event_to_same_three_row_work(self):
        protocol.validate_paired_calibration(
            calibration(profile="cmdy-defaults", up=2, down=-2),
            calibration("ghostty", profile="cmdy-defaults", up=1, down=-1))

    def test_calibration_cannot_hide_different_work_or_incomplete_evidence(self):
        for change in [dict(rows_per_event=2), dict(status="diagnostic"),
                       dict(upward_raw_delta=0), dict(upward_raw_delta=100),
                       dict(is_continuous=True), dict(binary_sha256=""),
                       dict(downward_raw_delta=3)]:
            with self.assertRaises(ValueError):
                dataclasses.replace(calibration(), **change).validate()

    def test_callback_can_precede_windowserver_event_timestamp(self):
        result = protocol.validate_frame_clock(100, 105, 110, 108, 112, 500, 125, 3)
        self.assertGreater(result["eventToCompleteViewportMS"], 0)
        self.assertLess(result["callbackMinusDisplayMS"], 0)

    def test_invalid_or_zero_duration_native_clock_rejected(self):
        for args in [(100, 105, 100, 108, 112, 500, 125, 3),
                     (100, 99, 110, 108, 112, 500, 125, 3),
                     (100, 105, 510, 108, 112, 500, 125, 3),
                     (100, 105, 110, 113, 112, 500, 125, 3),
                     (100, 105, 110, 108, 112, 500, 125, 0)]:
            with self.assertRaises(ValueError):
                protocol.validate_frame_clock(*args)

    def test_native_integer_ranges_are_required(self):
        valid = [100, 105, 110, 108, 112, 500, 125, 3]
        for index in range(len(valid)):
            limit = 2**64 if index < 6 else 2**32
            for replacement in (0, -1, True, 1.5, limit, limit * 10**400):
                with self.subTest(index=index, replacement_type=type(replacement).__name__):
                    changed = valid.copy()
                    changed[index] = replacement
                    with self.assertRaisesRegex(ValueError, "invalid native clock fields"):
                        protocol.validate_frame_clock(*changed)

    def test_near_uint64_maximum_keeps_small_signed_differences(self):
        start = 2**64 - 1000
        value = protocol.validate_frame_clock(start, start + 5, start + 10,
                                             start + 8, start + 12, start + 500, 125, 3)
        self.assertAlmostEqual(value["eventToCompleteViewportMS"], 10 * 125 / 3 / 1_000_000)
        self.assertAlmostEqual(value["callbackMinusDisplayMS"], -2 * 125 / 3 / 1_000_000)


if __name__ == "__main__":
    unittest.main()
