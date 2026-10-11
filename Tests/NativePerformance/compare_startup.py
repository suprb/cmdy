#!/usr/bin/env python3
"""Freeze an untimed first-visible pair; only explicit run may launch or capture."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid

import compare_output as coordinator
import startup_recorder as recorder
from startup_build import OBSERVER_SOURCES, PYTHON_SOURCES
from startup_evidence import validate
from startup_grid import Witness
from startup_target_trace import validate as validate_worker_trace, PROTOCOL
from resize_calibration_evidence import validate_display_mode

RUNTIME = tuple(sorted(set(OBSERVER_SOURCES + PYTHON_SOURCES + [
    'startup_tests.swift', 'startup_state_tests.swift', 'TERMINAL-STARTUP-BENCHMARKS.md', 'parity-policy.json'])))
DISPLAY_FIELDS = ('displayID', 'displayMode', 'displayBounds', 'lowPowerMode', 'thermalState')
KIND = 'untimed-prearmed-first-visible-startup-pair'


def prepare(args):
    candidate = args.candidate.resolve()
    qualified = coordinator.candidate_preparation.verify(candidate)
    source = args.startup_qualification.resolve()
    qualification = coordinator.read(source / 'results.json')
    build = coordinator.read(source / 'startup-observer-build.json')
    coordinator.require(qualification['status'] == 'pass' and qualification['sourcesUnchanged'] is True
        and qualification['nativeObservationRun'] is False and qualification['applicationLaunches'] == 0
        and qualification['pythonTests'] >= 40 and qualification['swiftChecks'] >= 70
        and all(item['exitCode'] == 0 and item['exitedAndReaped'] is True for item in qualification['commands'])
        and set(qualification['sourceSHA256']) == set(RUNTIME)
        and build['headlessQualified'] is True and build['nativeObservationRun'] is False
        and set(build['sourceSHA256']) == set(OBSERVER_SOURCES)
        and build['toolingSHA256'] == qualification['sourceSHA256'], 'startup qualification differs')
    output = args.output.resolve(); output.mkdir(parents=True, mode=0o700, exist_ok=False)
    tooling = output / 'tooling/Tests'; native = tooling / 'NativePerformance'; native.mkdir(parents=True)
    for name, value in qualification['sourceSHA256'].items():
        coordinator.require(coordinator.sha(coordinator.TESTS / name) == value
            == coordinator.sha(source / 'tooling' / name), 'qualified startup source changed: ' + name)
        shutil.copy2(source / 'tooling' / name, tooling / name)
        coordinator.require(coordinator.sha(tooling / name) == value, 'startup copy changed')
    for name in ('compare_startup.py', 'compare_output.py', 'prepare.py'):
        shutil.copy2(coordinator.HERE / name, native / name)
    observer = output / 'startup-observer'; shutil.copy2(source / observer.name, observer)
    coordinator.require(coordinator.sha(observer) == qualification['observerSHA256'] == build['binarySHA256']
        and all(build['sourceSHA256'][name] == qualification['sourceSHA256'][name] for name in OBSERVER_SOURCES),
        'observer binary or compiled sources differ')
    shutil.copy2(source / 'results.json', output / 'startup-qualification.json')
    shutil.copy2(source / 'startup-observer-build.json', output / 'startup-observer-build.json')
    window = coordinator.read(args.window_qualification)
    helper = output / 'window-helper'; shutil.copy2(Path(window['helper']['path']), helper)
    shutil.copy2(coordinator.TESTS / 'TerminalBenchWindow.swift', tooling / 'TerminalBenchWindow.swift')
    shutil.copy2(args.window_qualification, output / 'window-qualification.json')
    coordinator.require(window['status'] == 'passed-headless-native-pilot-required'
        and coordinator.sha(helper) == window['helper']['sha256']
        and coordinator.sha(tooling / 'TerminalBenchWindow.swift') == window['helper']['sourceSHA256'],
        'window helper is not the qualified binary/source')
    review = coordinator.read(args.activity_review)
    coordinator.require(review['status'] == 'pass-no-open-findings'
        and review['inputs'][str(coordinator.HERE / 'compare_output.py')] == coordinator.sha(native / 'compare_output.py'),
        'supervisor differs from the reviewed activity guard')
    shutil.copy2(args.activity_review, output / 'activity-review.json')
    binaries = {name: coordinator.bench.binary_metadata(path) for name, path in (
        ('cmdy', candidate / qualified['binary']), ('ghostty', args.ghostty_bin.resolve()))}
    coordinator.require(binaries['cmdy']['sha256'] == qualified['signed_binary_sha256']
        and binaries['ghostty']['sha256'] == args.ghostty_sha256, 'app binary identity differs')
    power = coordinator.bench.power_snapshot()
    coordinator.require(power['signature']['source'] == args.power_source, 'actual preparation power source differs')
    recorder.write(output / 'preparation-power.json', power)
    python = Path(sys.executable).resolve()
    coordinator.require(coordinator.sha(python) == qualification['pythonRuntimeSHA256'], 'qualified Python runtime changed')
    token = uuid.uuid4().hex
    payload = output / 'first-generation.bin'; payload.write_bytes(Witness(token, 98, 29, 1, 1).frame_bytes()); payload.chmod(0o600)
    command = [str(python), '-B', str(native / 'compare_startup.py'), 'record', '--output', str(output)]
    plan = dict(schemaVersion=1, kind=KIND, protocol=PROTOCOL, output=str(output), createdUTC=coordinator.utc(),
        candidate=str(candidate), candidateManifestSHA256=coordinator.sha(candidate / 'candidate.json'),
        nativeSourceKey=qualified['native_source_key'], nativeArchiveSHA256=qualified['native_archive_sha256'],
        binaries=binaries, profile='matched', powerSource=args.power_source, displayID=args.display_id,
        helper=str(helper), observer=str(observer), observerBuild=str(output / 'startup-observer-build.json'),
        python=str(python), pythonSHA256=coordinator.sha(python), token=token,
        targetGrid=[98, 29], requiredGeneration=1, stabilityNanoseconds=1_000_000_000,
        publicInitialRequest=dict(cmdy='default', ghostty=dict(columns=96, rows=28, paddingX=10, paddingY=10)),
        initialRequestValidated=False, displayMetadata='fresh observer --probe-display before each owned preparation',
        payload=str(payload), payloadBytes=payload.stat().st_size, payloadSHA256=coordinator.sha(payload),
        cases=[dict(workload='startup-first-visible', output=str(output / 'observations'), command=command)],
        minimumHumanIdleSeconds=300, maximumCaseSeconds=130, nativeLaunches=2,
        measuredSamples=0, warmups=0, performanceAdmission=False, qualifying=False, priorSamplesInherited=False,
        exclusions=[], foregroundAuthorized=True, requiredPermissions=['screenCaptureAuthorized'],
        captureRequired=True, clipboardAccessed=False, appleEventsUsed=False, resizeAllowed=False,
        scope='first-generation viewport transport and owned cleanup only; raw diagnostic clocks cannot enter the performance gate',
        pins={str(path.relative_to(output)): coordinator.sha(path) for path in sorted(output.rglob('*')) if path.is_file()})
    recorder.write(output / 'plan.json', plan)
    print(json.dumps(dict(status='prepared-no-native-actions', output=str(output), nativeLaunches=2)))


def check_plan(root):
    plan = coordinator.read(root / 'plan.json')
    coordinator.require(plan['kind'] == KIND and plan['protocol'] == PROTOCOL and Path(plan['output']) == root and plan['profile'] == 'matched'
        and plan['targetGrid'] == [98, 29] and plan['requiredGeneration'] == 1
        and plan['stabilityNanoseconds'] == 1_000_000_000 and plan['resizeAllowed'] is False
        and plan['captureRequired'] is True and plan['minimumHumanIdleSeconds'] == 300
        and type(plan['measuredSamples']) is int and plan['measuredSamples'] == 0
        and plan['warmups'] == 0 and plan['performanceAdmission'] is False and plan['qualifying'] is False
        and plan['publicInitialRequest'] == dict(cmdy='default', ghostty=dict(columns=96, rows=28, paddingX=10, paddingY=10)),
        'startup pilot contract differs')
    coordinator.verify_inputs(root, plan, coordinator.sha(root / 'plan.json'))
    coordinator.require(coordinator.sha(Path(plan['python'])) == plan['pythonSHA256'], 'Python runtime changed')
    payload = Witness(plan['token'], 98, 29, 1, 1).frame_bytes()
    coordinator.require(Path(plan['payload']).read_bytes() == payload and len(payload) == plan['payloadBytes']
        and coordinator.sha(Path(plan['payload'])) == plan['payloadSHA256'], 'frozen first-generation workload differs')
    return plan


def probe_display(directory, plan):
    """Only called inside the explicit supervised native slot, before launch."""
    directory.mkdir(mode=0o700)
    process = None; receipt = dict(command=[plan['observer'], '--probe-display', str(plan['displayID'])], reaped=False)
    try:
        with (directory / 'stderr.log').open('xb') as log:
            process = subprocess.Popen(receipt['command'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log)
            receipt['pid'] = process.pid
            raw, _ = process.communicate(timeout=10)
        (directory / 'stdout.json').write_bytes(raw)
        coordinator.require(process.returncode == 0 and len(raw) <= 65536, 'native display probe failed')
        value = json.loads(raw)
        coordinator.require(value['schemaVersion'] == 1 and value['qualifying'] is False
            and value['displayID'] == plan['displayID'] and value['lowPowerMode'] is False
            and value['thermalState'] == 0, 'startup display/power probe differs')
        validate_display_mode(value['displayMode'])
        return value
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill(); process.communicate(); receipt['forcedKill'] = True
            receipt.update(exitCode=process.returncode, reaped=True)
        recorder.write(directory / 'process.json', receipt)


def initial_generation(raw, plan):
    ready, events = raw['workerReady'], raw['workerEvents']['events']
    coordinator.require(raw.get('syntheticTestFixture') is not True, 'synthetic evidence cannot be a native pilot')
    try:
        trace=validate_worker_trace(ready,raw['workerFinalEvents'],raw['cleanup']['worker'],ready['token'],plan['targetGrid'])
    except (ValueError,KeyError,TypeError) as error:
        raise RuntimeError('startup target worker trace differs: '+str(error)) from error
    coordinator.require(raw['protocol'] == PROTOCOL and trace['generatedViewports'] == 1
        and len(events) == 1 and events[0]['generation'] == 1
        and events[0]['payloadSHA256'] == plan['payloadSHA256']
        and events[0]['offeredBytes'] == events[0]['completedBytes'] == plan['payloadBytes']
        and raw['proofs'][raw['firstFrame']['proofSHA256']]['witness']['generation'] == 1,
        'target grid/generation differs; no corrected later frame can pass')


def record_one(root, plan, terminal, initial, started):
    directory = root / 'observations' / terminal; directory.mkdir(mode=0o700)
    item = dict(terminal=terminal, status='failed', qualifying=False, performanceAdmission=False)
    try:
        display = probe_display(directory / 'display-probe', plan)
        recorder.prepare(directory / 'inputs', terminal, Path(plan['binaries'][terminal]['path']), display,
                         profile='matched', token=plan['token'])
        coordinator.require(not coordinator.human_returned(initial, time.monotonic() - started, coordinator.idle_seconds()),
                            'session activity resumed; no app launched')
        recorder.record(directory / 'inputs/prepared.json', Path(plan['observer']), Path(plan['observerBuild']),
                        directory / 'observation')
        raw = coordinator.read(directory / 'observation/raw.json'); initial_generation(raw, plan)
        item.update(status='valid-first-generation-startup', rawSHA256=coordinator.sha(directory / 'observation/raw.json'))
    except BaseException as error:
        item['error'] = str(error); raise
    finally:
        # Preserve the actual first geometry even when the qualified recorder
        # rejects it. Unverified exited-worker self-reports remain labelled.
        path = directory / 'observation/raw.json'
        result_path = directory / 'observation/result.json'
        if result_path.is_file():
            result = coordinator.read(result_path)
            if 'nativeReceipt' in result: item['nativeReceipt'] = result['nativeReceipt']
            if 'nativeFailure' in result: item['nativeFailure'] = result['nativeFailure']
        if path.is_file() and path.stat().st_size <= 32 * 1024 * 1024:
            raw, receipt = recorder.native_receipt(path)
            item['nativeReceipt'] = receipt
            ready = raw.get('workerReady') or raw.get('unverifiedWorkerReady')
            if ready:
                item['actualInitialGrid'] = [ready.get('initialColumns'), ready.get('initialRows')]
                item['initialWorkerIdentityVerified'] = bool(raw.get('workerReady') and raw.get('workerIdentity'))
            item['observedGenerations'] = [event.get('generation') for event in raw.get('workerEvents', {}).get('events', [])]
        recorder.write(directory / 'pilot.json', item)


def record(root):
    plan = check_plan(root); execution = coordinator.read(root / 'execution.json')
    coordinator.require(execution['status'] == 'running' and execution['pid'] == os.getppid()
        and execution['planSHA256'] == coordinator.sha(root / 'plan.json'), 'startup must be a child of the active supervisor')
    sample = coordinator.activity_sample(); recorder.write(root / 'pair-activity-start.json', sample)
    coordinator.require_initial_quiet(sample, 300)
    started = sample['sessionReadFinishedMonotonicNS'] / 1e9
    (root / 'observations').mkdir(mode=0o700)
    def interrupted(*_): raise InterruptedError('supervised startup pilot interrupted')
    signal.signal(signal.SIGINT, interrupted); signal.signal(signal.SIGTERM, interrupted)
    for terminal in ('cmdy', 'ghostty'):
        record_one(root, plan, terminal, sample['idleSeconds'], started)


def defaults_proved(value, terminal, domain):
    coordinator.require(value.get('complete') is True, 'owned defaults cleanup incomplete')
    if terminal == 'ghostty':
        coordinator.require(value == dict(complete=True, status='not-applicable'), 'unexpected Ghostty defaults action')
        return
    coordinator.require(re.fullmatch(r'com\.cmdy\.startup\.[0-9a-f]{32}', domain) is not None
        and value['domain'] == domain and value['status'] in ('already-absent', 'exported-and-deleted'),
        'defaults suite is not the exact generated owner')
    commands = value['commands']
    expected = ['export'] if value['status'] == 'already-absent' else ['export', 'delete', 'export']
    coordinator.require(len(commands) == len(expected), 'defaults command inventory differs')
    for operation, item in zip(expected, commands):
        coordinator.require(item['arguments'] == ['/usr/bin/defaults', operation, domain] + (['-'] if operation == 'export' else [])
            and item['exitedAndReaped'] is True and type(item['exitCode']) is int, 'defaults operation or lifecycle differs')
    coordinator.require(commands[-1]['exitCode'] != 0 and re.search(r'Domain\s+' + re.escape(domain) + r'\s+does not exist',
        commands[-1]['stdout'] + commands[-1]['stderr']) is not None
        and all(item['exitCode'] == 0 for item in commands[:-1]), 'exact owned defaults absence not proved')


def audit_cleanup(root, require_pair=False):
    """Read-only; incomplete/missing native ownership never authorizes signalling."""
    checked = []; launches = 0
    directories = sorted((root / 'observations').glob('*'))
    coordinator.require(not require_pair or [p.name for p in directories] == ['cmdy', 'ghostty'], 'both startup observations required')
    for directory in directories:
        probe = directory / 'display-probe/process.json'
        if probe.is_file():
            value = coordinator.read(probe)
            coordinator.require(value['reaped'] is True and coordinator.bench.process_identity(value['pid']) is None,
                                'display helper cleanup incomplete')
            checked.append(value['pid'])
        observation = directory / 'observation'
        if not observation.exists(): continue  # Failure before recorder/owned launch.
        result = coordinator.read(observation / 'result.json')
        coordinator.require(result['observerReaped'] is True
            and coordinator.bench.process_identity(result['observerPID']) is None, 'observer cleanup incomplete')
        checked.append(result['observerPID'])
        raw = coordinator.read(observation / 'raw.json'); cleanup = raw['cleanup']; launch = raw['launch']
        coordinator.require(launch['api'] == 'posix_spawn' and launch['calls'] == 1 and launch['result'] == 0
            and cleanup['appPID'] == launch['pid'] and cleanup['appReaped'] is True
            and cleanup['workerGone'] is True and type(cleanup['childStatus']) is int,
            'owned app/worker cleanup missing or unproved')
        for pid in (cleanup['appPID'], cleanup['workerPID']):
            coordinator.require(type(pid) is int and pid > 0 and coordinator.bench.process_identity(pid) is None,
                                'recorded owned PID still exists')
            checked.append(pid)
        manifest = coordinator.read(directory / 'inputs/prepared.json')
        spec = coordinator.read(directory / 'inputs/spec.json')
        coordinator.require(manifest['terminal'] == directory.name and manifest['defaultsDomain'] == spec['environment']['CMDY_DEFAULTS_DOMAIN'],
                            'defaults preparation identity differs')
        defaults_proved(result['ownedDefaultsCleanup'], directory.name, manifest['defaultsDomain'])
        launches += 1
    coordinator.require(not require_pair or launches == 2, 'both owned launches are required')
    return dict(status='owned-cleanup-pass', observedLaunches=launches, allRecordedPIDsAbsent=checked,
                privateGeneratedEvidenceRetained=True)


def audit_case(case):
    root = Path(case['output']).parent; plan = check_plan(root)
    cleanup = audit_cleanup(root, require_pair=True); rows = []
    for terminal in ('cmdy', 'ghostty'):
        directory = root / 'observations' / terminal; inputs = directory / 'inputs'; observation = directory / 'observation'
        manifest = coordinator.read(inputs / 'prepared.json'); spec = coordinator.read(inputs / 'spec.json')
        raw = coordinator.read(observation / 'raw.json'); result = coordinator.read(observation / 'result.json')
        item = coordinator.read(directory / 'pilot.json'); display = coordinator.read(directory / 'display-probe/stdout.json')
        process = coordinator.read(directory / 'display-probe/process.json')
        coordinator.require(manifest['terminal'] == terminal and manifest['profile'] == plan['profile']
            and manifest['targetGrid'] == plan['targetGrid'] and Path(manifest['spec']) == inputs / 'spec.json'
            and manifest['specSHA256'] == coordinator.sha(inputs / 'spec.json')
            and spec['token'] == plan['token'] and spec['executable'] == plan['binaries'][terminal]['path']
            and spec['executableSHA256'] == plan['binaries'][terminal]['sha256']
            and spec['workerExecutable'] == plan['python'] and spec['workerExecutableSHA256'] == plan['pythonSHA256']
            and spec['displayID'] == plan['displayID'] and all(spec[name] == display[name] for name in DISPLAY_FIELDS)
            and process['command'] == [plan['observer'], '--probe-display', str(plan['displayID'])]
            and process['exitCode'] == 0 and not process.get('forcedKill')
            and coordinator.read(observation / 'prepared.json') == manifest
            and coordinator.sha(observation / 'observer-build.json') == coordinator.sha(Path(plan['observerBuild']))
            and result['observerExitCode'] == 0 and result['diagnosticValid'] is True
            and item['status'] == 'valid-first-generation-startup' and item['rawSHA256'] == coordinator.sha(observation / 'raw.json'),
            'paired preparation, native probe or app/observer identity differs')
        for name, value in manifest['preparationSources'].items():
            coordinator.require(coordinator.sha(root / 'tooling/Tests' / name) == value, 'startup preparation source changed')
        for name, value in spec['inputFiles'].items():
            coordinator.require(coordinator.sha(Path(name)) == value, 'startup generated input changed')
        options = recorder.BenchOptions(Path(spec['executable']), Path(spec['executable']), profile='matched', font_size=14)
        config = inputs / ('cmdy-config/config' if terminal == 'cmdy' else 'ghostty.config')
        coordinator.require(config.read_text() == recorder.terminal_config(terminal, options,
            (96, 28) if terminal == 'ghostty' else None, inputs / 'work'), 'public startup configuration differs')
        command = [plan['python'], '-B', str(inputs / 'tooling/startup_fixture.py'), '--directory',
                   str(inputs / 'worker'), '--token', plan['token'], '--timeout', '25', '--columns', '98', '--rows', '29']
        expected_files = [inputs / 'tooling/startup_fixture.py', inputs / 'tooling/startup_grid.py',
                          inputs / 'zsh/.zshenv', config, inputs / 'cmdy-config/app-update-state.json']
        coordinator.require(spec['arguments'] == ([] if terminal == 'cmdy' else
            ['--config-default-files=false', '--config-file=' + str(config)])
            and spec['cwd'] == str(inputs / 'work') and spec['appLog'] == str(inputs / 'app.log')
            and spec['workerDirectory'] == str(inputs / 'worker') and manifest['fixtureCommand'] == command
            and (inputs / 'zsh/.zshenv').read_text() == 'unsetopt RCS\nexec ' + shlex.join(command) + '\n'
            and set(spec['inputFiles']) == {str(p) for p in expected_files}
            and set(manifest['preparationSources']) == set(recorder.PREPARATION_SOURCES)
            and all(coordinator.sha(inputs / 'tooling' / name) == coordinator.sha(root / 'tooling/Tests' / name)
                    for name in ('startup_fixture.py', 'startup_grid.py')),
            'owned worker command, public launch arguments or generated source set differs')
        environment = spec['environment']
        base_keys = ('HOME', 'USER', 'LOGNAME', '__CF_USER_TEXT_ENCODING')
        expected_environment = recorder.launch_environment({k: environment[k] for k in base_keys if k in environment},
            inputs, inputs / 'work', manifest['defaultsDomain'])
        coordinator.require(environment == expected_environment, 'owned launch environment differs')
        validated = validate(raw, spec, manifest['specSHA256']); initial_generation(raw, plan)
        coordinator.require(all(result[name] == value for name, value in validated.items()), 'stored startup summary differs')
        rows.append(dict(terminal=terminal, display={name: spec[name] for name in DISPLAY_FIELDS},
            appIdentity=raw['appIdentity'], workerIdentity=raw['workerIdentity'], actualInitialGrid=item['actualInitialGrid'],
            sharedEnvironment={k: environment[k] for k in base_keys if k in environment},
            firstProofSHA256=raw['firstFrame']['proofSHA256'], rawSHA256=coordinator.sha(observation / 'raw.json')))
    coordinator.require(rows[0]['display'] == rows[1]['display'], 'paired display mode/bounds/power changed')
    coordinator.require(rows[0]['sharedEnvironment'] == rows[1]['sharedEnvironment'], 'paired base environment changed')
    lifetimes = [(row[k]['pid'], row[k]['startSeconds'], row[k]['startMicroseconds'])
                 for row in rows for k in ('appIdentity', 'workerIdentity')]
    coordinator.require(len(set(lifetimes)) == 4, 'paired app/worker lifetimes are not distinct')
    return dict(measuredSamples=0, warmups=0, observations=rows, cleanup=cleanup,
        files={str(p.relative_to(root / 'observations')): coordinator.sha(p)
               for p in sorted((root / 'observations').rglob('*')) if p.is_file()})


def finish(root, plan):
    value = audit_case(plan['cases'][0])
    return dict(status='paired-first-generation-startup-diagnostic-pass', qualifying=False, performanceAdmission=False,
        measuredSamples=0, goalMet=False, targetGrid=plan['targetGrid'], stabilityNanoseconds=plan['stabilityNanoseconds'],
        observations=value['observations'], osClipboardAccessed=False,
        scope='native diagnostic only; no startup latency distribution or strict performance admission')


def main():
    parser = argparse.ArgumentParser(description=__doc__); actions = parser.add_subparsers(dest='action', required=True)
    prep = actions.add_parser('prepare')
    prep.add_argument('--candidate', type=Path, required=True)
    prep.add_argument('--startup-qualification', type=Path, required=True)
    prep.add_argument('--window-qualification', type=Path, required=True)
    prep.add_argument('--activity-review', type=Path, required=True)
    prep.add_argument('--ghostty-bin', type=Path, default=Path('/Applications/Ghostty.app/Contents/MacOS/ghostty'))
    prep.add_argument('--ghostty-sha256', required=True)
    prep.add_argument('--power-source', choices=('AC Power', 'Battery Power'), required=True)
    prep.add_argument('--display-id', type=int, default=1)
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
