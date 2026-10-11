"""Setup diagnostic retention with mocked native calls; never opens a window."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

import competitive_bench as bench


class WindowPositionEvidenceTests(unittest.TestCase):
    def test_success_retains_ax_polling_and_original_window_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            state = {"windows": [{"bounds": {"width": 860, "height": 540}}]}
            session = SimpleNamespace(directory=directory, app_pid=123, helper=Path("/helper"),
                                      window=Mock(return_value=state))
            response = {"ok": True, "resizeReadiness": {"status": "ready", "polls": [
                {"axCount": None}, {"axCount": 0}, {"axCount": 1}]}}
            with patch.object(bench, "window_command", return_value=response) as command, \
                    patch.object(bench.time, "sleep"):
                self.assertEqual(bench.TerminalSession.place_window(session, 120, 120), state)
            command.assert_called_once_with(Path("/helper"), "resize", 123, 860, 540, 120, 120)
            self.assertEqual(json.loads((directory / "window-position.json").read_text()), state)
            evidence = json.loads((directory / "window-position-resize.json").read_text())
            self.assertEqual(evidence["resizeResponse"], response)
            self.assertEqual(evidence["status"], "valid")
            self.assertEqual(session.window.call_args_list, [(), ()])

    def test_failure_retains_polls_and_does_not_retry_or_activate(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            session = SimpleNamespace(directory=directory, app_pid=123, helper=Path("/helper"),
                window=Mock(return_value={"windows": [{"bounds": {"width": 860, "height": 540}}]}))
            failure = bench.WindowHelperError("focus changed", {"returncode": 2, "response": {
                "ok": False, "resizeReadiness": {"status": "failed", "polls": [{"frontmostPID": 456}]}}})
            with patch.object(bench, "window_command", side_effect=failure) as command, \
                    patch.object(bench.time, "sleep") as sleep:
                with self.assertRaises(bench.WindowHelperError) as caught:
                    bench.TerminalSession.place_window(session, 120, 120)
            self.assertIs(caught.exception, failure)
            command.assert_called_once()
            sleep.assert_not_called()
            session.window.assert_called_once_with()
            self.assertFalse((directory / "window-position.json").exists())
            evidence = json.loads((directory / "window-position-resize.json").read_text())
            self.assertEqual(evidence["helperFailure"], failure.evidence)
            self.assertEqual(evidence["status"], "failed")


if __name__ == "__main__":
    unittest.main()
