"""Untimed layout control tests; no native input or performance samples."""
import unittest
from unittest.mock import patch
from four_pane_bench import Layout


class DividerModel(Layout):
    def __init__(self, sign=1, cell_points=20, movable=True):
        self.offset = 0
        self.sign = sign
        self.cell_points = cell_points
        self.movable = movable
        self.actions = []
        self.records = []

    def focus_slot(self, slot):
        self.focus = slot

    def states(self):
        shift = self.offset // self.cell_points
        return {0: {"grid": {"columns": 60, "rows": 17 + shift}},
                2: {"grid": {"columns": 60, "rows": 19 - shift}}}

    def key(self, action):
        self.actions.append(action)
        if self.movable:
            self.offset += self.sign * (10 if action == "resize-up" else -10)

    def record(self, value):
        self.records.append(value)


class GridBalanceTests(unittest.TestCase):
    @patch("four_pane_bench.time.sleep")
    def test_public_actions_balance_cells_for_either_direction_and_quantization(self, _):
        for sign in (1, -1):
            for cell_points in (20, 40):
                with self.subTest(sign=sign, cell_points=cell_points):
                    layout = DividerModel(sign=sign, cell_points=cell_points)
                    layout.balance_pair(0, 2, "rows", "resize-up", "resize-down")
                    self.assertEqual([v["grid"]["rows"] for v in layout.states().values()], [18, 18])
                    self.assertEqual(layout.focus, 0)
                    self.assertLessEqual(len(layout.actions), 12)

    @patch("four_pane_bench.time.sleep")
    def test_nonmoving_divider_fails_with_a_bounded_action_count(self, _):
        layout = DividerModel(movable=False)
        with self.assertRaisesRegex(RuntimeError, "could not balance"):
            layout.balance_pair(0, 2, "rows", "resize-up", "resize-down")
        self.assertEqual(len(layout.actions), 24)

    @patch("four_pane_bench.time.sleep")
    def test_equal_grids_do_not_receive_divider_actions(self, _):
        layout = DividerModel()
        layout.offset = 20
        layout.balance_pair(0, 2, "rows", "resize-up", "resize-down")
        self.assertEqual(layout.actions, [])


if __name__ == "__main__":
    unittest.main()
