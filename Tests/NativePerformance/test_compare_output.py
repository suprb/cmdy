"""Headless checks for the native coordinator's human-input and source guards."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import compare_output as compare


class ComparisonGuards(unittest.TestCase):
    def test_complete_block_survives_next_child_failure_without_admission(self):
        self.checkpoint_scenario(input_before_checkpoint=False)

    def test_input_before_checkpoint_prevents_the_commit(self):
        self.checkpoint_scenario(input_before_checkpoint=True)

    def checkpoint_scenario(self, input_before_checkpoint):
        from types import SimpleNamespace
        def sample(idle=400):
            return dict(clock=compare.ACTIVITY_CLOCK, readStartedMonotonicNS=1_000_000_000_000,
                        sessionReadFinishedMonotonicNS=1_000_000_000_000,
                        readFinishedMonotonicNS=1_000_000_000_000,
                        idleSeconds=idle, hardwareIdleSeconds=idle)
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve()
            compare.write_new(root / 'plan.json', dict(output=str(root), helper='unused', displayID=1,
                minimumHumanIdleSeconds=300, maximumCaseSeconds=1800, collectionOnly=True,
                performanceAdmission=False, cases=[dict(workload=f'block-{i}', command=['generated']) for i in range(2)]))
            first, second = Mock(), Mock()
            first.pid = 100; first.poll.return_value = 0; first.wait.return_value = 0
            second.pid = 101; second.poll.return_value = 1; second.wait.return_value = 1
            checkpoint = Mock(return_value='a' * 64)
            finalizer = Mock()
            samples = [sample(), sample(), sample(0) if input_before_checkpoint else sample(), sample(), sample()]
            with patch.object(compare, 'verify_inputs'), patch.object(compare, 'check_environment', return_value={}), \
                 patch.object(compare.bench, 'window_command', return_value=dict(accessibilityTrusted=True,
                     displays=[dict(displayID=1)], frontmostPID=123)), \
                 patch.object(compare, 'activity_sample', side_effect=samples), \
                 patch.object(compare.subprocess, 'Popen', side_effect=[first, second]), \
                 patch.object(compare.signal, 'signal'), patch.object(compare.bench, 'restore_frontmost'), \
                 self.assertRaises(RuntimeError):
                compare.run(SimpleNamespace(output=root), audit=lambda _:dict(measuredSamples=36, warmups=0),
                            checkpoint=checkpoint, collection_finalizer=finalizer)
            finalizer.assert_not_called()
            if input_before_checkpoint:
                checkpoint.assert_not_called()
            else:
                checkpoint.assert_called_once()
                self.assertIn('after', checkpoint.call_args.args[3])
                self.assertEqual(compare.read(root / 'execution.json')['cases'][0]['checkpointSHA256'], 'a' * 64)
            self.assertFalse((root / 'parity-gate.json').exists())

    def test_hardware_idle_clock_is_unique_nonnegative_integer(self):
        record = [{'IORegistryEntryChildren': [{'HIDIdleTime': 400_000_000_000}]}]
        self.assertEqual(compare.parse_idle(plistlib.dumps(record)), 400)
        for value in ([], [{'HIDIdleTime': -1}], [{'HIDIdleTime': 1.5}],
                      [{'HIDIdleTime': True}], [{'HIDIdleTime': 1}, {'HIDIdleTime': 2}]):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                compare.parse_idle(plistlib.dumps(value))

    def test_human_input_resumption_aborts_instead_of_restoring_over_it(self):
        self.assertFalse(compare.human_returned(400, 20, 420))
        self.assertFalse(compare.human_returned(400, 20, 419.9))
        self.assertTrue(compare.human_returned(400, 20, 0))
        self.assertTrue(compare.human_returned(400, 20, 19))

    def test_initial_launch_requires_both_clocks_to_be_quiet(self):
        compare.require_initial_quiet({'idleSeconds': 300, 'hardwareIdleSeconds': 300}, 300)
        for session, hardware in ((299, 400), (400, 299), (400, float('nan'))):
            with self.subTest(session=session, hardware=hardware), self.assertRaises(RuntimeError):
                compare.require_initial_quiet({'idleSeconds': session, 'hardwareIdleSeconds': hardware}, 300)

    def test_self_only_generated_keys_do_not_look_like_session_input(self):
        # Windowless self-probe 02 receipt SHA256:
        # 866ddd3327335e99c588fce71d3f1207ff1d2f8e48c10962dcc8b0c97a8c9771
        elapsed = (411199693879708 - 411198907521125) / 1e9
        self.assertFalse(compare.human_returned(16.312323833, elapsed, 17.098856083))
        self.assertTrue(compare.human_returned(16.529795166, elapsed, 0.770001458))
        # A reset in the session stream still stops the run.
        self.assertTrue(compare.human_returned(16.312323833, elapsed, 0.770001458))

    def test_invalid_session_clock_cannot_silently_report_quiet(self):
        for value in (float('inf'), float('nan'), -1.0, True, '400'):
            with self.subTest(value=value), patch.object(compare, '_event_source', return_value=value), \
                 self.assertRaisesRegex(RuntimeError, 'invalid session input clock'):
                compare.idle_seconds()
        with patch.object(compare, '_event_source', return_value=1000.0), \
             patch.object(compare.time, 'monotonic', return_value=100), \
             self.assertRaisesRegex(RuntimeError, 'exceeds system uptime'):
            compare.idle_seconds()
        for position in range(3):
            args = [400, 20, 420]; args[position] = float('nan')
            with self.subTest(position=position), self.assertRaises(RuntimeError):
                compare.human_returned(*args)

    def test_session_read_is_separate_from_slow_hardware_query(self):
        with patch.object(compare, 'idle_seconds', return_value=420), \
             patch.object(compare, 'hardware_idle_seconds', return_value=1), \
             patch.object(compare.time, 'monotonic_ns', side_effect=[1_016_000_000_000,
                 1_019_999_000_000, 1_020_000_000_000, 1_020_001_000_000]):
            sample = compare.activity_sample()
        self.assertEqual(sample['sessionReadFinishedMonotonicNS'], 1_020_001_000_000)
        self.assertEqual(sample['hardwareIdleSeconds'], 1)
        elapsed = sample['readStartedMonotonicNS'] / 1e9 - 1000
        self.assertFalse(compare.human_returned(400, elapsed, sample['idleSeconds']))

    def test_clock_error_can_reap_an_unresponsive_owned_controller(self):
        process = Mock()
        process.wait.side_effect = [subprocess.TimeoutExpired('owned controller', 20), -9]
        receipt = {}
        compare.stop_controller(process, receipt)
        process.terminate.assert_called_once(); process.kill.assert_called_once()
        self.assertEqual(receipt, {'controllerForcedKill': True, 'exitCode': -9, 'controllerReaped': True})

    def test_final_activity_or_unavailable_clock_cannot_restore_or_complete(self):
        from types import SimpleNamespace
        def sample(idle):
            return {'clock': compare.ACTIVITY_CLOCK, 'readStartedMonotonicNS': 1_000_000_000_000,
                    'sessionReadFinishedMonotonicNS': 1_000_000_000_000,
                    'readFinishedMonotonicNS': 1_000_000_000_000,
                    'idleSeconds': idle, 'hardwareIdleSeconds': idle}
        for final in (sample(0), RuntimeError('clock unavailable')):
            with self.subTest(final=final), tempfile.TemporaryDirectory() as name:
                root = Path(name).resolve()
                compare.write_new(root / 'plan.json', {'output': str(root), 'helper': 'unused',
                    'displayID': 1, 'minimumHumanIdleSeconds': 300, 'cases': []})
                with patch.object(compare, 'verify_inputs'), \
                     patch.object(compare.bench, 'window_command', return_value={'accessibilityTrusted': True,
                         'displays': [{'displayID': 1}], 'frontmostPID': 123}), \
                     patch.object(compare, 'activity_sample', side_effect=[sample(400), final]), \
                     patch.object(compare, 'finish_results'), \
                     patch.object(compare.signal, 'signal'), \
                     patch.object(compare.bench, 'restore_frontmost') as restore, \
                     self.assertRaises(RuntimeError):
                    compare.run(SimpleNamespace(output=root))
                restore.assert_not_called()
                record = compare.read(root / 'execution.json')
                self.assertEqual(record['status'], 'stopped-with-retained-evidence')
                self.assertIn('foregroundRestoreSkippedReason', record)

    def test_changed_frozen_input_is_rejected_before_runtime_queries(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            tool = root / 'tool.py'; tool.write_text('original')
            plan = {'pins': {'tool.py': compare.sha(tool)}}
            path = root / 'plan.json'; path.write_text(json.dumps(plan))
            pin = compare.sha(path)
            tool.write_text('changed')
            with patch.object(compare.bench, 'binary_metadata') as binary, \
                 patch.object(compare.candidate_preparation, 'verify') as candidate, \
                 self.assertRaisesRegex(RuntimeError, 'frozen comparison tool changed'):
                compare.verify_inputs(root, plan, pin, full_candidate=True)
            binary.assert_not_called(); candidate.assert_not_called()

    def test_existing_receipts_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / 'receipt.json'
            compare.write_new(path, {'original': True})
            before = path.read_bytes()
            with self.assertRaises(FileExistsError):
                compare.write_new(path, {'replacement': True})
            self.assertEqual(path.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
