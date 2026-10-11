"""Pure generated protocol tests. No native app or screen capture."""
import unittest
from resize_protocol import (ArmState, FIXTURE_VERSION, GRIDS, HISTORY_BYTES,
                             cell_classes_bytes, decode_word, digest, frame_bytes,
                             growth_guard_enabled, history, row_colors, row_classes, row_word, sequence_plan)


class ResizeProtocolTests(unittest.TestCase):
    nonce = "0123456789abcdef0123456789abcdef"

    def test_history_exact_logical_lines_and_repeated_generation(self):
        value = history(self.nonce)
        self.assertEqual(len(value), HISTORY_BYTES)
        self.assertEqual(value, history(self.nonce))
        rows = value.split(b"\r\n")
        self.assertEqual(rows[-1], b"")
        self.assertEqual(len(rows), 1001)
        self.assertTrue(all(len(row) == 145 for row in rows[:-1]))
        self.assertEqual(len(set(rows[:-1])), 1000)

    def test_every_row_decodes_exact_context(self):
        for columns, rows in GRIDS:
            for row in range(rows):
                word = row_word(self.nonce, 0x10203, columns, rows, row)
                self.assertEqual(decode_word(word), dict(nonce=self.nonce, sequence=0x10203,
                    columns=columns, rows=rows, row=row))
                self.assertEqual(len(row_colors(self.nonce, 0x10203, columns, rows, row)), columns)

    def test_changed_field_rejected_without_new_checksum(self):
        word = row_word(self.nonce, 1, 120, 36, 0)
        for index in range(len(word)):
            changed = word[:index] + ("1" if word[index] != "1" else "2") + word[index + 1:]
            with self.assertRaises(ValueError):
                decode_word(changed)

    def test_v2_full_width_bytes_and_frozen_vectors(self):
        self.assertEqual(FIXTURE_VERSION, 2)
        vectors = {
            (120, 36): (92600, "7851928e7ca172a7702ec6238a96e99a68c90e84122c7a3edd3cd2f353818058",
                        "23ea93c007fde02303ff01ad3c9173a797a09943c71625f8cb1e2c7c02a3e67f"),
            (132, 40): (112968, "b6826b3b740fae2b4cac61dd57fb1d33fd10c334daffbca6e08e41d254838082",
                        "2c898c5071e5001f966cad45c25cca3a1da71c6c7d9ebb17f162564348597d64"),
        }
        for (columns, rows), (size, payload_hash, cell_hash) in vectors.items():
            payload = frame_bytes(self.nonce, 1, columns, rows)
            classes = cell_classes_bytes(self.nonce, 1, columns, rows)
            self.assertEqual((len(payload), digest(payload)), (size, payload_hash))
            self.assertEqual((len(classes), digest(classes)), (columns * rows, cell_hash))
            for sequence in (0, 1, 0xffffffff):
                self.assertEqual(len(frame_bytes(self.nonce, sequence, columns, rows)), size)
                for row in range(rows):
                    generated = row_classes(self.nonce, sequence, columns, rows, row)
                    self.assertEqual(len(generated), columns)
                    self.assertEqual((generated[0], generated[-1]), (16, 17))
                    self.assertTrue(all(0 <= digit < 16 for digit in generated[1:-1]))

    def test_growth_guard_is_exact_prefix_only_for_large_repaint(self):
        for grid in GRIDS:
            original = frame_bytes(self.nonce, 1, *grid)
            guarded = frame_bytes(self.nonce, 1, *grid, history_growth_guard=True)
            expected = (original if grid == GRIDS[0] else
                        original.replace(b"\x1b[2J", b"\x1b[40;1H" + b"\r\n" * 4 + b"\x1b[2J", 1))
            self.assertEqual(guarded, expected)
            self.assertEqual(len(guarded) - len(original), 0 if grid == GRIDS[0] else 15)
            for forbidden in (b"\x1b[3J", b"1049", b"2026", b"6n"):
                self.assertNotIn(forbidden, guarded)

    def test_growth_guard_cannot_select_arbitrary_workload_or_boolean_row_count(self):
        self.assertFalse(growth_guard_enabled({}))
        self.assertTrue(growth_guard_enabled(dict(historyGrowthGuardRows=4)))
        for value in (True, False, -1, 1, 5, 4.0, "4", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                growth_guard_enabled(dict(historyGrowthGuardRows=value))
        for value in (0, 1, None, "true"):
            with self.assertRaises(ValueError): frame_bytes(self.nonce, 1, 132, 40, history_growth_guard=value)

    def test_no_alternate_history_clear_or_dsr_in_repaint(self):
        for dimensions in GRIDS:
            payload = frame_bytes(self.nonce, 10, *dimensions)
            for forbidden in (b"\x1b[3J", b"\x1b[?1049", b"\x1b[6n", b"\x1b[?2026"):
                self.assertNotIn(forbidden, payload)
            self.assertEqual(payload.count(b"\x1b[48;2;242;036;036m "), dimensions[1])
            self.assertLess(payload.rfind(b"\x1b[38;2;180;180;180m"),
                            payload.find(b"\x1b[48;2;242;036;036m "))

    def test_arm_does_not_authorize_without_new_matching_signal(self):
        state = ArmState()
        state.arm(1, GRIDS[1], GRIDS[0], 12)
        self.assertIsNone(state.resize(12, GRIDS[1]))
        self.assertIsNone(state.resize(13, GRIDS[0]))
        self.assertIsNotNone(state.resize(14, GRIDS[1]))
        self.assertIsNone(state.resize(15, GRIDS[1]))
        self.assertEqual(state.completed, 1)

    def test_rearm_cannot_duplicate_or_change_same_grid(self):
        state = ArmState()
        state.arm(1, GRIDS[1], GRIDS[0], 0)
        with self.assertRaises(ValueError):
            state.arm(2, GRIDS[1], GRIDS[0], 0)
        state.resize(1, GRIDS[1])
        with self.assertRaises(ValueError):
            state.arm(1, GRIDS[0], GRIDS[1], 1)
        with self.assertRaises(ValueError):
            state.arm(2, GRIDS[1], GRIDS[1], 1)

    def test_preregistered_warmups_cycle_and_unique_sequences(self):
        all_sequences = []
        for block in range(6):
            plan = sequence_plan(block)
            self.assertEqual(len(plan), 42)
            self.assertEqual(sum(not item["warmup"] for item in plan), 40)
            self.assertEqual([item["warmup"] for item in plan], [True] * 2 + [False] * 40)
            self.assertEqual([(item["columns"], item["rows"]) for item in plan], list(reversed(GRIDS)) * 21)
            all_sequences.extend(item["sequence"] for item in plan)
        self.assertEqual(len(set(all_sequences)), 252)


if __name__ == "__main__":
    unittest.main()
