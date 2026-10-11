"""Generated-file tests; interpreter preflight must precede GUI and output writes."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import history_executable_identity as identity
import memory_bench


class InterpreterPinTests(unittest.TestCase):
    def test_native_image_is_pinned_and_a_same_content_launcher_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            native = root / 'native'
            native.write_bytes(b'generated-unexecuted-interpreter')
            launcher = root / 'launcher'
            launcher.write_bytes(native.read_bytes())
            with patch.object(identity.sys, 'executable', str(native)), \
                    patch.object(identity, '_running_executable', return_value=str(native)):
                self.assertEqual(identity.pin_current_interpreter(), dict(path=str(native.resolve()),
                    bytes=native.stat().st_size, sha256=hashlib.sha256(native.read_bytes()).hexdigest()))
            with patch.object(identity.sys, 'executable', str(launcher)), \
                    patch.object(identity, '_running_executable', return_value=str(native)):
                with self.assertRaisesRegex(RuntimeError, 'launcher differs'):
                    identity.pin_current_interpreter()

    def test_failure_happens_before_output_creation_or_any_native_app(self):
        with tempfile.TemporaryDirectory() as name:
            output = Path(name) / 'must-not-exist'
            args = ['--output', str(output), '--cmdy-bin', '/generated-cmdy',
                    '--ghostty-bin', '/generated-ghostty', '--window-helper', '/generated-window',
                    '--memory-helper', '/generated-memory', '--history-helper', '/generated-history',
                    '--post-sample-history']
            with patch.object(identity, 'pin_current_interpreter', side_effect=RuntimeError('launcher differs')), \
                    patch.object(memory_bench.subprocess, 'Popen', side_effect=AssertionError('no process launch')):
                with self.assertRaisesRegex(RuntimeError, 'launcher differs'):
                    memory_bench.main(args)
            self.assertFalse(output.exists())

    def test_native_identity_query_failure_is_not_silently_replaced_by_python_path(self):
        with patch.object(identity, '_running_executable', side_effect=RuntimeError('native query failed')):
            with self.assertRaisesRegex(RuntimeError, 'native query failed'):
                identity.pin_current_interpreter()


if __name__ == '__main__':
    unittest.main()
