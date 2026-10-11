"""Generated receipts and mocked native calls only; no app, display or capture."""
from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import compare_startup as pilot
from startup_evidence_tests import fixture, TOKEN

c = pilot.coordinator


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


class PreparationTests(unittest.TestCase):
    def test_prepare_freezes_qualified_sources_without_native_queries_or_launches(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve(); qualified = root / 'qualified'; (qualified / 'tooling').mkdir(parents=True)
            sources = {n: c.sha(c.TESTS / n) for n in pilot.RUNTIME}
            for n in sources: shutil.copy2(c.TESTS / n, qualified / 'tooling' / n)
            observer = qualified / 'startup-observer'; observer.write_bytes(b'unit-test observer stub, never executed')
            python_sha = c.sha(Path(sys.executable).resolve())
            save(qualified / 'results.json', dict(status='pass', sourcesUnchanged=True, nativeObservationRun=False,
                applicationLaunches=0, pythonTests=48, swiftChecks=70, sourceSHA256=sources,
                commands=[dict(exitCode=0, exitedAndReaped=True)], observerSHA256=c.sha(observer), pythonRuntimeSHA256=python_sha))
            save(qualified / 'startup-observer-build.json', dict(headlessQualified=True, nativeObservationRun=False,
                binarySHA256=c.sha(observer), sourceSHA256={n: sources[n] for n in pilot.OBSERVER_SOURCES}, toolingSHA256=sources))
            helper = root / 'window-helper'; helper.write_bytes(b'unit-test window stub, never executed')
            window = root / 'window.json'; save(window, dict(status='passed-headless-native-pilot-required',
                helper=dict(path=str(helper), sha256=c.sha(helper), sourceSHA256=c.sha(c.TESTS / 'TerminalBenchWindow.swift'))))
            review = root / 'review.json'; save(review, dict(status='pass-no-open-findings',
                inputs={str(c.HERE / 'compare_output.py'): c.sha(c.HERE / 'compare_output.py')}))
            candidate = root / 'candidate'; candidate.mkdir(); app = candidate / 'cmdy'; app.write_bytes(b'unit-test app')
            save(candidate / 'candidate.json', {'syntheticTestFixture': True})
            ghostty = root / 'ghostty'; ghostty.write_bytes(b'unit-test comparator')
            args = SimpleNamespace(candidate=candidate, startup_qualification=qualified, window_qualification=window,
                activity_review=review, output=root / 'prepared', ghostty_bin=ghostty, ghostty_sha256=c.sha(ghostty),
                power_source='Battery Power', display_id=1)
            approved = dict(binary='cmdy', signed_binary_sha256=c.sha(app), native_source_key='source-key', native_archive_sha256='archive')
            with patch.object(c.candidate_preparation, 'verify', return_value=approved), \
                    patch.object(c.bench, 'power_snapshot', return_value={'signature': {'source': 'Battery Power'}}), \
                    patch.object(pilot.subprocess, 'Popen') as native, patch.object(pilot.subprocess, 'run') as direct:
                pilot.prepare(args)
                native.assert_not_called(); direct.assert_not_called()
            plan = pilot.check_plan(args.output)
            self.assertEqual(plan['binaries']['cmdy']['path'], str(app))
            self.assertEqual(plan['targetGrid'], [98, 29]); self.assertFalse(plan['initialRequestValidated'])
            self.assertFalse(plan['performanceAdmission']); self.assertEqual(plan['measuredSamples'], 0)
            self.assertFalse((args.output / 'observations').exists())
            for n, value in sources.items(): self.assertEqual(c.sha(args.output / 'tooling/Tests' / n), value)
            (args.output / 'tooling/Tests/startup_native.swift').write_text('changed')
            with self.assertRaisesRegex(RuntimeError, 'frozen comparison tool changed'): pilot.check_plan(args.output)

    def test_both_idle_clocks_and_active_supervisor_precede_native_work(self):
        for session, hardware in ((400, 0), (0, 400), (400, 400)):
            with self.subTest(session=session, hardware=hardware), tempfile.TemporaryDirectory() as name:
                root = Path(name); save(root / 'plan.json', {})
                save(root / 'execution.json', dict(status='running', pid=os.getppid(), planSHA256=c.sha(root / 'plan.json')))
                sample = dict(idleSeconds=session, hardwareIdleSeconds=hardware, sessionReadFinishedMonotonicNS=1_000_000_000)
                with patch.object(pilot, 'check_plan', return_value={}), patch.object(c, 'activity_sample', return_value=sample), \
                        patch.object(pilot, 'record_one') as native, patch.object(pilot.signal, 'signal'):
                    if min(session, hardware) < 300:
                        with self.assertRaisesRegex(RuntimeError, 'no app launched'): pilot.record(root)
                        native.assert_not_called()
                    else:
                        pilot.record(root)
                        self.assertEqual([x.args[2] for x in native.call_args_list], ['cmdy', 'ghostty'])
                self.assertEqual(c.read(root / 'pair-activity-start.json'), sample)

    def test_returned_activity_after_display_probe_prevents_owned_launch(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); (root / 'observations').mkdir()
            plan = dict(binaries={'cmdy': {'path': '/owned/app'}}, token=TOKEN)
            with patch.object(pilot, 'probe_display', return_value={}), patch.object(pilot.recorder, 'prepare'), \
                    patch.object(c, 'idle_seconds', return_value=0), patch.object(c.time, 'monotonic', return_value=1000), \
                    patch.object(pilot.recorder, 'record') as launch, self.assertRaisesRegex(RuntimeError, 'no app launched'):
                pilot.record_one(root, plan, 'cmdy', 400, 1000)
            launch.assert_not_called()
            self.assertEqual(c.read(root / 'observations/cmdy/pilot.json')['status'], 'failed')

    def test_interrupted_probe_is_reaped_without_starting_an_app(self):
        process = SimpleNamespace(pid=123, returncode=None)
        def communicate(**_):
            if process.returncode is None: raise InterruptedError('synthetic interruption')
            return b'', None
        process.communicate = communicate; process.poll = lambda: process.returncode
        process.kill = lambda: setattr(process, 'returncode', -9)
        with tempfile.TemporaryDirectory() as name, patch.object(pilot.subprocess, 'Popen', return_value=process):
            root = Path(name) / 'probe'
            with self.assertRaises(InterruptedError): pilot.probe_display(root, dict(observer='/owned/observer', displayID=1))
            receipt = c.read(root / 'process.json')
            self.assertTrue(receipt['reaped']); self.assertTrue(receipt['forcedKill']); self.assertEqual(receipt['exitCode'], -9)


def pair_fixture(root):
    root = root.resolve(); tooling = root / 'tooling/Tests'; tooling.mkdir(parents=True)
    for name in pilot.recorder.PREPARATION_SOURCES: shutil.copy2(c.TESTS / name, tooling / name)
    payload = root / 'first-generation.bin'; payload.write_bytes(pilot.Witness(TOKEN, 98, 29, 1, 1).frame_bytes())
    plan = dict(token=TOKEN, targetGrid=[98, 29], payloadBytes=payload.stat().st_size, payloadSHA256=c.sha(payload),
        python=str(Path(sys.executable).resolve()), pythonSHA256=c.sha(Path(sys.executable).resolve()),
        binaries={}, profile='matched', displayID=1, observer='/owned/observer', observerBuild=str(root / 'build.json'))
    save(Path(plan['observerBuild']), dict(unitTestBuild=True))
    for offset, terminal in ((0, 'cmdy'), (100, 'ghostty')):
        directory = root / 'observations' / terminal; inputs = directory / 'inputs'; observation = directory / 'observation'
        executable = root / (terminal + '-executable'); executable.write_bytes(('unit-test-' + terminal).encode())
        plan['binaries'][terminal] = dict(path=str(executable), sha256=c.sha(executable))
        raw, display = fixture()
        manifest = pilot.recorder.prepare(inputs, terminal, executable, display, token=TOKEN)
        spec = c.read(inputs / 'spec.json')
        def rebind(value):
            if isinstance(value, dict):
                return {key: (item + offset if type(item) is int and key.lower().endswith('pid') else rebind(item))
                        for key, item in value.items()}
            if isinstance(value, list): return [rebind(item) for item in value]
            if value == '/owned/app': return str(executable)
            if value == '/owned/python': return plan['python']
            return value
        raw = rebind(raw); raw.update(spec=spec, specSHA256=manifest['specSHA256']); raw['cleanup']['childStatus'] = 0
        save(observation / 'raw.json', raw); save(observation / 'prepared.json', manifest)
        shutil.copy2(Path(plan['observerBuild']), observation / 'observer-build.json')
        domain = manifest['defaultsDomain']
        defaults = dict(complete=True, status='not-applicable') if terminal == 'ghostty' else dict(complete=True,
            status='already-absent', domain=domain, commands=[dict(arguments=['/usr/bin/defaults', 'export', domain, '-'],
                exitedAndReaped=True, exitCode=1, stdout='', stderr='Domain ' + domain + ' does not exist')])
        result = pilot.validate(raw, spec, manifest['specSHA256'])
        result.update(observerReaped=True, observerPID=10 + offset, observerExitCode=0, ownedDefaultsCleanup=defaults)
        save(observation / 'result.json', result)
        save(directory / 'pilot.json', dict(status='valid-first-generation-startup', actualInitialGrid=[98, 29],
                                             rawSHA256=c.sha(observation / 'raw.json')))
        save(directory / 'display-probe/stdout.json', {k: spec[k] for k in pilot.DISPLAY_FIELDS})
        save(directory / 'display-probe/process.json', dict(command=[plan['observer'], '--probe-display', '1'],
                                                          pid=5 + offset, reaped=True, exitCode=0))
    return plan


class AuditTests(unittest.TestCase):
    def test_complete_generated_pair_has_only_functional_admission(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve(); plan = pair_fixture(root)
            with patch.object(pilot, 'check_plan', return_value=plan), patch.object(c.bench, 'process_identity', return_value=None):
                result = pilot.audit_case(dict(output=str(root / 'observations')))
            self.assertEqual(result['measuredSamples'], 0); self.assertEqual(len(result['observations']), 2)
            self.assertEqual(result['cleanup']['observedLaunches'], 2)

    def test_wrong_binary_probe_and_worker_command_fail_closed(self):
        changes = [('inputs/spec.json', lambda v: v.update(executableSHA256='0' * 64)),
                   ('display-probe/process.json', lambda v: v['command'].__setitem__(1, '--capture-after-launch')),
                   ('inputs/prepared.json', lambda v: v['fixtureCommand'].__setitem__(0, '/other/python'))]
        for name, mutate in changes:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); plan = pair_fixture(root); path = root / 'observations/cmdy' / name
                value = c.read(path); mutate(value); save(path, value)
                with patch.object(pilot, 'check_plan', return_value=plan), patch.object(c.bench, 'process_identity', return_value=None), \
                        self.assertRaises((RuntimeError, ValueError)):
                    pilot.audit_case(dict(output=str(root / 'observations')))

    def test_prearm_missing_pixels_wrong_owner_and_short_stability_cannot_pass(self):
        mutations = [lambda r: r['frames'][0].update(checkedTicks=1001),
                     lambda r: r.update(proofs={}),
                     lambda r: r['frames'][1]['before'].update(foregroundPID=999),
                     lambda r: r.update(finishedTicks=5000)]
        for mutate in mutations:
            raw, spec = fixture(); mutate(raw)
            with self.assertRaises((ValueError, KeyError, TypeError)): pilot.validate(raw, spec, raw['specSHA256'])

    def test_forged_initial_grid_later_generation_and_synthetic_receipts_reject(self):
        raw, _ = fixture(); event = raw['workerEvents']['events'][0]
        plan = dict(targetGrid=[98, 29], payloadSHA256=event['payloadSHA256'], payloadBytes=event['offeredBytes'])
        pilot.initial_generation(raw, plan)
        for mutate in (lambda r: r['workerReady'].update(initialColumns=96),
                       lambda r: r['workerEvents']['events'][0].update(generation=2),
                       lambda r: r['workerEvents']['events'].append(deepcopy(r['workerEvents']['events'][0])),
                       lambda r: r.update(syntheticTestFixture=True)):
            value = deepcopy(raw); mutate(value)
            with self.assertRaises(RuntimeError): pilot.initial_generation(value, plan)

    def test_true_initial_transition_retains_first_target_generation(self):
        raw,_=fixture(initial_grid=(44,16),signal_ticks=(1150,));event=raw['workerEvents']['events'][0]
        plan=dict(targetGrid=[98,29],payloadSHA256=event['payloadSHA256'],payloadBytes=event['offeredBytes'])
        pilot.initial_generation(raw,plan)
        self.assertEqual(raw['workerReady']['initialColumns'],44)

    def test_live_pid_missing_cleanup_or_wrong_defaults_suite_reject(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve(); pair_fixture(root)
            with patch.object(c.bench, 'process_identity', return_value='still alive'), self.assertRaises(RuntimeError):
                pilot.audit_cleanup(root)
            path = root / 'observations/cmdy/observation/result.json'; value = c.read(path)
            with patch.object(c.bench, 'process_identity', return_value=None):
                value['ownedDefaultsCleanup']['commands'][0]['arguments'][2] = 'com.user.existing'
                save(path, value)
                with self.assertRaisesRegex(RuntimeError, 'defaults operation'): pilot.audit_cleanup(root)
                path.unlink()
                with self.assertRaises(FileNotFoundError): pilot.audit_cleanup(root)

    def test_invalid_initial_grid_is_retained_when_native_recorder_rejects(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); (root / 'observations').mkdir()
            plan = dict(binaries={'ghostty': {'path': '/owned/ghostty'}}, token=TOKEN,
                        observer='/owned/observer', observerBuild='/owned/build')
            def failed(*args):
                save(args[-1] / 'raw.json', dict(unverifiedWorkerReady=dict(initialColumns=96, initialRows=28),
                                                workerEvents=dict(events=[dict(generation=1)])))
                raise ValueError('invalid native first grid')
            with patch.object(pilot, 'probe_display', return_value={}), patch.object(pilot.recorder, 'prepare'), \
                    patch.object(pilot.recorder, 'record', side_effect=failed), patch.object(c, 'idle_seconds', return_value=400), \
                    patch.object(c.time, 'monotonic', return_value=1000), self.assertRaisesRegex(ValueError, 'first grid'):
                pilot.record_one(root, plan, 'ghostty', 400, 1000)
            item = c.read(root / 'observations/ghostty/pilot.json')
            self.assertEqual(item['actualInitialGrid'], [96, 28]); self.assertEqual(item['observedGenerations'], [1])
            self.assertFalse(item['initialWorkerIdentityVerified']); self.assertEqual(item['status'], 'failed')

    def test_missing_raw_receipt_status_survives_controller_failure(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);(root/'observations').mkdir()
            plan=dict(binaries={'cmdy':{'path':'/owned/inert'}},token=TOKEN,
                      observer='/owned/inert-observer',observerBuild='/owned/inert-build')
            def failed(*args):
                save(args[-1]/'result.json',dict(nativeReceipt=dict(status='missing'),diagnosticValid=False))
                raise ValueError('native startup diagnostic failed; raw receipt missing')
            with patch.object(pilot,'probe_display',return_value={}),patch.object(pilot.recorder,'prepare'), \
                    patch.object(pilot.recorder,'record',side_effect=failed),patch.object(c,'idle_seconds',return_value=400), \
                    patch.object(c.time,'monotonic',return_value=1000),self.assertRaisesRegex(ValueError,'missing'):
                pilot.record_one(root,plan,'cmdy',400,1000)
            item=c.read(root/'observations/cmdy/pilot.json')
            self.assertEqual(item['nativeReceipt']['status'],'missing')
            self.assertEqual(item['status'],'failed');self.assertNotIn('actualInitialGrid',item)


if __name__ == '__main__': unittest.main()
