"""Generated data and mocked native requests only; no app, AX, capture or clipboard."""
import base64
from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import compare_resize as pilot
from test_resize_calibration import discovery, document_fixture, rehash
from resize_protocol import cell_classes_bytes

c = pilot.c


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def shrink_document():
    doc = document_fixture(); small = discovery(); bounds = pilot.larger_bounds(small)
    large = discovery(132, 40, bounds)
    for value, sequence in ((small, 0), (large, 1)):
        evidence = json.loads(value['evidenceUTF8']); evidence['sequence'] = sequence; rehash(value, evidence)
    doc.update(source=large['calibration'], target=small['calibration'], sourceDiscovery=large,
               targetDiscovery=small, planned=deepcopy(pilot.PLANNED))
    doc['display']['initialTTYGrid'] = dict(columns=132, rows=40)
    entry = doc['entry']; expected = pilot.expected_event(doc['nonce'], pilot.PLANNED); entry['expected'] = expected
    entry['worker'].update(sequence=2, grid=dict(columns=120, rows=36), sourceGrid=[132, 40],
        offeredBytes=expected['payloadBytes'], completedBytes=expected['payloadBytes'], payloadSHA256=expected['payloadSHA256'])
    entry['arm']['pending'].update(sequence=2, target=[120, 36])
    observer = entry['observer']; observer.update(sequence=2, finalTTYGrid=dict(columns=120, rows=36))
    observer['action']['requestedBounds'] = small['calibration']['outerBounds']
    observer['action']['beforeProof']['bounds'] = bounds
    observer['action']['afterProof']['bounds'] = small['calibration']['outerBounds']
    encoded = base64.b64encode(cell_classes_bytes(doc['nonce'], 2, 120, 36)).decode()
    for frame in observer['frames']:
        for side in ('before', 'after'):
            frame[side]['bounds'] = small['calibration']['outerBounds'] if frame['matching'] else bounds
        if frame['matching']: frame['observedCellClasses'] = encoded
    first = observer['firstCompleteFrame']
    first.update(matchedRows=36, matchedCells=4320, cellClassesSHA256=expected['cellClassesSHA256'],
                 words=expected['words'], observedCellClasses=encoded)
    for key in ('beforeProof', 'afterProof'): first[key]['bounds'] = small['calibration']['outerBounds']
    observer['finalProof']['bounds'] = small['calibration']['outerBounds']
    return doc


class CalibrationTests(unittest.TestCase):
    def test_target_uses_discovered_pixel_pitch_and_actual_scale(self):
        value = discovery(); result = pilot.larger_bounds(value)
        self.assertEqual(result, dict(x=10, y=10, width=1048, height=632))
        for field, change in (('cellWidthPixels', float('nan')), ('tolerance', 12), ('columns', 132)):
            wrong = deepcopy(value); wrong['calibration'][field] = change
            with self.subTest(field=field), self.assertRaises((RuntimeError, ValueError)): pilot.larger_bounds(wrong)

    def calibrate(self, wrong_target=False, activity=False):
        small = discovery(); target = pilot.larger_bounds(small)
        large = discovery(132, 40, dict(target, width=target['width'] + (1 if wrong_target else 0)))
        native = SimpleNamespace(started=document_fixture()['display'], close=lambda *_: None)
        requests = []
        def request(operation, **fields):
            requests.append((operation, fields))
            return dict(result=small if fields['sequence'] == 0 else large)
        native.request = request
        with tempfile.TemporaryDirectory() as name, patch.object(pilot.recorder, 'Native', return_value=native), \
                patch.object(native, 'close') as close, patch.object(pilot, 'worker_request', return_value={}) as arm, \
                patch.object(pilot, 'wait_grid_event', return_value={}) as wait, \
                patch.object(c.bench, 'window_command', return_value={'ok': True}) as action:
            root = Path(name) / 'calibration'
            session = SimpleNamespace(ready={}, helper=Path('/owned/window-helper'), app_pid=123)
            def quiet():
                if activity: raise RuntimeError('session input resumed')
            if wrong_target or activity:
                with self.assertRaises(RuntimeError): pilot.calibrate(Path('/owned/observer'), root, {}, session, 'a' * 32, quiet)
                close.assert_called_once_with(False)
            else:
                self.assertEqual(pilot.calibrate(Path('/owned/observer'), root, {}, session, 'a' * 32, quiet), (small, large))
                close.assert_called_once_with(True)
            if activity:
                arm.assert_not_called(); action.assert_not_called(); wait.assert_not_called()
            else:
                arm.assert_called_once(); wait.assert_called_once()
                action.assert_called_once_with(session.helper, 'resize', 123, 1048, 632)
                self.assertEqual(requests, [('discover', dict(sequence=0, columns=120, rows=36)),
                                            ('discover', dict(sequence=1, columns=132, rows=40))])

    def test_one_public_calibration_transition_and_exact_discoveries(self): self.calibrate()
    def test_wrong_target_never_refits_or_retries(self): self.calibrate(wrong_target=True)
    def test_activity_before_calibration_resize_prevents_action(self): self.calibrate(activity=True)

    def test_wait_requires_actual_grid_and_completed_sequence(self):
        good = dict(completedEvents=1, grid=dict(columns=132, rows=40), pending=None, events=[dict(sequence=1)])
        with patch.object(pilot, 'worker_request', return_value=good):
            self.assertEqual(pilot.wait_grid_event({}, 'a' * 32, 1, pilot.LARGE), good)
        for changed in (dict(grid=dict(columns=131, rows=40)), dict(completedEvents=2), dict(pending={})):
            with patch.object(pilot, 'worker_request', return_value=dict(good, **changed)), self.assertRaises(RuntimeError):
                pilot.wait_grid_event({}, 'a' * 32, 1, pilot.LARGE)


class EnvelopeTests(unittest.TestCase):
    def test_full_pair_audit_joins_native_records_apps_and_cleanup(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve(); worker_source = root / 'tooling/Tests/resize_worker.py'
            worker_source.parent.mkdir(parents=True); shutil.copy2(c.TESTS / 'resize_worker.py', worker_source)
            build = root / 'observer-build.json'; save(build, dict(generatedTestBuild=True))
            nonce = shrink_document()['nonce']
            plan = dict(nonce=nonce, binaries={}, python='/generated/python', helper='/generated/helper',
                        observerBuild=str(build), displayID=1)
            for terminal, offset in (('cmdy', 0), ('ghostty', 100)):
                directory = root / 'observations' / terminal; doc = shrink_document()
                def rebind(value):
                    if isinstance(value, dict):
                        return {k: (v + offset if type(v) is int and k.lower().endswith('pid') else rebind(v)) for k, v in value.items()}
                    if isinstance(value, list): return [rebind(v) for v in value]
                    return '/generated/' + terminal if value == '/generated/owned' else value
                doc = rebind(doc); app, worker = 123 + offset, 124 + offset
                for side in ('source', 'target'):
                    value = doc[side + 'Discovery']
                    rehash(value, rebind(json.loads(value['evidenceUTF8'])))
                    doc[side] = deepcopy(value['calibration'])
                plan['binaries'][terminal] = dict(path='/generated/' + terminal, sha256=terminal + '-bytes')
                private = [root / (terminal + '-absent-work'), root / (terminal + '-absent-control')]
                cwd = private[0] / 'work'; domain = 'com.cmdy.bench.' + 'a' * 32
                capability = 'b' * 32
                command = [plan['python'], '-B', str(worker_source), '--output', str(directory / 'fixture'),
                    '--socket-directory', str(private[1]), '--capability', capability, '--nonce', nonce, '--timeout', '90']
                ready = dict(pid=worker, ttyPath='/dev/ttys001', nonce=nonce)
                request = dict(nativeSpec=dict(executableSHA256=terminal + '-bytes', windowID=456, displayID=1,
                    pid=app, workerPID=worker, ttyPath=ready['ttyPath'], nonce=nonce, thermalState=0, lowPowerMode=False, timeoutSeconds=40),
                    sourceSequence=1, planned=deepcopy(pilot.PLANNED), workerCapability=capability, workerReady=ready,
                    **{k: doc[k] for k in ('source', 'target', 'sourceDiscovery', 'targetDiscovery')})
                save(directory / 'event/event.json', doc); save(directory / 'event/request.json', request)
                save(directory / 'event/result.json', pilot.validate_document(doc))
                shutil.copy2(build, directory / 'event/observer-build.json')
                config = directory / 'config'; config.write_text(c.bench.terminal_config(terminal,
                    c.bench.BenchOptions(Path('/unused'), Path('/unused'), profile='matched', font_size=14), pilot.SMALL, cwd))
                save(directory / 'launch.json', dict(appPID=app, workerPID=worker, terminal=terminal, cwd=str(cwd),
                    defaultsDomain=domain, fixtureCommand=command, config=str(config), configSHA256=c.sha(config),
                    arguments=[plan['binaries'][terminal]['path']] + ([] if terminal == 'cmdy' else
                        ['--config-default-files=false', '--config-file=' + str(config)])))
                save(directory / 'binding.json', dict(worker=command, workerSHA256=c.sha(worker_source),
                    capability=capability, controlDirectory=str(private[1])))
                save(directory / 'pilot.json', dict(status='valid-resize-viewport-diagnostic', eventSHA256=c.sha(directory / 'event/event.json')))
                save(directory / 'pilot-cleanup.json', dict(complete=True, appPID=app, workerPID=worker,
                    appReaped=True, originalWorkerAbsent=True, privatePaths=[dict(path=str(p), absent=True) for p in private]))
                save(directory / 'cleanup.json', dict(appPID=app, returncode=0,
                    defaultsExport=dict(command=['/usr/bin/defaults', 'export', domain, '-'], returncode=0),
                    defaultsDelete=dict(command=['/usr/bin/defaults', 'delete', domain], returncode=0)))
                for component, pid in (('calibration', 500 + offset), ('event', 501 + offset)):
                    native = directory / component / 'native'
                    save(native / 'cleanup.json', dict(exited=True, pipesClosed=True, ownedPID=pid, successfulBlock=True, returncode=0))
                    save(native / 'spec.json', request['nativeSpec'])
                    initial = deepcopy(doc['display'])
                    if component == 'calibration': initial['initialTTYGrid'] = dict(columns=120, rows=36)
                    save(native / '0001.json', initial)
                    if component == 'calibration':
                        save(native / '0002.json', dict(result=doc['targetDiscovery']))
                        save(native / '0003.json', dict(result=doc['sourceDiscovery']))
                        save(native / '0004.json', dict(op='finished'))
                    else:
                        save(native / '0002.json', dict(op='verify', sequence=1))
                        save(native / '0003.json', dict(op='armed'))
                        save(native / '0004.json', doc['entry']['observer'])
                        save(native / '0005.json', dict(op='finished'))
                save(directory / 'calibration/large.json', doc['sourceDiscovery']); save(directory / 'calibration/small.json', doc['targetDiscovery'])
                bounds = doc['source']['outerBounds']; save(directory / 'calibration/target-request.json', bounds)
                save(directory / 'calibration/action.json', dict(command=[plan['helper'], 'resize', app, bounds['width'], bounds['height']], response={'ok': True}))
                save(directory / 'fixture/ready.json', ready)
                (directory / 'fixture/history.bin').write_bytes(pilot.history(nonce))
                save(directory / 'fixture/received.json', dict(events=[dict(sequence=1), doc['entry']['worker']]))
                save(directory / 'fixture/cleanup.json', dict(pid=worker, nonce=nonce, error='', stopReason='controller-finish',
                    pending=None, uncompletedOfferedSequence=None, unexpectedCleanupInputBytes=0,
                    **{k: True for k in ('termiosRestored', 'terminalRestoreWritten', 'fileFlagsRestored', 'signalWakeupRestored', 'signalPipeClosed')}))
            with patch.object(pilot, 'check_plan', return_value=plan), patch.object(c.bench, 'process_identity', return_value=None):
                result = pilot.audit_case(dict(output=str(root / 'observations')))
                self.assertEqual([row['matchedCells'] for row in result['observations']], [4320, 4320])
                self.assertEqual(result['cleanup']['observedLaunches'], 2); self.assertEqual(result['measuredSamples'], 0)
                native = root / 'observations/cmdy/event/native/0004.json'; raw = c.read(native); raw['sequence'] = 99; save(native, raw)
                with self.assertRaisesRegex(RuntimeError, 'native response differs'):
                    pilot.audit_case(dict(output=str(root / 'observations')))

    def test_recorder_waits_for_source_pixels_before_arm_or_worker_request(self):
        for missing in (False, True):
            with self.subTest(sourceMissing=missing), tempfile.TemporaryDirectory() as name:
                doc = shrink_document(); calls = []; closed = []
                request = dict(schemaVersion=1, qualifying=False, nonce=doc['nonce'], nativeSpec=dict(
                    nonce=doc['nonce'], workerPID=124, ttyPath='/dev/ttys001'),
                    workerReady=dict(pid=124, ttyPath='/dev/ttys001'), workerCapability='a' * 32,
                    sourceSequence=1, planned=pilot.PLANNED,
                    **{k: doc[k] for k in ('source', 'target', 'sourceDiscovery', 'targetDiscovery')})
                def native_request(op, **fields):
                    calls.append(op)
                    if op == 'verify':
                        self.assertEqual(fields, dict(sequence=1, calibration=doc['source']))
                        if missing: raise RuntimeError('source pixels did not arrive')
                    if op == 'arm': self.assertEqual(calls, ['verify', 'arm'])
                    return doc['entry']['observer'] if op == 'go' else {'ok': True}
                native = SimpleNamespace(started=doc['display'], request=native_request, close=closed.append)
                def worker(*args, **fields):
                    self.assertEqual(calls[:2], ['verify', 'arm'])
                    return doc['entry']['arm'] if args[2] == 'arm' else {'events': [doc['entry']['worker']]}
                with patch.object(pilot.recorder, 'validate_build', return_value={}), \
                        patch.object(pilot.recorder, 'Native', return_value=native), \
                        patch.object(pilot.recorder, 'worker_request', side_effect=worker) as control:
                    if missing:
                        with self.assertRaisesRegex(RuntimeError, 'source pixels'):
                            pilot.recorder.record_diagnostic(Path('/unused'), Path('/unused'), request, Path(name) / 'event')
                        self.assertEqual(calls, ['verify']); control.assert_not_called(); self.assertEqual(closed, [False])
                    else:
                        result = pilot.recorder.record_diagnostic(Path('/unused'), Path('/unused'), request, Path(name) / 'event')
                        self.assertTrue(result['diagnosticValid']); self.assertEqual(calls, ['verify', 'arm', 'go']); self.assertEqual(closed, [True])

    def test_complete_shrink_observes_all_4320_cells_and_stays_unqualified(self):
        doc = shrink_document(); result = pilot.validate_document(doc)
        self.assertTrue(result['diagnosticValid']); self.assertFalse(result['qualifying'])
        self.assertTrue(doc['planned']['warmup']); self.assertEqual(doc['entry']['observer']['finalTTYGrid'], dict(columns=120, rows=36))
        for kind in ('last-cell', 'initial-owner', 'refresh', 'first-frame', 'actual-grid'):
            wrong = deepcopy(doc)
            if kind == 'last-cell':
                wrong['entry']['observer']['firstCompleteFrame']['observedCellClasses'] = base64.b64encode(b'\x00' * 4320).decode()
            if kind == 'initial-owner': wrong['sourceDiscovery']['calibration']['outerBounds']['width'] += 1
            if kind == 'refresh': wrong['display']['displayMode']['refreshRate'] = 120
            if kind == 'first-frame': wrong['entry']['observer']['firstCompleteFrame']['displayTicks'] += 1
            if kind == 'actual-grid': wrong['entry']['observer']['finalTTYGrid']['columns'] = 119
            with self.subTest(kind=kind), self.assertRaises(ValueError): pilot.validate_document(wrong)

    def test_both_initial_idle_clocks_are_required_before_owned_session(self):
        for session, hardware in ((400, 0), (0, 400), (400, 400)):
            with self.subTest(session=session, hardware=hardware), tempfile.TemporaryDirectory() as name:
                root = Path(name); save(root / 'plan.json', {})
                save(root / 'execution.json', dict(status='running', pid=os.getppid(), planSHA256=c.sha(root / 'plan.json')))
                sample = dict(idleSeconds=session, hardwareIdleSeconds=hardware, sessionReadFinishedMonotonicNS=10**9)
                with patch.object(pilot, 'check_plan', return_value={}), patch.object(c, 'activity_sample', return_value=sample), \
                        patch.object(pilot, 'record_one') as owned, patch.object(pilot.signal, 'signal'):
                    if min(session, hardware) < 300:
                        with self.assertRaisesRegex(RuntimeError, 'no app launched'): pilot.record(root)
                        owned.assert_not_called()
                    else:
                        pilot.record(root)
                        self.assertEqual([call.args[2] for call in owned.call_args_list], ['cmdy', 'ghostty'])
                self.assertEqual(c.read(root / 'pair-activity-start.json'), sample)

    def test_untimed_finalizer_cannot_admit_resize_or_retained_history(self):
        with tempfile.TemporaryDirectory() as name, patch.object(pilot, 'audit_case', return_value=dict(observations=[])), \
                patch.object(c.subprocess, 'run') as gate:
            root = Path(name); plan = dict(cases=[{}], measuredSamples=0, warmups=0, performanceAdmission=False); result = {}
            c.finish_untimed(root, plan, result, pilot.finish)
            gate.assert_not_called(); self.assertFalse(result['goalMet']); self.assertFalse(result['performanceAdmission'])
            self.assertFalse(c.read(root / 'untimed-result.json')['historyRetentionVerified'])

    def test_missing_observer_cleanup_live_pid_and_wrong_defaults_fail(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); directory = root / 'observations/cmdy'; domain = 'com.cmdy.bench.' + 'a' * 32
            private = [root / 'absent-work', root / 'absent-control']
            save(directory / 'launch.json', dict(appPID=111, workerPID=222, terminal='cmdy', cwd=str(private[0] / 'work'), defaultsDomain=domain))
            save(directory / 'binding.json', dict(controlDirectory=str(private[1])))
            save(directory / 'pilot-cleanup.json', dict(complete=True, appPID=111, workerPID=222, appReaped=True, originalWorkerAbsent=True,
                privatePaths=[dict(path=str(p), absent=True) for p in private]))
            cleanup = dict(appPID=111, returncode=0,
                defaultsExport=dict(command=['/usr/bin/defaults', 'export', domain, '-'], returncode=0),
                defaultsDelete=dict(command=['/usr/bin/defaults', 'delete', domain], returncode=0))
            save(directory / 'cleanup.json', cleanup)
            save(directory / 'event/native/cleanup.json', dict(exited=True, pipesClosed=True, ownedPID=333))
            with patch.object(c.bench, 'process_identity', return_value=None):
                self.assertEqual(pilot.audit_cleanup(root)['allRecordedPIDsAbsent'], [111, 222, 333])
                (directory / 'event/native/cleanup.json').unlink()
                with self.assertRaises(FileNotFoundError): pilot.audit_cleanup(root)
                (directory / 'event/native').rmdir()
                cleanup['defaultsDelete']['command'][2] = 'com.user.existing'; save(directory / 'cleanup.json', cleanup)
                with self.assertRaisesRegex(RuntimeError, 'defaults cleanup'): pilot.audit_cleanup(root)
            with patch.object(c.bench, 'process_identity', return_value='live'), self.assertRaises(RuntimeError): pilot.audit_cleanup(root)


if __name__ == '__main__': unittest.main()
