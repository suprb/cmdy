"""Guard the main-actor ordering behind the native first-frame regression.

This source contract complements, never replaces, the real native pixel observer.
The native failure is a worker interleaving between adjacent main-actor calls.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ScrollOrderingTests(unittest.TestCase):
    def test_local_wheel_fences_old_publication_before_any_motion_control(self):
        source = (ROOT / 'App/CmdyTerminalSurface.swift').read_text()
        wheel = source[source.index('override func scrollWheel('):source.index('override func updateTrackingAreas(')]
        split = wheel.index('if event.hasPreciseScrollingDeltas, smoothScroll')
        fence = wheel.rfind('metalRenderer?.sourceDidChange()', 0, split)
        self.assertGreater(fence, wheel.index('if terminal.isAlternateBuffer'))
        self.assertLess(fence, wheel.index('applyPreciseLocalScroll(delta)'))
        self.assertLess(fence, wheel.index('metalRenderer?.setScrollHeld(0)'))
        self.assertLess(wheel.index('metalRenderer?.noteScroll('), wheel.index('installViewportUpdate(update)'))

    def test_both_synchronous_scroll_paths_reserve_publication_for_host_capture(self):
        source = (ROOT / 'App/TerminalModel.swift').read_text()
        start = source.index('func scrollViewport(to row: Int)')
        stop = source.index('private func viewportSnapshot(', start)
        self.assertEqual(source[start:stop].count('storeSynchronousSnapshot(&snapshot, publishRenderer: false)'), 2)


if __name__ == '__main__':
    unittest.main()
