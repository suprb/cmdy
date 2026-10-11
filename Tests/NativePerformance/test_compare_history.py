"""Generated files and mocked lifetimes only; no app, native query or key event."""
from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import compare_history as pilot
import compare_output as coordinator
from history_export_binding import cmdy_store_bytes, install_binding, validate_binding, shortcut_event
from test_history_export import transfer_fixture, NONCE
from test_history_scope import file_transfer_fixture


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


class FinalizerTests(unittest.TestCase):
    def test_default_still_invokes_exact_timing_gate_and_checks_coverage(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            plan = dict(cases=[dict(output='case-one')], binaries={name: dict(sha256=name + '-pin')
                                                                  for name in ('cmdy', 'ghostty')})
            result = dict(invalidEvidence=[], passed=False,
                          results=[dict(status='not-measured')] * 130 + [dict(status='pass')] * 10)
            record = {}
            def gate(command, **kwargs):
                self.assertEqual(command[-2:], ['--output', str(root / 'parity-gate.json')])
                self.assertIn('case-one', command)
                self.assertIn('cmdy-pin', command); self.assertIn('ghostty-pin', command)
                save(root / 'parity-gate.json', result)
                return SimpleNamespace(returncode=1, stdout='retained gate output', stderr='')
            with patch.object(coordinator.subprocess, 'run', side_effect=gate) as invoked:
                coordinator.finish_results(root, plan, record, 10, 'complete-native-output-evidence')
            invoked.assert_called_once()
            self.assertEqual(record['status'], 'complete-native-output-evidence')
            self.assertEqual(record['gateCounts'], {'not-measured': 130, 'pass': 10})
            self.assertFalse(record['goalMet'])

    def test_untimed_result_never_invokes_gate_or_claims_admission(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); record = {}
            plan = dict(measuredSamples=0, warmups=0, performanceAdmission=False)
            result = dict(status='paired-generated-file-transfer-pass', measuredSamples=0,
                          performanceAdmission=False, qualifying=False, goalMet=False)
            with patch.object(coordinator.subprocess, 'run') as native:
                coordinator.finish_results(root, plan, record, 140, 'ignored', lambda *_: result)
            native.assert_not_called()
            self.assertEqual(record['status'], 'complete-untimed-functional-pilot')
            self.assertNotIn('gateCounts', record)
            self.assertFalse(record['goalMet']); self.assertFalse(record['performanceAdmission'])
            self.assertFalse((root / 'parity-gate.json').exists())

    def test_untimed_finalizer_rejects_measurements_and_admission_flags(self):
        result = dict(measuredSamples=0, performanceAdmission=False, qualifying=False, goalMet=False)
        plan = dict(measuredSamples=0, warmups=0, performanceAdmission=False)
        for change in (dict(goalMet=True), dict(qualifying=True), dict(performanceAdmission=True),
                       dict(measuredSamples=1), dict(measuredSamples=False), dict(gateCounts={}),
                       dict(parityGateSHA256='fabricated')):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                with self.assertRaisesRegex(RuntimeError, 'cannot claim performance admission'):
                    coordinator.finish_untimed(root, plan, {}, lambda *_: dict(result, **change))
                self.assertFalse((root / 'untimed-result.json').exists())
        for change in (dict(measuredSamples=1), dict(warmups=1), dict(performanceAdmission=True)):
            with tempfile.TemporaryDirectory() as name, self.assertRaises(RuntimeError):
                coordinator.finish_untimed(Path(name), dict(plan, **change), {}, lambda *_: result)


class PilotPreparationTests(unittest.TestCase):
    def test_both_idle_clocks_are_required_before_any_owned_launch(self):
        for session_idle, hardware_idle in ((400, 0), (0, 400), (400, 400)):
            with self.subTest(session=session_idle, hardware=hardware_idle), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                save(root / 'execution.json', dict(status='running', pid=os.getppid()))
                sample = dict(idleSeconds=session_idle, hardwareIdleSeconds=hardware_idle,
                              sessionReadFinishedMonotonicNS=1_000_000_000_000)
                with patch.object(pilot, 'check_plan', return_value={}), \
                        patch.object(coordinator, 'activity_sample', return_value=sample) as sampled, \
                        patch.object(coordinator, 'idle_seconds', return_value=session_idle), \
                        patch.object(coordinator.time, 'monotonic', return_value=1000.0), \
                        patch.object(pilot, 'record_one') as launch, patch.object(pilot.signal, 'signal'):
                    if min(session_idle, hardware_idle) < 300:
                        with self.assertRaisesRegex(RuntimeError, 'no app launched'): pilot.record(root)
                        launch.assert_not_called()
                    else:
                        pilot.record(root)
                        self.assertEqual([call.args[2] for call in launch.call_args_list], ['cmdy', 'ghostty'])
                    sampled.assert_called_once()
                observed = json.loads((root / 'pair-activity-start.json').read_text())
                self.assertEqual(observed, sample)

    def test_existing_public_session_constructs_same_payload_and_binding_without_launch(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); marker = '1' * 16
            payload = root / 'payload.bin'
            payload.write_bytes(pilot.memory_payload(pilot.expectation(pilot.CASE, marker + '0' * 16)))
            self.assertEqual(payload.stat().st_size, 78000)
            options = pilot.BenchOptions(Path('/owned/cmdy'), Path('/owned/ghostty'), payload=payload,
                                         tooling_dir=coordinator.TESTS)
            with patch.object(coordinator.bench.subprocess, 'Popen') as launched:
                for terminal in ('cmdy', 'ghostty'):
                    public = pilot.PublicHistorySession(options, Path('/owned/window-helper'), terminal,
                        root / terminal, pilot.CASE, payload, marker, Path('/owned/python'))
                    private = [Path(public.session.temporary.name), Path(public.export_directory.name),
                               Path(public.control_directory.name)]
                    try:
                        config = public.session.config_path.read_text().splitlines()
                        receipt = json.loads((public.directory / 'public-history-binding.json').read_text())['shortcutBinding']
                        validate_binding(terminal, public.session.config_path, receipt)
                        self.assertEqual(receipt['actionInvocationVerified'], False)
                        if terminal == 'cmdy':
                            self.assertFalse(any(line.startswith('keybind') for line in config))
                            self.assertEqual((public.session.config_path.parent / 'keybindings.json').read_bytes(), cmdy_store_bytes())
                        else:
                            self.assertEqual(config.count('keybind = ctrl+shift+enter=write_scrollback_file:paste'), 1)
                        self.assertEqual(public.session.environment['TMPDIR'], public.export_directory.name + '/')
                        self.assertEqual(pilot.memory_payload(public.expected), payload.read_bytes())
                        self.assertTrue(all(path.stat().st_mode & 0o077 == 0 for path in private))
                        self.assertLess(len(str(public.socket_path).encode()), 104)
                    finally:
                        public.close()
                    self.assertTrue(all(not path.exists() for path in private))
                launched.assert_not_called()

    def test_generated_drain_requires_exact_footer_reply_byte_count_and_grid(self):
        footer, response = pilot.expected_reply(36, 120, 0)
        drain = dict(payloadBytes=78000, footerHex=footer.hex(), responseHex=response.hex(),
                     expectedResponseHex=response.hex(), gridBefore=dict(columns=120, rows=36),
                     gridAfter=dict(columns=120, rows=36))
        pilot.check_drain(drain, dict(payloadBytes=78000))
        for change in (dict(payloadBytes=77922), dict(responseHex=''), dict(footerHex=''),
                       dict(gridAfter=dict(columns=119, rows=36))):
            with self.subTest(change=change), self.assertRaises((RuntimeError, ValueError)):
                pilot.check_drain(dict(drain, **change), dict(payloadBytes=78000))

    def test_native_helper_is_reaped_and_failure_retained_on_interruption(self):
        process = SimpleNamespace(pid=4242, returncode=None)
        def communicate(**_):
            if process.returncode is None: raise InterruptedError('test interruption')
            return b'', None
        process.communicate = communicate
        process.poll = lambda: process.returncode
        process.kill = lambda: setattr(process, 'returncode', -9)
        with tempfile.TemporaryDirectory() as name, \
                patch.object(pilot.subprocess, 'Popen', return_value=process), \
                self.assertRaises(InterruptedError):
            root = Path(name) / 'request'
            try:
                pilot.native_json(root, ['/owned/helper', 'inspect', '--spec', '/owned/spec'])
            finally:
                receipt = json.loads((root / 'process.json').read_text())
                self.assertTrue(receipt['reaped']); self.assertTrue(receipt['forcedKill'])
                self.assertEqual(receipt['exitCode'], -9)


class CleanupTests(unittest.TestCase):
    def fixture(self, root):
        directory = root / 'transport/cmdy'
        private = [root / 'removed-app-work', root / 'removed-exports', root / 'removed-control']
        domain = 'com.cmdy.bench.' + 'a' * 32
        save(directory / 'launch.json', dict(terminal='cmdy', appPID=111, workerPID=222,
             cwd=str(private[0] / 'work'), defaultsDomain=domain))
        save(directory / 'public-history-binding.json', dict(temporaryDirectory=str(private[1]),
             socketPath=str(private[2] / 'control.sock')))
        save(directory / 'cleanup.json', dict(appPID=111, returncode=-15,
             defaultsExport=dict(command=['/usr/bin/defaults', 'export', domain, '-'], returncode=0),
             defaultsDelete=dict(command=['/usr/bin/defaults', 'delete', domain], returncode=0)))
        save(directory / 'pilot-cleanup.json', dict(status='pass', appPID=111, workerPID=222,
             appReaped=True, originalWorkerAbsent=True,
             privatePaths=[dict(path=str(path), absent=True) for path in private]))
        return directory, private

    def test_partial_pair_cleanup_is_independently_audited(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); directory, _ = self.fixture(root)
            with patch.object(coordinator.bench, 'process_identity', return_value=None):
                self.assertEqual(pilot.audit_cleanup(root)['observedLaunches'], 1)
                with self.assertRaisesRegex(RuntimeError, 'both owned launches'):
                    pilot.audit_cleanup(root, require_pair=True)
                (directory / 'cleanup.json').unlink()
                with self.assertRaises(FileNotFoundError): pilot.audit_cleanup(root)

    def test_live_pid_retained_directory_wrong_defaults_and_omitted_paths_reject(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); directory, private = self.fixture(root)
            with patch.object(coordinator.bench, 'process_identity', return_value='still alive'), \
                    self.assertRaisesRegex(RuntimeError, 'still exists'):
                pilot.audit_cleanup(root)
            with patch.object(coordinator.bench, 'process_identity', return_value=None):
                private[1].mkdir()
                with self.assertRaisesRegex(RuntimeError, 'temporary path remains'): pilot.audit_cleanup(root)
                private[1].rmdir()
                cleanup = json.loads((directory / 'cleanup.json').read_text())
                changed = deepcopy(cleanup); changed['defaultsDelete']['command'][2] = 'com.user.existing'
                save(directory / 'cleanup.json', changed)
                with self.assertRaisesRegex(RuntimeError, 'defaults cleanup'): pilot.audit_cleanup(root)
                save(directory / 'cleanup.json', cleanup)
                owned = json.loads((directory / 'pilot-cleanup.json').read_text()); owned['privatePaths'] = []
                save(directory / 'pilot-cleanup.json', owned)
                with self.assertRaisesRegex(RuntimeError, 'path set differs'): pilot.audit_cleanup(root)


class PairEvidenceTests(unittest.TestCase):
    def fixture(self, root):
        worker = root / 'tooling/Tests/history_export_worker.py'
        worker.parent.mkdir(parents=True); worker.write_text('# synthetic pinned test input\n')
        payload = root / 'primary-1000.bin'
        payload.write_bytes(pilot.memory_payload(pilot.expectation(pilot.CASE, NONCE)))
        plan = dict(generatedMarker=NONCE[:16], payload=str(payload), payloadBytes=78000,
                    payloadSHA256=coordinator.sha(payload), python='/owned/python3.13', displayID=1,
                    historyHelper='/owned/history-helper', binaries={}, childUmask=0o077)
        footer, reply = pilot.expected_reply(36, 120, 0)
        for index, terminal in enumerate(('cmdy', 'ghostty')):
            directory = root / 'transport' / terminal
            document, raw = file_transfer_fixture(pilot.CASE)
            def rebind(value):
                if isinstance(value, dict):
                    return {key: (item + index * 100 if isinstance(item, int) and
                            key in ('pid','parentPID','expectedAppPID','expectedWorkerPID','observedPID',
                                    'requestedPID','foregroundPID','workerPID','targetPID') else rebind(item))
                            for key, item in value.items()}
                if isinstance(value, list): return [rebind(item) for item in value]
                return '/owned/' + terminal if value == '/owned/app' else value
            document = rebind(document); document['terminal'] = terminal
            spec = document['expectation']; app = document['nativeSpec']['pid']; child = document['nativeSpec']['workerPID']
            plan['binaries'][terminal] = dict(path='/owned/' + terminal, sha256=terminal + '-pin')
            document['nativeSpec']['executableSHA256'] = terminal + '-pin'
            document['workerReady'].update(payloadBytes=78000, payloadSHA256=plan['payloadSHA256'])
            history = dict(expectation=spec, transfer=document, transferValidation=pilot.validate_transfer(document, raw),
                           before=dict(ok=True, op='inspect', owner=document['beforeOwner']),
                           action=document['action'], after=dict(ok=True, op='inspect', owner=document['afterOwner']))
            save(directory / 'history-verification.json', history)
            save(directory / 'pilot.json', dict(status='valid-generated-file-transfer',
                                               historySHA256=coordinator.sha(directory / 'history-verification.json')))
            retained = directory / 'fixture/generated-export.bin'; retained.parent.mkdir(mode=0o700); retained.write_bytes(raw); retained.chmod(0o600)
            config = directory / 'config'; config.write_text('font-family = Menlo\n')
            shortcut_binding = install_binding(terminal, config)
            command = [plan['python'], '-S', str(worker)]
            private = [root / ('removed-' + terminal + '-app'), Path(document['workerReady']['temporaryDirectory']),
                       root / ('removed-' + terminal + '-control')]
            document['workerReady']['socketPath'] = str(private[2] / 'socket')
            save(directory / 'history-verification.json', history)
            save(directory / 'pilot.json', dict(status='valid-generated-file-transfer',
                                               historySHA256=coordinator.sha(directory / 'history-verification.json')))
            domain = 'com.cmdy.bench.' + 'a' * 32
            save(directory / 'launch.json', dict(terminal=terminal, appPID=app, workerPID=child,
                arguments=['/owned/' + terminal], config=str(config), configSHA256=coordinator.sha(config), childUmask=0o077,
                fixtureCommand=command, cwd=str(private[0] / 'work'), defaultsDomain=domain,
                environment=dict(TMPDIR=str(private[1]) + '/', CMDY_CONFIG_DIR=str(config.parent))))
            save(directory / 'public-history-binding.json', dict(nonce=spec['nonce'], expectation=spec, worker=command,
                workerSHA256=coordinator.sha(worker), temporaryDirectory=str(private[1]), socketPath=str(private[2] / 'socket'),
                shortcutBinding=shortcut_binding, childUmask=0o077))
            save(directory / 'generated-drain.json', dict(payloadBytes=78000, footerHex=footer.hex(), responseHex=reply.hex(),
                expectedResponseHex=reply.hex(), gridBefore=dict(columns=120, rows=36), gridAfter=dict(columns=120, rows=36)))
            save(directory / 'history-finish.json', dict(workerExit=dict(pid=child, exited=True)))
            save(directory / 'fixture/cleanup.json', dict(pid=child, nonce=spec['nonce'], status='pass',
                reason='controller-finish', unexpectedInputBytes=0, termiosRestored=True, fileFlagsRestored=True,
                terminalRestoreWritten=True, controlSocketRemoved=True))
            save(directory / 'cleanup.json', dict(appPID=app, returncode=0,
                defaultsExport=dict(command=['/usr/bin/defaults','export',domain,'-'], returncode=0),
                defaultsDelete=dict(command=['/usr/bin/defaults','delete',domain], returncode=0)))
            save(directory / 'pilot-cleanup.json', dict(status='pass', appPID=app, workerPID=child,
                appReaped=True, originalWorkerAbsent=True, privatePaths=[dict(path=str(path), absent=True) for path in private]))
            for ordinal, (operation, value) in enumerate((('inspect', history['before']), ('post-key', history['action']),
                                                        ('inspect', history['after'])), 1):
                request = directory / 'native-requests' / f'{ordinal:02d}-{operation}'
                save(request / 'response.json', value)
                save(request / 'process.json', dict(command=[plan['historyHelper'],operation], reaped=True,
                                                     exitCode=0, pid=1000+index*10+ordinal))
        return plan

    def test_complete_pair_replays_full_rows_and_rejects_detached_binary_or_worker_identity(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as name:
            root = Path(name); plan = self.fixture(root); case = dict(output=str(root / 'transport'))
            with patch.object(pilot, 'check_plan', return_value=plan), \
                    patch.object(coordinator.bench, 'process_identity', return_value=None):
                result = pilot.audit_case(case)
                self.assertEqual(result['measuredSamples'], 0)
                self.assertEqual([item['generatedHistory']['logicalRows'] for item in result['transfers']], [1000, 1000])
                path = root / 'transport/ghostty/history-verification.json'
                original = json.loads(path.read_text())
                for change in (dict(pid=777), dict(workerPID=777), dict(executableSHA256='wrong')):
                    modified = deepcopy(original); modified['transfer']['nativeSpec'].update(change); save(path, modified)
                    save(path.with_name('pilot.json'), dict(status='valid-generated-file-transfer',
                                                          historySHA256=coordinator.sha(path)))
                    with self.subTest(change=change), self.assertRaisesRegex(RuntimeError, 'app identity differs'):
                        pilot.audit_case(case)

    def test_missing_wrong_or_forged_public_store_is_rejected(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as name:
            root = Path(name)
            for terminal in ('cmdy', 'ghostty'):
                config = root / terminal / 'config'; config.parent.mkdir(); config.write_text('font-family = Menlo\n')
                receipt = install_binding(terminal, config)
                self.assertEqual(validate_binding(terminal, config, receipt)['keyCode'], 36)
                for update in (dict(bindingPath='/not-the-generated-store'), dict(keyCode=19),
                               dict(modifierFlags=0), dict(actionInvocationVerified=True)):
                    with self.subTest(terminal=terminal, update=update), self.assertRaises(ValueError):
                        validate_binding(terminal, config, dict(receipt, **update))
                if terminal == 'cmdy':
                    store = config.parent / 'keybindings.json'; raw = store.read_bytes(); store.unlink()
                    with self.assertRaisesRegex(ValueError, 'public-binding-store-differs'):
                        validate_binding(terminal, config, receipt)
                    changed = json.loads(raw); changed['mappings'][0]['command']['value'] = 'copy'
                    store.write_text(json.dumps(changed))
                    with self.assertRaisesRegex(ValueError, 'public-binding-store-differs'):
                        validate_binding(terminal, config, receipt)
                else:
                    config.write_text(config.read_text().replace('ctrl+shift+enter', 'ctrl+shift+2'))
                    with self.assertRaisesRegex(ValueError, 'public-binding-config-differs'):
                        validate_binding(terminal, config, receipt)

    def test_missing_or_unequal_child_umask_receipts_reject_the_pair(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as name:
            root = Path(name); plan = self.fixture(root); case = dict(output=str(root / 'transport'))
            with patch.object(pilot, 'check_plan', return_value=plan), \
                    patch.object(coordinator.bench, 'process_identity', return_value=None):
                self.assertEqual(pilot.audit_case(case)['measuredSamples'], 0)
                for terminal in ('cmdy', 'ghostty'):
                    for filename in ('launch.json', 'public-history-binding.json'):
                        path = root / 'transport' / terminal / filename
                        original = json.loads(path.read_text())
                        for mode in (None, 0o022, '0077', True):
                            changed = deepcopy(original)
                            if mode is None: changed.pop('childUmask')
                            else: changed['childUmask'] = mode
                            save(path, changed)
                            with self.subTest(terminal=terminal, file=filename, mode=mode), \
                                    self.assertRaisesRegex(RuntimeError, 'child umask differs'):
                                pilot.audit_case(case)
                        save(path, original)
                plan['childUmask'] = 0o022
                with self.assertRaisesRegex(RuntimeError, 'child umask differs'): pilot.audit_case(case)


if __name__ == '__main__': unittest.main()
