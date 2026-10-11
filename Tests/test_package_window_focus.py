import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from CMDYFinishing.package_window_focus import activate_owned_window


class PackageWindowFocusTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.helper = self.root / 'helper'
        self.helper.write_bytes(b'known helper')
        self.binary = self.root / 'cmdy'
        self.output = self.root / 'receipt.json'
        self.process = SimpleNamespace(pid=123, poll=Mock(return_value=None))

    def response(self, **changes):
        state = dict(ok=True, pid=123, executable=str(self.binary), frontmostPID=123,
                     windows=[dict(ownerPID=123, onScreen=True)])
        state.update(changes)
        return SimpleNamespace(returncode=0, stdout=json.dumps(state), stderr='')

    def invoke(self, **kwargs):
        return activate_owned_window(self.process, self.helper, self.binary, self.output, **kwargs)

    def test_waits_for_owned_window_then_activates_once(self):
        missing = SimpleNamespace(returncode=1, stdout='{"ok":false}', stderr='')
        with patch('CMDYFinishing.package_window_focus.subprocess.run', side_effect=[missing, self.response(), self.response()]) as run:
            with patch('CMDYFinishing.package_window_focus.time.sleep'):
                result = self.invoke()
        self.assertEqual([call.args[0][1] for call in run.call_args_list], ['inspect', 'inspect', 'activate'])
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['activationActions'], 1)
        self.assertEqual(result['inputEventsPosted'], 0)
        self.assertFalse(result['clipboardAccessed'])
        self.assertEqual(json.loads(self.output.read_text()), result)

    def test_rejects_different_executable_before_activation(self):
        with patch('CMDYFinishing.package_window_focus.subprocess.run', return_value=self.response(executable='/unrelated/app')) as run:
            with self.assertRaisesRegex(RuntimeError, 'identity differs'):
                self.invoke()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(json.loads(self.output.read_text())['activationActions'], 0)

    def test_rejects_different_pid_before_activation(self):
        with patch('CMDYFinishing.package_window_focus.subprocess.run', return_value=self.response(pid=456)) as run:
            with self.assertRaisesRegex(RuntimeError, 'identity differs'):
                self.invoke()
        self.assertEqual(run.call_count, 1)

    def test_does_not_activate_after_owned_process_exits(self):
        self.process.poll.side_effect = [None, 0]
        with patch('CMDYFinishing.package_window_focus.subprocess.run', return_value=self.response()) as run:
            with self.assertRaisesRegex(RuntimeError, 'exited before activation'):
                self.invoke()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(json.loads(self.output.read_text())['activationActions'], 0)

    def test_wrong_foreground_fails_without_repeated_activation(self):
        with patch('CMDYFinishing.package_window_focus.subprocess.run', side_effect=[self.response(), self.response(frontmostPID=456)]) as run:
            with self.assertRaisesRegex(RuntimeError, 'did not activate'):
                self.invoke()
        self.assertEqual(run.call_count, 2)
        self.assertEqual(json.loads(self.output.read_text())['activationActions'], 1)

    def test_timeout_never_activates_an_unobserved_window(self):
        with patch('CMDYFinishing.package_window_focus.subprocess.run') as run:
            with self.assertRaisesRegex(RuntimeError, 'did not appear'):
                self.invoke(timeout=0)
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
