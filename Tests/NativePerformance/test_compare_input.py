"""A valid summary alone cannot admit interrupted native input process evidence."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import compare_input as comparison


class InputProcessAudit(unittest.TestCase):
    def fixture(self, root):
        def write(path, value):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
        write(root / 'summary.json', dict(valid=True, displayID=1))
        write(root / 'metadata.json', dict(requestedBlocks=6, samplesPerBlock=40, panes=1))
        for block in range(6):
            for index, terminal in enumerate(('cmdy', 'ghostty')):
                directory = root / f'{block:02d}-{terminal}'
                pid = 100 + block * 10 + index * 3
                write(directory / 'launch.json', dict(appPID=pid, workerPID=pid+1))
                status = dict(command=['owned-observer', '--pid', str(pid)], returncode=0, stdout='', stderr='')
                write(directory / 'observer-status.json', status)
                write(directory / 'observer-process.json', dict(status, pid=pid+2, reaped=True))
                write(directory / 'fixture-stop.json', dict(complete=True))
                write(directory / 'cleanup.json', dict(appPID=pid, returncode=-15))
                write(directory / 'fixture/received.json', list(range(40)))

    def test_unreaped_or_interrupted_event_generator_rejects_even_with_valid_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            case = dict(output=str(root), displayID=1)
            path = root / '00-cmdy/observer-process.json'
            original = json.loads(path.read_text())
            with patch.object(comparison.coordinator.bench, 'process_identity', return_value=None):
                self.assertEqual(comparison.audit_case(case)['measuredSamples'], 480)
                for change in (dict(reaped=False), dict(interrupted=True), dict(forcedKill=True),
                               dict(command=['another-observer'])):
                    path.write_text(json.dumps(dict(original, **change)))
                    with self.subTest(change=change), self.assertRaises(RuntimeError):
                        comparison.audit_case(case)

    def test_live_owned_process_or_wrong_display_rejects_complete_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            case = dict(output=str(root), displayID=1)
            with patch.object(comparison.coordinator.bench, 'process_identity', return_value='still running'), \
                    self.assertRaisesRegex(RuntimeError, 'still exists'):
                comparison.audit_case(case)
            with self.assertRaises(RuntimeError):
                comparison.audit_case(dict(case, displayID=2))


if __name__ == '__main__':
    unittest.main()
