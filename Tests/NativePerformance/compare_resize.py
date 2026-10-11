#!/usr/bin/env python3
"""Prepare one untimed public-resize pair with fresh same-lifetime calibration."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import tempfile
import time
import uuid

import compare_output as c
from owned_defaults_cleanup import classify_owned_defaults_cleanup
import resize_recorder as recorder
from resize_calibration_evidence import validate_discovery
from resize_controller import worker_request, expected_event
from resize_evidence import validate_document
from resize_protocol import history, frame_bytes, digest

KIND = 'untimed-public-resize-with-live-calibration'
SMALL, LARGE = (120, 36), (132, 40)
PLANNED = dict(sequence=2, columns=120, rows=36, warmup=True)


def prepare(args):
    candidate = args.candidate.resolve(); qualified = c.candidate_preparation.verify(candidate)
    qpath = args.resize_qualification.resolve(); q = c.read(qpath)
    delta = c.read(args.recorder_qualification)
    c.require(delta['status'] == 'pass' and delta['baselineQualificationSHA256'] == c.sha(qpath)
        and delta['changedSourcePaths'] == ['Tests/resize_recorder.py']
        and delta['beforeSHA256'] == q['sourceSHA256']['Tests/resize_recorder.py']
        and delta['afterSHA256'] == c.sha(c.TESTS / 'resize_recorder.py')
        and delta['nativeActions'] == 0 and delta['reaped'] is True, 'recorder delta is not qualified')
    build_path = Path(q['native']['observerBuild']); build = c.read(build_path)
    c.require(q['status'] == 'headless-adapter-validation-pass' and q['nativeGUIRun'] is False
        and q['windowResizesPosted'] == 0 and q['native']['syntheticChecks'] == 116 and q['python']['tests'] == 44
        and c.sha(build_path) == q['native']['observerBuildSHA256']
        and c.sha(Path(q['native']['result'])) == q['native']['resultSHA256']
        and c.read(Path(q['native']['result']))['status'] == 'pass', 'qualified resize inputs differ')
    output = args.output.resolve(); output.mkdir(mode=0o700, parents=True, exist_ok=False)
    tooling = output / 'tooling/Tests'; native = tooling / 'NativePerformance'; native.mkdir(parents=True)
    for name, value in q['sourceSHA256'].items():
        expected = delta['afterSHA256'] if name == 'Tests/resize_recorder.py' else value
        c.require(name.startswith('Tests/') and c.sha(c.TESTS.parent / name) == expected
            and c.sha(Path(q['frozenSourceDirectory']) / name) == value, 'qualified resize source changed: ' + name)
        shutil.copy2(c.TESTS.parent / name, output / 'tooling' / name)
    for name in ('competitive_bench.py', 'terminal_bench_worker.py', 'TerminalBenchWindow.swift', 'parity-policy.json', 'RESIZE-PILOT.md'):
        shutil.copy2(c.TESTS / name, tooling / name)
    c.require(c.sha(tooling / 'parity-policy.json') == q['policyUnchanged']['sha256'], 'public policy changed')
    for name in ('compare_resize.py', 'compare_output.py', 'prepare.py', 'owned_defaults_cleanup.py'):
        shutil.copy2(c.HERE / name, native / name)
    observer = output / 'resize-observer'; shutil.copy2(build_path.with_name('resize-observer'), observer)
    recorder.validate_build(observer, build_path)
    shutil.copy2(build_path, output / 'resize-observer-build.json'); shutil.copy2(qpath, output / 'resize-qualification.json')
    shutil.copy2(args.recorder_qualification, output / 'recorder-qualification.json')
    w = c.read(args.window_qualification); helper = output / 'window-helper'; shutil.copy2(Path(w['helper']['path']), helper)
    c.require(w['status'] == 'passed-headless-native-pilot-required' and c.sha(helper) == w['helper']['sha256']
        and c.sha(tooling / 'TerminalBenchWindow.swift') == w['helper']['sourceSHA256'], 'window helper identity differs')
    shutil.copy2(args.window_qualification, output / 'window-qualification.json')
    review = c.read(args.activity_review)
    c.require(review['status'] == 'pass-no-open-findings'
        and review['inputs'][str(c.HERE / 'compare_output.py')] == c.sha(native / 'compare_output.py'), 'activity guard differs from review')
    shutil.copy2(args.activity_review, output / 'activity-review.json')
    binaries = {name: c.bench.binary_metadata(path) for name, path in (
        ('cmdy', candidate / qualified['binary']), ('ghostty', args.ghostty_bin.resolve()))}
    c.require(binaries['cmdy']['sha256'] == qualified['signed_binary_sha256']
        and binaries['ghostty']['sha256'] == args.ghostty_sha256, 'application identity differs')
    nonce = uuid.uuid4().hex; payload = output / 'history.bin'; payload.write_bytes(history(nonce)); payload.chmod(0o600)
    python = Path(sys.executable).resolve()
    command = [str(python), '-B', str(native / 'compare_resize.py'), 'record', '--output', str(output)]
    plan = dict(schemaVersion=1, kind=KIND, output=str(output), createdUTC=c.utc(), candidate=str(candidate),
        candidateManifestSHA256=c.sha(candidate / 'candidate.json'), binaries=binaries,
        nativeSourceKey=qualified['native_source_key'], nativeArchiveSHA256=qualified['native_archive_sha256'],
        helper=str(helper), observer=str(observer), observerBuild=str(output / 'resize-observer-build.json'),
        python=str(python), pythonSHA256=c.sha(python), nonce=nonce, profile='matched', fontSize=14,
        powerSource=args.power_source, displayID=args.display_id, initialGrid=list(SMALL), calibrationGrid=list(LARGE),
        finalGrid=list(SMALL), diagnosticEvent=PLANNED, calibrationTransitionsPerApp=1, diagnosticEventsPerApp=1,
        historySHA256=c.sha(payload), historyBytes=147000, historyRetentionVerified=False,
        cases=[dict(workload='resize-viewport', output=str(output / 'observations'), command=command)],
        measuredSamples=0, warmups=0, qualifying=False, performanceAdmission=False, priorSamplesInherited=False,
        exclusions=[], minimumHumanIdleSeconds=300, maximumCaseSeconds=180, foregroundAuthorized=True,
        requiredPermissions=['accessibilityTrusted', 'screenCaptureAuthorized'], captureRequired=True,
        clipboardAccessed=False, appleEventsUsed=False, nativeCalibrationPassed=False,
        targetMismatch='fatal; no fitting or retry after worker preparation',
        scope='one diagnostic generated-cell resize per app; no retained-history or performance admission',
        pins={str(p.relative_to(output)): c.sha(p) for p in sorted(output.rglob('*')) if p.is_file()})
    c.write_new(output / 'plan.json', plan)
    print(json.dumps(dict(status='prepared-no-native-actions', output=str(output))))


def check_plan(root):
    plan = c.read(root / 'plan.json')
    c.require(plan['kind'] == KIND and Path(plan['output']) == root and plan['initialGrid'] == list(SMALL)
        and plan['calibrationGrid'] == list(LARGE) and plan['finalGrid'] == list(SMALL)
        and plan['diagnosticEvent'] == PLANNED and plan['profile'] == 'matched' and plan['fontSize'] == 14
        and plan['measuredSamples'] == plan['warmups'] == 0 and plan['performanceAdmission'] is False
        and plan['qualifying'] is False and plan['historyRetentionVerified'] is False
        and plan['minimumHumanIdleSeconds'] == 300, 'resize pilot contract differs')
    c.verify_inputs(root, plan, c.sha(root / 'plan.json'))
    c.require(c.sha(Path(plan['python'])) == plan['pythonSHA256']
        and (root / 'history.bin').read_bytes() == history(plan['nonce'])
        and (root / 'history.bin').stat().st_size == plan['historyBytes'] == 147000, 'generated workload/runtime differs')
    return plan


def larger_bounds(discovery):
    """One setup request, derived only from independently learned cell pitch."""
    cal = validate_discovery(discovery)
    c.require((cal['columns'], cal['rows']) == SMALL, 'initial calibration grid differs')
    display = cal['displayBounds']; bounds = dict(cal['outerBounds'])
    bounds['width'] += 12 * cal['cellWidthPixels'] * display['width'] / cal['captureWidth']
    bounds['height'] += 4 * cal['rowPitchPixels'] * display['height'] / cal['captureHeight']
    c.require(all(type(v) in (int, float) and math.isfinite(v) for v in bounds.values())
        and bounds['x'] >= display['x'] and bounds['y'] >= display['y']
        and bounds['x'] + bounds['width'] <= display['x'] + display['width']
        and bounds['y'] + bounds['height'] <= display['y'] + display['height'], 'derived calibration target leaves display')
    return bounds


def wait_grid_event(ready, capability, sequence, target):
    deadline = time.monotonic() + 3
    while True:
        value = worker_request(ready, capability, 'status')
        if value['completedEvents'] == sequence:
            c.require(value['grid'] == dict(zip(('columns', 'rows'), target)) and value['pending'] is None
                and value['events'][-1]['sequence'] == sequence, 'actual calibration target differs')
            return value
        c.require(value['completedEvents'] < sequence and time.monotonic() < deadline, 'calibration did not reach actual target; no retry')
        time.sleep(.02)


def calibrate(observer, directory, native_spec, session, capability, quiet, *, settle_target=None):
    directory.mkdir(mode=0o700); native = recorder.Native(observer, directory, native_spec); success = False
    try:
        small = native.request('discover', sequence=0, columns=120, rows=36)['result']
        validate_discovery(small, native.started)
        target = larger_bounds(small)
        c.write_new(directory / 'small.json', small); c.write_new(directory / 'target-request.json', target)
        quiet()
        armed = worker_request(session.ready, capability, 'arm', sequence=1, grid=dict(columns=132, rows=40))
        c.write_new(directory / 'worker-arm.json', armed)
        # Only one public size request. The fixture is prepared now; fitting
        # again or repainting a substituted target is forbidden.
        action = c.bench.window_command(session.helper, 'resize', session.app_pid, target['width'], target['height'])
        c.write_new(directory / 'action.json', dict(command=[str(session.helper), 'resize', session.app_pid,
            target['width'], target['height']], response=action))
        status = wait_grid_event(session.ready, capability, 1, LARGE); c.write_new(directory / 'worker-status.json', status)
        if settle_target is not None:
            # Untimed discovery must not race the native window's setup
            # transition. This hook observes the one requested target only;
            # it may not issue another resize or change the pixel oracle.
            settle_target(target)
        large = native.request('discover', sequence=1, columns=132, rows=40)['result']
        validate_discovery(large, native.started)
        c.require(large['calibration']['outerBounds'] == target, 'actual target bounds differ; no correction permitted')
        c.write_new(directory / 'large.json', large)
        success = True
        return small, large
    finally:
        native.close(success)


def close_session(session, control, directory):
    """Reuse only the isolated launcher's exact child/defaults cleanup."""
    worker = session.worker_identity
    if worker is None and session.process is not None and session.ready_path.is_file():
        ready = c.read(session.ready_path); pid = ready.get('pid')
        if type(pid) is int and c.bench.is_descendant(pid, session.app_pid):
            identity = c.bench.process_identity(pid)
            if identity: worker = session.worker_identity = (pid, identity)
    paths = [Path(session.temporary.name), Path(control.name)]
    try:
        session.close()
    finally:
        control.cleanup()
        value = dict(appPID=session.process.pid if session.process else None,
            appReaped=session.process is None or session.process.returncode is not None,
            workerPID=worker[0] if worker else None, workerStartIdentity=worker[1] if worker else None,
            originalWorkerAbsent=worker is not None and c.bench.process_identity(worker[0]) is None,
            privatePaths=[dict(path=str(p), absent=not p.exists()) for p in paths])
        value['complete'] = value['appReaped'] and value['originalWorkerAbsent'] and all(p['absent'] for p in value['privatePaths'])
        c.write_new(directory / 'pilot-cleanup.json', value)


def record_one(root, plan, terminal, quiet):
    directory = root / 'observations' / terminal; fixture = directory / 'fixture'
    control = tempfile.TemporaryDirectory(prefix='cmdy-resize-control-', dir='/private/tmp')
    capability = uuid.uuid4().hex; session = None; item = dict(status='failed', terminal=terminal, qualifying=False)
    try:
        command = [plan['python'], '-B', str(root / 'tooling/Tests/resize_worker.py'), '--output', str(fixture),
            '--socket-directory', control.name, '--capability', capability, '--nonce', plan['nonce'], '--timeout', '90']
        options = c.bench.BenchOptions(Path(plan['binaries']['cmdy']['path']), Path(plan['binaries']['ghostty']['path']),
            profile='matched', font_size=14, timeout=10, tooling_dir=root / 'tooling/Tests')
        session = c.bench.TerminalSession(options, Path(plan['helper']), terminal, directory, SMALL,
                                         fixture_command=command, ready_path=fixture / 'ready.json')
        c.write_new(directory / 'binding.json', dict(capability=capability, worker=command, nonce=plan['nonce'],
            controlDirectory=control.name, workerSHA256=c.sha(root / 'tooling/Tests/resize_worker.py')))
        quiet(); session.launch()
        c.require(session.worker_identity and session.ready['nonce'] == plan['nonce'], 'owned resize worker not established')
        quiet(); session.window(activate=True); session.place_window(120, 120); session.fit_grid(SMALL, allow_resize=True)
        window = session.window()['windows'][0]
        c.require(window['displayID'] == plan['displayID'], 'owned window is on another display')
        prepared = worker_request(session.ready, capability, 'prepare'); c.write_new(directory / 'worker-prepare.json', prepared)
        c.require(prepared['history']['payloadSHA256'] == plan['historySHA256']
            and prepared['history']['offeredBytes'] == prepared['history']['completedBytes'] == 147000,
            'generated history write differs')
        spec = dict(pid=session.app_pid, workerPID=session.worker_identity[0], ttyPath=session.ready['ttyPath'],
            executableSHA256=plan['binaries'][terminal]['sha256'], windowID=window['windowID'], displayID=plan['displayID'],
            nonce=plan['nonce'], lowPowerMode=False, thermalState=0, timeoutSeconds=40)
        quiet(); small, large = calibrate(Path(plan['observer']), directory / 'calibration', spec, session, capability, quiet)
        request = dict(schemaVersion=1, qualifying=False, nonce=plan['nonce'], nativeSpec=spec,
            workerReady=session.ready, workerCapability=capability, source=large['calibration'], target=small['calibration'],
            sourceDiscovery=large, targetDiscovery=small, sourceSequence=1, planned=PLANNED)
        quiet(); result = recorder.record_diagnostic(Path(plan['observer']), Path(plan['observerBuild']), request, directory / 'event')
        c.require(result['diagnosticValid'] is True and session.grid() == dict(columns=120, rows=36), 'final actual grid/viewport invalid')
        finish = worker_request(session.ready, capability, 'finish'); c.write_new(directory / 'worker-finish.json', finish)
        deadline = time.monotonic() + 3
        while c.bench.process_identity(session.worker_identity[0]) == session.worker_identity[1] and time.monotonic() < deadline:
            time.sleep(.02)
        c.require((fixture / 'cleanup.json').is_file(), 'worker cleanup record missing')
        item.update(status='valid-resize-viewport-diagnostic', eventSHA256=c.sha(directory / 'event/event.json'))
    except BaseException as error:
        item['error'] = str(error); raise
    finally:
        old = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            if session is not None: close_session(session, control, directory)
            else: control.cleanup()
        finally:
            for sig, handler in old.items(): signal.signal(sig, handler)
            c.write_new(directory / 'pilot.json' if directory.exists() else root / ('failed-' + terminal + '.json'), item)


def record(root):
    plan = check_plan(root); execution = c.read(root / 'execution.json')
    c.require(execution['status'] == 'running' and execution['pid'] == os.getppid()
        and execution['planSHA256'] == c.sha(root / 'plan.json'), 'native pilot requires active parent supervisor')
    sample = c.activity_sample(); c.write_new(root / 'pair-activity-start.json', sample); c.require_initial_quiet(sample, 300)
    started = sample['sessionReadFinishedMonotonicNS'] / 1e9
    def quiet():
        c.require(not c.human_returned(sample['idleSeconds'], time.monotonic() - started, c.idle_seconds()),
                  'session activity resumed; no next native action')
    def interrupted(*_): raise InterruptedError('supervised resize pilot interrupted')
    signal.signal(signal.SIGINT, interrupted); signal.signal(signal.SIGTERM, interrupted)
    (root / 'observations').mkdir(mode=0o700)
    for terminal in ('cmdy', 'ghostty'): record_one(root, plan, terminal, quiet)


def audit_cleanup(root, require_pair=False):
    paths = sorted((root / 'observations').glob('*/launch.json')); pids = []
    c.require(not require_pair or len(paths) == 2, 'both owned resize launches required')
    for path in paths:
        launch = c.read(path); value = c.read(path.with_name('pilot-cleanup.json')); cleanup = c.read(path.with_name('cleanup.json'))
        c.require(value['complete'] is True and value['appReaped'] is True and value['originalWorkerAbsent'] is True
            and value['appPID'] == launch['appPID'] == cleanup['appPID'] and value['workerPID'] == launch['workerPID']
            and type(cleanup['returncode']) is int, 'app/worker cleanup incomplete')
        pids += [value['appPID'], value['workerPID']]
        binding = c.read(path.with_name('binding.json'))
        c.require([p['path'] for p in value['privatePaths']] == [str(Path(launch['cwd']).parent), binding['controlDirectory']]
            and all(p['absent'] is True and not Path(p['path']).exists() for p in value['privatePaths']), 'owned private directory remains')
        if launch['terminal'] == 'cmdy':
            domain = launch['defaultsDomain']; exported = cleanup['defaultsExport']; deleted = cleanup['defaultsDelete']
            classify_owned_defaults_cleanup(domain, exported, deleted)
        for native_directory in path.parent.glob('*/native'):
            native = c.read(native_directory / 'cleanup.json')
            c.require(native['exited'] is True and native['pipesClosed'] is True, 'observer cleanup incomplete')
            pids.append(native['ownedPID'])
    c.require(all(type(pid) is int and pid > 0 and c.bench.process_identity(pid) is None for pid in pids), 'owned PID still exists')
    return dict(status='owned-cleanup-pass', observedLaunches=len(paths), allRecordedPIDsAbsent=pids)


def audit_case(case):
    root = Path(case['output']).parent; plan = check_plan(root); cleanup = audit_cleanup(root, require_pair=True); rows = []
    for terminal in ('cmdy', 'ghostty'):
        directory = root / 'observations' / terminal; document = c.read(directory / 'event/event.json')
        request = c.read(directory / 'event/request.json'); launch = c.read(directory / 'launch.json'); binding = c.read(directory / 'binding.json')
        item = c.read(directory / 'pilot.json'); result = validate_document(document)
        c.require(item['status'] == 'valid-resize-viewport-diagnostic' and item['eventSHA256'] == c.sha(directory / 'event/event.json')
            and document['planned'] == PLANNED and document['nonce'] == plan['nonce']
            and document['display']['identity']['pid'] == launch['appPID']
            and document['display']['workerIdentity']['pid'] == launch['workerPID']
            and document['display']['identity']['executable'] == plan['binaries'][terminal]['path']
            and request['nativeSpec']['executableSHA256'] == plan['binaries'][terminal]['sha256']
            and request['nativeSpec']['windowID'] == document['display']['windowID']
            and request['nativeSpec']['displayID'] == document['display']['displayID'] == plan['displayID']
            and request['nativeSpec']['pid'] == launch['appPID']
            and request['nativeSpec']['workerPID'] == request['workerReady']['pid'] == launch['workerPID']
            and request['nativeSpec']['ttyPath'] == request['workerReady']['ttyPath']
            and request['nativeSpec']['nonce'] == request['workerReady']['nonce'] == plan['nonce']
            and request['nativeSpec']['thermalState'] == 0 and request['nativeSpec']['lowPowerMode'] is False
            and request['nativeSpec']['timeoutSeconds'] == 40
            and request['sourceSequence'] == 1 and request['planned'] == PLANNED
            and request['workerCapability'] == binding['capability']
            and request['workerReady'] == c.read(directory / 'fixture/ready.json'), 'owned event preparation differs')
        for key in ('source', 'target', 'sourceDiscovery', 'targetDiscovery'):
            c.require(request[key] == document[key], 'recorder discovery differs')
        c.require(document['sourceDiscovery'] == c.read(directory / 'calibration/large.json')
            and document['targetDiscovery'] == c.read(directory / 'calibration/small.json')
            and larger_bounds(document['targetDiscovery']) == document['source']['outerBounds'], 'same-lifetime calibration transition differs')
        for component in ('calibration', 'event'):
            native_dir = directory / component / 'native'; native = c.read(native_dir / 'cleanup.json')
            c.require(native['successfulBlock'] is True and native['returncode'] == 0, 'native helper failed')
            response_count = 4 if component == 'calibration' else 5
            c.require(c.read(native_dir / 'spec.json') == request['nativeSpec']
                and sorted(p.name for p in native_dir.glob('[0-9]*.json')) == [f'{n:04d}.json' for n in range(1, response_count + 1)],
                'native request or response inventory differs')
        initial = c.read(directory / 'calibration/native/0001.json')
        c.require(c.read(directory / 'event/native/0001.json') == document['display']
            and initial['identity'] == document['display']['identity']
            and initial['workerIdentity'] == document['display']['workerIdentity']
            and initial['initialTTYGrid'] == dict(columns=120, rows=36)
            and document['display']['initialTTYGrid'] == dict(columns=132, rows=40)
            and c.read(directory / 'calibration/native/0002.json')['result'] == document['targetDiscovery']
            and c.read(directory / 'calibration/native/0003.json')['result'] == document['sourceDiscovery']
            and c.read(directory / 'event/native/0002.json')['op'] == 'verify'
            and c.read(directory / 'event/native/0002.json')['sequence'] == 1
            and c.read(directory / 'event/native/0004.json') == document['entry']['observer'], 'retained native response differs')
        for discovery, sequence in ((document['targetDiscovery'], 0), (document['sourceDiscovery'], 1)):
            evidence = json.loads(discovery['evidenceUTF8'])
            c.require(evidence['nonce'] == plan['nonce'] and evidence['sequence'] == sequence, 'calibration generation differs')
        target_bounds = document['source']['outerBounds']
        c.require(c.read(directory / 'calibration/target-request.json') == target_bounds
            and c.read(directory / 'calibration/action.json')['command'] == [plan['helper'], 'resize', launch['appPID'],
                target_bounds['width'], target_bounds['height']]
            and c.read(directory / 'calibration/action.json')['response']['ok'] is True, 'public calibration request differs')
        c.require(c.read(directory / 'event/observer-build.json') == c.read(Path(plan['observerBuild'])), 'observer build differs')
        c.require(all(c.read(directory / 'event/result.json')[k] == v for k, v in result.items()), 'stored independent result differs')
        c.require(launch['fixtureCommand'] == binding['worker'] and binding['worker'][0:3] == [plan['python'], '-B', str(root / 'tooling/Tests/resize_worker.py')]
            and binding['workerSHA256'] == c.sha(root / 'tooling/Tests/resize_worker.py')
            and (directory / 'fixture/history.bin').read_bytes() == history(plan['nonce'])
            and c.sha(Path(launch['config'])) == launch['configSHA256'], 'worker, generated corpus or config changed')
        config = Path(launch['config'])
        c.require(launch['arguments'] == [plan['binaries'][terminal]['path']] + ([] if terminal == 'cmdy' else
            ['--config-default-files=false', '--config-file=' + str(config)])
            and config.read_text() == c.bench.terminal_config(terminal, c.bench.BenchOptions(Path('/unused'), Path('/unused'),
                profile='matched', font_size=14), SMALL, Path(launch['cwd']))
            and binding['worker'] == [plan['python'], '-B', str(root / 'tooling/Tests/resize_worker.py'), '--output',
                str(directory / 'fixture'), '--socket-directory', binding['controlDirectory'], '--capability', binding['capability'],
                '--nonce', plan['nonce'], '--timeout', '90'], 'public config or exact fixture command differs')
        worker = c.read(directory / 'fixture/cleanup.json'); received = c.read(directory / 'fixture/received.json')
        c.require(worker['pid'] == launch['workerPID'] and worker['nonce'] == plan['nonce'] and worker['error'] == ''
            and worker['stopReason'] == 'controller-finish' and worker['pending'] is None and worker['uncompletedOfferedSequence'] is None
            and worker['unexpectedCleanupInputBytes'] == 0 and all(worker[k] is True for k in (
                'termiosRestored', 'terminalRestoreWritten', 'fileFlagsRestored', 'signalWakeupRestored', 'signalPipeClosed'))
            and [e['sequence'] for e in received['events']] == [1, 2]
            and received['events'][1] == document['entry']['worker'], 'worker completion or event inventory differs')
        rows.append(dict(terminal=terminal, actualFinalGrid=document['entry']['observer']['finalTTYGrid'],
            matchedCells=document['entry']['observer']['firstCompleteFrame']['matchedCells'],
            display={k: document['display'][k] for k in ('displayID', 'displayMode', 'displayBounds', 'captureWidth', 'captureHeight')},
            eventSHA256=c.sha(directory / 'event/event.json')))
    c.require(rows[0]['display'] == rows[1]['display'], 'paired display geometry/mode differs')
    return dict(measuredSamples=0, warmups=0, observations=rows, cleanup=cleanup,
        files={str(p.relative_to(root / 'observations')): c.sha(p) for p in sorted((root / 'observations').rglob('*')) if p.is_file()})


def finish(root, plan):
    result = audit_case(plan['cases'][0])
    return dict(status='paired-resize-viewport-diagnostic-pass', qualifying=False, performanceAdmission=False,
        measuredSamples=0, goalMet=False, historyRetentionVerified=False, observations=result['observations'], osClipboardAccessed=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__); actions = parser.add_subparsers(dest='action', required=True)
    prep = actions.add_parser('prepare'); prep.add_argument('--candidate', type=Path, required=True)
    prep.add_argument('--resize-qualification', type=Path, required=True); prep.add_argument('--window-qualification', type=Path, required=True)
    prep.add_argument('--recorder-qualification', type=Path, required=True)
    prep.add_argument('--activity-review', type=Path, required=True)
    prep.add_argument('--ghostty-bin', type=Path, default=Path('/Applications/Ghostty.app/Contents/MacOS/ghostty'))
    prep.add_argument('--ghostty-sha256', required=True); prep.add_argument('--power-source', choices=('AC Power', 'Battery Power'), required=True)
    prep.add_argument('--display-id', type=int, default=1)
    for action in (prep, actions.add_parser('run'), actions.add_parser('record'), actions.add_parser('audit-cleanup')):
        action.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'prepare': prepare(args)
    elif args.action == 'record': record(args.output.resolve())
    elif args.action == 'audit-cleanup': print(json.dumps(audit_cleanup(args.output.resolve()), indent=2))
    else:
        check_plan(args.output.resolve()); c.run(args, audit=audit_case, untimed_finalizer=finish)


if __name__ == '__main__': main()
