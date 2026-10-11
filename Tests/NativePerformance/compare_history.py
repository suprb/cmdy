#!/usr/bin/env python3
"""Prepare one untimed public-history pair; native execution requires explicit run."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import termios
import time
import uuid

import compare_output as coordinator
from owned_defaults_cleanup import classify_owned_defaults_cleanup
from competitive_bench import BenchOptions
from history_export_build import PUBLIC_TOOLING, SOURCES
from history_export_binding import shortcut_event, validate_binding
from history_export_evidence import validate_transfer
from history_export_files import read_retained_generated
from history_export_protocol import ACTION, FILE_PROOF_SCOPE, SHORTCUT, expectation, expected_bytes, memory_payload, validate_export_bytes
from history_export_phase import POLICY, CASES, contract, selected_action, validate_contract, validate_phase, validate_phase_cleanup
from memory_public_history import PublicHistorySession, TRANSPORT, VERIFICATION_TRANSPORT
from terminal_bench_worker import expected_reply

CASE = 'primary-1000'
CHILD_UMASK = 0o077
LAUNCH_TOOLING = ('competitive_bench.py', 'memory_public_history.py', 'NativePerformance/compare_history.py',
    'history_executable_identity.py')
RUNTIME = tuple(dict.fromkeys(PUBLIC_TOOLING + (
    'competitive_bench.py', 'TerminalBenchWindow.swift', 'memory_public_history.py',
    'history_executable_identity.py')))


def prepare(args):
    case_name = getattr(args, 'case', CASE)
    phase_contract = contract(case_name)
    candidate = args.candidate.resolve()
    qualified = coordinator.candidate_preparation.verify(candidate)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    tooling = output / 'tooling/Tests'
    native = tooling / 'NativePerformance'
    native.mkdir(parents=True)
    for name in RUNTIME:
        shutil.copy2(coordinator.TESTS / name, tooling / name)
    for name in ('compare_history.py', 'compare_output.py', 'prepare.py', 'owned_defaults_cleanup.py'):
        shutil.copy2(coordinator.HERE / name, native / name)
    history_qpath = args.history_qualification.resolve()
    history = coordinator.read(history_qpath)
    coordinator.require(history['status'] == 'headlessly-qualified-public-history-tooling'
        and set(history['publicToolingSHA256']) == set(PUBLIC_TOOLING)
        and all(coordinator.sha(tooling / name) == value
                for name, value in history['publicToolingSHA256'].items()),
        'public history runtime differs from qualified sources')
    coordinator.require(type(history.get('childUmask')) is int and history['childUmask'] == CHILD_UMASK
        and history.get('verificationPolicy') == POLICY
        and set(history.get('publicHistoryLaunchSHA256', {})) == set(LAUNCH_TOOLING)
        and all(coordinator.sha(tooling / name) == value for name, value in history['publicHistoryLaunchSHA256'].items()),
        'public history child launch differs from qualified sources')
    coordinator.require(set(history['bindingApplicationSources']) == {
        'App/StandardKeybindings.swift', 'Kit/Sources/CmdyKit/KeybindingImport.swift',
        'Kit/Sources/CmdyKit/ConfigFile.swift'} and all(
            coordinator.sha(candidate / 'source' / name) == value
            for name, value in history['bindingApplicationSources'].items()),
        'candidate shortcut dispatcher or public store differs from headless qualification')
    helper = output / 'history-helper'
    shutil.copy2(history_qpath.parent / history['native']['binary'], helper)
    shutil.copy2(history_qpath.parent / history['native']['buildReceipt'], output / 'history-build.json')
    shutil.copy2(history_qpath, output / 'history-qualification.json')
    build = coordinator.read(output / 'history-build.json')
    coordinator.require(build['status'] == 'pass' and build['sourcesUnchanged'] is True
        and build['reaped'] is True and build['nativeHelperExecuted'] is False
        and build['binarySHA256'] == history['native']['binarySHA256'] == coordinator.sha(helper)
        and set(build['sourceSHA256']) == set(SOURCES)
        and all(coordinator.sha(tooling / name) == value for name, value in build['sourceSHA256'].items()),
        'history helper differs from compiled inputs')
    window = coordinator.read(args.window_qualification)
    window_helper = output / 'window-helper'
    shutil.copy2(Path(window['helper']['path']), window_helper)
    shutil.copy2(args.window_qualification, output / 'window-qualification.json')
    coordinator.require(window['status'] == 'passed-headless-native-pilot-required'
        and window['helper']['sha256'] == coordinator.sha(window_helper)
        and window['helper']['sourceSHA256'] == coordinator.sha(tooling / 'TerminalBenchWindow.swift'),
        'window helper differs from qualified source or binary')
    binaries = {name: coordinator.bench.binary_metadata(path) for name, path in (
        ('cmdy', candidate / qualified['binary']), ('ghostty', args.ghostty_bin.resolve()))}
    coordinator.require(binaries['cmdy']['sha256'] == qualified['signed_binary_sha256']
        and binaries['ghostty']['sha256'] == args.ghostty_sha256, 'app identity differs')
    marker = uuid.uuid4().hex[:16]
    spec = expectation(case_name, marker + '0' * 16)
    payload = output / (case_name + '.bin')
    payload.write_bytes(memory_payload(spec)); payload.chmod(0o600)
    interpreter = Path(sys.executable).resolve()
    command = [str(interpreter), '-B', str(native / 'compare_history.py'), 'record', '--output', str(output)]
    plan = dict(schemaVersion=3, kind='untimed-public-generated-history-pair', createdUTC=coordinator.utc(),
        output=str(output), candidate=str(candidate), candidateManifestSHA256=coordinator.sha(candidate / 'candidate.json'),
        nativeSourceKey=qualified['native_source_key'], nativeArchiveSHA256=qualified['native_archive_sha256'],
        binaries=binaries, profile='matched', powerSource=args.power_source, displayID=args.display_id,
        helper=str(window_helper), historyHelper=str(helper), python=str(interpreter),
        pythonSHA256=coordinator.sha(interpreter), generatedMarker=marker, case=case_name,
        payload=str(payload), payloadSHA256=coordinator.sha(payload), payloadBytes=payload.stat().st_size,
        publicAction=phase_contract['action'], publicShortcut=SHORTCUT,
        publicKeyEvent=shortcut_event(case=case_name, policy=POLICY), historyTransport=VERIFICATION_TRANSPORT,
        verificationPolicy=POLICY, verificationContract=phase_contract,
        childUmask=CHILD_UMASK,
        cases=[dict(workload='history-' + case_name, output=str(output / 'transport'), command=command)],
        minimumHumanIdleSeconds=300, maximumCaseSeconds=180, nativeLaunches=2,
        measuredSamples=0, warmups=0, performanceAdmission=False, qualifying=False,
        priorSamplesInherited=False, exclusions=[], foregroundAuthorized=True,
        requiredPermissions=['accessibilityTrusted', 'postEventAuthorized'],
        captureRequired=False, clipboardAccessed=False, appleEventsUsed=False,
        ownershipProofScope=FILE_PROOF_SCOPE, visualVisibilityVerified=False,
        scope='complete generated file export and owned cleanup only; no timing, memory or viewport admission',
        pins={str(path.relative_to(output)): coordinator.sha(path)
              for path in sorted(output.rglob('*')) if path.is_file()})
    coordinator.write_new(output / 'plan.json', plan)
    print(json.dumps(dict(status='prepared-no-native-actions', output=str(output), nativeLaunches=2)))


def check_plan(root):
    plan = coordinator.read(root / 'plan.json')
    policy = plan.get('verificationPolicy')
    phased = policy is not None
    case_name = plan['case']
    if phased: validate_contract(plan['verificationContract'], case_name)
    coordinator.require((policy == POLICY and plan['schemaVersion'] == 3 and plan['verificationContract'] == contract(case_name)
                         and plan['historyTransport'] == VERIFICATION_TRANSPORT) if phased
                        else plan['schemaVersion'] == 2 and case_name == CASE and 'verificationContract' not in plan,
                        'pilot verification policy differs')
    coordinator.require(plan['kind'] == 'untimed-public-generated-history-pair' and Path(plan['output']) == root
        and plan['ownershipProofScope'] == FILE_PROOF_SCOPE
        and plan['visualVisibilityVerified'] is False
        and case_name in CASES and plan['measuredSamples'] == 0 and plan['performanceAdmission'] is False
        and plan['captureRequired'] is False and plan['publicAction'] == selected_action(case_name if phased else None, policy)
        and type(plan.get('childUmask')) is int and plan['childUmask'] == CHILD_UMASK
        and plan['publicShortcut'] == SHORTCUT and plan['publicKeyEvent'] == shortcut_event(case=case_name if phased else None, policy=policy)
        and plan['minimumHumanIdleSeconds'] == 300,
        'pilot contract differs')
    coordinator.verify_inputs(root, plan, coordinator.sha(root / 'plan.json'))
    coordinator.require(coordinator.sha(Path(plan['python'])) == plan['pythonSHA256'], 'Python executable changed')
    expected = memory_payload(expectation(case_name, plan['generatedMarker'] + '0' * 16))
    coordinator.require(Path(plan['payload']).read_bytes() == expected
        and len(expected) == plan['payloadBytes'], 'generated payload changed')
    return plan


def native_json(directory, arguments):
    """Retain and reap each inspect/key helper even if the supervisor interrupts."""
    directory.mkdir(mode=0o700)
    record = dict(command=arguments, reaped=False)
    process = None
    try:
        with (directory / 'stderr.log').open('xb') as log:
            process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log)
            record['pid'] = process.pid
            raw, _ = process.communicate(timeout=10)
        coordinator.require(len(raw) <= 1024 * 1024, 'native response exceeds bound')
        value = json.loads(raw)
        coordinator.write_new(directory / 'response.json', value)
        coordinator.require(process.returncode == 0 and value.get('ok') is True, 'native public operation failed')
        return value
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill(); process.communicate()
                record['forcedKill'] = True
            record.update(exitCode=process.returncode, reaped=True)
        coordinator.write_new(directory / 'process.json', record)


def timebase():
    class Base(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    function = ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info
    function.argtypes = [ctypes.POINTER(Base)]; function.restype = ctypes.c_int
    value = Base()
    coordinator.require(function(ctypes.byref(value)) == 0 and value.numer > 0 and value.denom > 0
        and time.get_clock_info('perf_counter').implementation == 'mach_absolute_time()', 'native clock unavailable')
    return value.numer, value.denom


def check_layout(session, display, before=None):
    value = session.window()
    coordinator.bench.assert_grid(session.grid(), (120, 36))
    coordinator.require(value['windows'][0]['displayID'] == display
        and (before is None or value['windows'] == before['windows']), 'owned layout changed')
    return value


def check_drain(drain, plan):
    footer, response = expected_reply(36, 120, 0)
    coordinator.require(drain.get('payloadBytes') == plan['payloadBytes']
        and drain.get('footerHex') == footer.hex() and drain.get('responseHex') == response.hex()
        and drain.get('expectedResponseHex') == response.hex(), 'generated drain acknowledgement differs')
    for key in ('gridBefore', 'gridAfter'):
        coordinator.bench.assert_grid(drain[key], (120, 36))


def cleanup_result(public):
    """Report only this owned session; never discover or signal other apps."""
    session = public.session
    paths = [Path(session.temporary.name), Path(public.export_directory.name), Path(public.control_directory.name)]
    worker = session.worker_identity
    discovery_error = None
    if worker is None and session.process is not None and session.ready_path.is_file():
        # Launch can fail after the private ready file is written. Never signal
        # its PID unless both its current start identity and ancestry agree.
        try:
            coordinator.require(session.ready_path.stat().st_size <= 65536, 'private ready receipt exceeds bound')
            ready = coordinator.read(session.ready_path)
            pid = ready.get('workerPID', ready.get('pid'))
            if type(pid) is int and coordinator.bench.is_descendant(pid, session.app_pid):
                identity = coordinator.bench.process_identity(pid)
                if identity:
                    worker = session.worker_identity = (pid, identity)
            coordinator.require(worker is not None or type(pid) is int
                and coordinator.bench.process_identity(pid) is None, 'unproved live worker after partial launch')
        except Exception as error:
            discovery_error = str(error)
    try:
        public.close()
    finally:
        value = dict(status='failed', appPID=session.process.pid if session.process else None,
            appReaped=session.process is None or session.process.returncode is not None,
            workerPID=worker[0] if worker else None, workerStartIdentity=worker[1] if worker else None,
            originalWorkerAbsent=worker is None or coordinator.bench.process_identity(worker[0]) != worker[1],
            privatePaths=[dict(path=str(path), absent=not path.exists()) for path in paths])
        value['workerDiscoveryError'] = discovery_error
        value['status'] = 'pass' if discovery_error is None and value['appReaped'] and value['originalWorkerAbsent'] and all(
            row['absent'] for row in value['privatePaths']) else 'failed'
        coordinator.bench.atomic_json(session.directory / 'pilot-cleanup.json', value)
    coordinator.require(value['status'] == 'pass', 'owned process or private directory cleanup incomplete')
    return value


def record_one(root, plan, terminal):
    directory = root / 'transport' / terminal
    record = dict(terminal=terminal, status='failed', measuredSamples=0, performanceAdmission=False)
    public = None
    try:
        options = BenchOptions(Path(plan['binaries']['cmdy']['path']), Path(plan['binaries']['ghostty']['path']),
            payload=Path(plan['payload']), profile='matched', font_size=14, timeout=10, settle_seconds=0,
            tooling_dir=root / 'tooling/Tests')
        public = PublicHistorySession(options, Path(plan['helper']), terminal, directory,
            plan['case'], Path(plan['payload']), plan['generatedMarker'], Path(plan['python']), child_umask=plan['childUmask'],
            verification_policy=plan.get('verificationPolicy'))
        session = public.session
        session.launch()
        coordinator.require(session.worker_identity and session.ready['payloadSHA256'] == plan['payloadSHA256']
            and session.ready['payloadBytes'] == plan['payloadBytes']
            and not session.ready['ttyFlagsRaw'][1] & termios.OPOST, 'worker identity, raw TTY or payload differs')
        session.window(activate=True); session.place_window(120, 120); session.fit_grid((120, 36), allow_resize=True)
        layout = check_layout(session, plan['displayID'])
        drain = public.drain(sequence=0, timeout=8)
        coordinator.write_new(directory / 'generated-drain.json', drain)
        check_drain(drain, plan); check_layout(session, plan['displayID'], layout)
        requests = directory / 'native-requests'; requests.mkdir(mode=0o700)
        counter = 0
        def request(arguments):
            nonlocal counter
            counter += 1
            coordinator.require(arguments[1] in ('inspect', 'post-key'), 'capture or other native mode is forbidden')
            return native_json(requests / f'{counter:02d}-{arguments[1]}', arguments)
        boundary = dict(kind='untimed-drain', finishedMonotonicNS=drain['finishedMonotonicNS']) if plan.get('verificationPolicy') else None
        history = public.verify(Path(plan['historyHelper']), request, layout, timebase(), file_transport=True, verification_boundary=boundary)
        expected = validate_export_bytes(expected_bytes(public.expected), public.expected)
        coordinator.require(history['retainedRows'] == public.expected['logicalRows'] and history['normalizedSHA256'] == expected['normalizedSHA256'],
                            'full generated history differs')
        check_layout(session, plan['displayID'], layout)
        public.finish()
        record.update(status='valid-generated-file-transfer', historySHA256=coordinator.sha(directory / 'history-verification.json'))
    except BaseException as error:
        record['error'] = str(error)
        raise
    finally:
        # An outer interruption must not interrupt exact owned cleanup twice.
        prior = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            if public is not None:
                record['cleanup'] = cleanup_result(public)
        except BaseException as error:
            record.update(status='failed', cleanupError=str(error)); raise
        finally:
            for sig, handler in prior.items(): signal.signal(sig, handler)
            coordinator.bench.atomic_json(directory / 'pilot.json' if directory.exists()
                                          else root / f'failed-{terminal}.json', record)


def record(root):
    plan = check_plan(root)
    execution = coordinator.read(root / 'execution.json')
    coordinator.require(execution['status'] == 'running' and execution['pid'] == os.getppid(),
                        'native pilot must be a child of the active hardware-idle supervisor')
    initial = coordinator.activity_sample()
    coordinator.write_new(root / 'pair-activity-start.json', initial)
    coordinator.require_initial_quiet(initial, 300)
    initial_idle = initial['idleSeconds']
    started = initial['sessionReadFinishedMonotonicNS'] / 1e9
    (root / 'transport').mkdir(mode=0o700)
    def interrupted(_signal, _frame):
        raise InterruptedError('supervised native pilot interrupted')
    signal.signal(signal.SIGINT, interrupted); signal.signal(signal.SIGTERM, interrupted)
    for terminal in ('cmdy', 'ghostty'):
        coordinator.require(not coordinator.human_returned(initial_idle, time.monotonic() - started,
                                                           coordinator.idle_seconds()),
                            'session activity resumed; no next app launched')
        record_one(root, plan, terminal)
    print(json.dumps(dict(status='paired-generated-file-transfer-pass', measuredSamples=0)))


def audit_cleanup(root, require_pair=False):
    """Read-only failure cleanup check, including a partially launched pair."""
    launches = sorted((root / 'transport').glob('*/launch.json'))
    coordinator.require(not require_pair or len(launches) == 2, 'both owned launches are required')
    checked = []
    for path in launches:
        launch = coordinator.read(path)
        cleanup = coordinator.read(path.with_name('cleanup.json'))
        owned = coordinator.read(path.with_name('pilot-cleanup.json'))
        coordinator.require(owned['status'] == 'pass' and owned['appPID'] == cleanup['appPID'] == launch['appPID']
            and owned['appReaped'] is True and owned['originalWorkerAbsent'] is True
            and 'returncode' in cleanup and type(cleanup['returncode']) is int,
            'app or worker cleanup receipt incomplete')
        pids = [launch['appPID']] + ([owned['workerPID']] if owned.get('workerPID') else [])
        coordinator.require(not launch.get('workerPID') or launch['workerPID'] == owned['workerPID'],
                            'cleanup worker differs from recorded launch')
        coordinator.require(all(coordinator.bench.process_identity(pid) is None for pid in pids), 'owned PID still exists')
        binding = coordinator.read(path.with_name('public-history-binding.json'))
        expected_paths = [str(Path(launch['cwd']).parent), binding['temporaryDirectory'],
                          str(Path(binding['socketPath']).parent)]
        coordinator.require([item['path'] for item in owned['privatePaths']] == expected_paths,
                            'owned cleanup path set differs')
        for item in owned['privatePaths']:
            coordinator.require(item['absent'] is True and not Path(item['path']).exists(), 'owned temporary path remains')
        if launch['terminal'] == 'cmdy':
            domain = launch['defaultsDomain']
            coordinator.require(re.fullmatch(r'com\.cmdy\.bench\.[0-9a-f]{32}', domain) is not None,
                                'defaults domain is not the generated owned suite')
            exported, deleted = cleanup['defaultsExport'], cleanup['defaultsDelete']
            classify_owned_defaults_cleanup(domain, exported, deleted)
        for receipt in path.parent.glob('native-requests/*/process.json'):
            helper = coordinator.read(receipt)
            coordinator.require(helper['reaped'] is True and coordinator.bench.process_identity(helper['pid']) is None,
                                'native helper was not reaped')
        checked.extend(pids)
    return dict(status='owned-cleanup-pass', observedLaunches=len(launches), allRecordedPIDsAbsent=checked)


from history_executable_identity import same_executable_file


def audit_case(case):
    root = Path(case['output']).parent
    plan = check_plan(root)
    cleanup = audit_cleanup(root, require_pair=True)
    rows = []
    policy = plan.get('verificationPolicy'); phased = policy is not None
    for terminal in ('cmdy', 'ghostty'):
        directory = root / 'transport' / terminal
        item = coordinator.read(directory / 'pilot.json')
        history = coordinator.read(directory / 'history-verification.json')
        binding = coordinator.read(directory / 'public-history-binding.json')
        launch = coordinator.read(directory / 'launch.json')
        spec = expectation(plan.get('case', CASE), binding['nonce'])
        coordinator.require(spec['nonce'].startswith(plan['generatedMarker']) and binding['expectation'] == spec
            and item['status'] == 'valid-generated-file-transfer'
            and item['historySHA256'] == coordinator.sha(directory / 'history-verification.json')
            and history['expectation'] == spec and history['transfer']['terminal'] == terminal
            and history['transfer']['schemaVersion'] == (3 if phased else 2)
            and history['transfer']['nativeSpec'].get('proofScope') == FILE_PROOF_SCOPE
            and history['transfer']['expectation'] == spec
            and history['transfer']['nativeSpec']['executableSHA256'] == plan['binaries'][terminal]['sha256']
            and history['transfer']['nativeSpec']['pid'] == launch['appPID']
            and history['transfer']['nativeSpec']['workerPID'] == launch['workerPID']
            and history['transfer']['nativeSpec']['displayID'] == plan['displayID']
            and same_executable_file(history['transfer']['beforeOwner']['identity']['executable'], plan['binaries'][terminal])
            and history['transfer']['workerReady']['payloadSHA256'] == plan['payloadSHA256']
            and history['transfer']['workerReady']['payloadBytes'] == plan['payloadBytes']
            and history['transfer']['workerReady']['temporaryDirectory'] == binding['temporaryDirectory']
            and history['transfer']['workerReady']['socketPath'] == binding['socketPath']
            and launch['environment']['TMPDIR'] == binding['temporaryDirectory'] + '/'
            and launch['arguments'][0] == plan['binaries'][terminal]['path']
            and launch['fixtureCommand'] == binding['worker'] and binding['worker'][0] == plan['python']
            and binding['worker'][2] == str(root / 'tooling/Tests/history_export_worker.py')
            and binding['workerSHA256'] == coordinator.sha(root / 'tooling/Tests/history_export_worker.py'),
            'paired workload, worker or app identity differs')
        coordinator.require(coordinator.sha(Path(launch['config'])) == launch['configSHA256'],
            'public binding or retained config differs')
        coordinator.require(type(plan.get('childUmask')) is int and plan['childUmask'] == CHILD_UMASK
            and type(launch.get('childUmask')) is int and launch['childUmask'] == CHILD_UMASK
            and type(binding.get('childUmask')) is int and binding['childUmask'] == CHILD_UMASK,
            'paired public history child umask differs')
        validate_binding(terminal, Path(launch['config']), binding['shortcutBinding'],
                         case=spec['case'] if phased else None, policy=policy)
        if terminal == 'cmdy':
            coordinator.require(Path(launch['environment']['CMDY_CONFIG_DIR']) == Path(launch['config']).parent,
                                'CMDY launch does not select the qualified public shortcut store')
        check_drain(coordinator.read(directory / 'generated-drain.json'), plan)
        raw = read_retained_generated(directory / 'fixture/generated-export.bin', spec)
        validated = validate_transfer(history['transfer'], raw)
        coordinator.require(validated == history['transferValidation'], 'stored history summary differs')
        if phased:
            phase = coordinator.read(directory / 'fixture/verification-phase.json')
            prepared = coordinator.read(directory / 'fixture/prepared.json')
            boundary = dict(kind='untimed-drain', finishedMonotonicNS=coordinator.read(directory / 'generated-drain.json')['finishedMonotonicNS'])
            coordinator.require(policy == POLICY and binding.get('verificationPolicy') == POLICY
                and binding['verificationContract'] == contract(spec['case']) and binding['schemaVersion'] == 2
                and binding['transport'] == history['transport'] == VERIFICATION_TRANSPORT
                and history['schemaVersion'] == 2 and history['verificationPolicy'] == POLICY
                and binding['worker'][-2:] == ['--verification-policy', POLICY]
                and phase == history['verificationPhase'] == history['transfer']['verificationPhase']
                and prepared == history['transfer']['workerPrepared']
                and history['verificationReply']['verificationPhase'] == phase
                and history['verificationReply']['prepared'] == prepared and history['verificationReply']['mode'] == 'verified'
                and history['hostStartedMonotonicNS'] <= phase['startedMonotonicNS'] <= phase['finishedMonotonicNS'] <= history['hostFinishedMonotonicNS'],
                'paired verification phase binding differs')
            validate_phase(phase, spec, launch['workerPID'], prepared, boundary=boundary,
                timebase=(history['timebase']['numer'], history['timebase']['denom']))
        requests = directory / 'native-requests'
        coordinator.require(sorted(path.name for path in requests.iterdir())
                            == ['01-inspect', '02-post-key', '03-inspect'], 'native operation inventory differs')
        for name, value in (('01-inspect', history['before']), ('02-post-key', history['action']),
                            ('03-inspect', history['after'])):
            process = coordinator.read(requests / name / 'process.json')
            coordinator.require(coordinator.read(requests / name / 'response.json') == value
                and process['command'][:2] == [plan['historyHelper'], name.split('-', 1)[1]]
                and process['reaped'] is True and process['exitCode'] == 0 and not process.get('forcedKill'),
                'native helper response or lifecycle differs')
        finished = coordinator.read(directory / 'history-finish.json')
        worker = coordinator.read(directory / 'fixture/cleanup.json')
        if phased: validate_phase_cleanup(worker, phase, history['transfer']['workerArm'])
        coordinator.require(finished['workerExit']['pid'] == launch['workerPID'] == worker['pid']
            and finished['workerExit']['exited'] is True and worker['status'] == 'pass'
            and worker['reason'] == 'controller-finish' and worker['nonce'] == spec['nonce']
            and worker['unexpectedInputBytes'] == 0 and all(worker[key] is True for key in (
                'termiosRestored', 'fileFlagsRestored', 'terminalRestoreWritten', 'controlSocketRemoved')),
            'worker final cleanup differs')
        rows.append(dict(terminal=terminal, generatedHistory=validated['generatedHistory'], viewportVerified=False))
    coordinator.require(rows[0]['generatedHistory']['normalizedSHA256'] == rows[1]['generatedHistory']['normalizedSHA256'],
                        'paired full generated history differs')
    coordinator.require(len(cleanup['allRecordedPIDsAbsent']) == 4
        and len(set(cleanup['allRecordedPIDsAbsent'])) == 4, 'app and worker lifetimes are not distinct')
    return dict(measuredSamples=0, warmups=0, transfers=rows, cleanup=cleanup,
                files={str(path.relative_to(root / 'transport')): coordinator.sha(path)
                       for path in sorted((root / 'transport').rglob('*')) if path.is_file()})


def finish(root, plan):
    value = audit_case(plan['cases'][0])
    return dict(status='paired-generated-file-transfer-pass', qualifying=False, performanceAdmission=False,
                measuredSamples=0, goalMet=False, viewportVerified=False, osClipboardAccessed=False,
                visualVisibilityVerified=False, ownershipProofScope=FILE_PROOF_SCOPE,
                case=plan.get('case', CASE), transport=plan.get('historyTransport', TRANSPORT), transfers=value['transfers'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    prep = actions.add_parser('prepare')
    prep.add_argument('--candidate', type=Path, required=True)
    prep.add_argument('--history-qualification', type=Path, required=True)
    prep.add_argument('--window-qualification', type=Path, required=True)
    prep.add_argument('--ghostty-bin', type=Path, default=Path('/Applications/Ghostty.app/Contents/MacOS/ghostty'))
    prep.add_argument('--ghostty-sha256', required=True)
    prep.add_argument('--power-source', choices=('AC Power', 'Battery Power'), required=True)
    prep.add_argument('--display-id', type=int, default=1)
    prep.add_argument('--case', choices=CASES, default=CASE)
    for action in (prep, actions.add_parser('run'), actions.add_parser('record'), actions.add_parser('audit-cleanup')):
        action.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'prepare': prepare(args)
    elif args.action == 'record': record(args.output.resolve())
    elif args.action == 'audit-cleanup': print(json.dumps(audit_cleanup(args.output.resolve()), indent=2))
    else:
        check_plan(args.output.resolve())
        coordinator.run(args, audit=audit_case, untimed_finalizer=finish)


if __name__ == '__main__': main()
