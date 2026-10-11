"""Untimed native setup must settle without fitting or hiding an invalid target."""
import unittest
from types import SimpleNamespace
from resize import wait_for_target

TARGET = dict(x=120, y=120, width=1142, height=849)
OTHER = dict(TARGET, width=1040)

class ResizeSetupTests(unittest.TestCase):
    def run_setup(self, bounds):
        now = [0.0]; seen = []
        def window():
            value = bounds(now[0]); seen.append(value)
            return dict(windows=[dict(bounds=value)])
        def pause(seconds): now[0] += seconds
        result = wait_for_target(SimpleNamespace(window=window), TARGET,
            clock=lambda: now[0], pause=pause)
        return result, seen

    def test_transient_target_does_not_satisfy_settling(self):
        result, seen = self.run_setup(lambda t: OTHER if t < .1 or .2 <= t < .4 else TARGET)
        self.assertGreaterEqual(result['observations'][-1]['elapsedSeconds'], .65)
        self.assertGreaterEqual(result['stableSeconds'], .25)
        self.assertEqual(result['resizeRequests'], 0)
        self.assertIn(OTHER, seen)

    def test_wrong_target_fails_without_correction(self):
        with self.assertRaisesRegex(RuntimeError, 'did not settle'):
            self.run_setup(lambda _: OTHER)

    def test_missing_window_fails_immediately(self):
        with self.assertRaisesRegex(RuntimeError, 'exactly one'):
            wait_for_target(SimpleNamespace(window=lambda: dict(windows=[])), TARGET)

if __name__ == '__main__': unittest.main()
