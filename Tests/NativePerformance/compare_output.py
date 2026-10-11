#!/usr/bin/env python3
"""Freeze and run the existing five-case native output comparison on a normal app.

No builds, clipboard access or Apple Events. Native execution is explicit and
uses an outer foreground owner that stops when the session input clock resets.
"""
from __future__ import annotations

import argparse
from collections import Counter
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time

import prepare as candidate_preparation

HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
sys.path.insert(0, str(TESTS))
import competitive_bench as bench

WORKLOADS = ('unicode', 'continuous', 'lines', 'styled', 'source')
TOOLING = ('competitive_bench.py', 'competitive-bench.sh', 'terminal_bench_worker.py',
           'TerminalBenchWindow.swift', 'parity_gate.py', 'parity-policy.json')
ACTIVITY_CLOCK = 'CGEventSourceSecondsSinceLastEventType:combinedSessionState:anyInputEventType'
_event_source = None


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def utc():
    return datetime.now(timezone.utc).isoformat()


def write_new(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def parse_idle(data):
    values = []
    def visit(value):
        if isinstance(value, dict):
            if 'HIDIdleTime' in value:
                idle = value['HIDIdleTime']
                require(type(idle) is int and idle >= 0, 'invalid hardware idle clock')
                values.append(idle / 1e9)
            for child in value.values():
                if isinstance(child, (dict, list)):
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(plistlib.loads(data))
    require(len(values) == 1, 'unique hardware idle clock unavailable')
    return values[0]


def hardware_idle_seconds():
    return parse_idle(subprocess.check_output(
        ['/usr/sbin/ioreg', '-r', '-c', 'IOHIDSystem', '-a'], timeout=5))


def valid_seconds(value, name):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0,
            'invalid ' + name)
    return value


def idle_seconds():
    # Direct-to-PID synthetic keys reset both IOHID and CG's HID state on this
    # macOS version. They bypass the session stream, whose AnyInput clock still
    # detects real login-session input. No event tap or input contents are read.
    global _event_source
    if _event_source is None:
        library = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        _event_source = library.CGEventSourceSecondsSinceLastEventType
        _event_source.argtypes = [ctypes.c_int32, ctypes.c_uint32]
        _event_source.restype = ctypes.c_double
    value = valid_seconds(_event_source(0, 0xffffffff), 'session input clock')
    require(value <= time.monotonic() + 2, 'session input clock exceeds system uptime')
    return value


def activity_sample():
    hardware_start = time.monotonic_ns()
    hardware = valid_seconds(hardware_idle_seconds(), 'hardware idle clock')
    hardware_end = time.monotonic_ns()
    require(hardware <= hardware_end / 1e9 + 2, 'hardware idle clock exceeds system uptime')
    # Read the session clock last: slow ioreg must not stale the foreground
    # decision or become elapsed time attributed to this session sample.
    before = time.monotonic_ns()
    idle = idle_seconds()
    session_end = time.monotonic_ns()
    return {'clock': ACTIVITY_CLOCK, 'readStartedMonotonicNS': before,
            'sessionReadFinishedMonotonicNS': session_end,
            'readFinishedMonotonicNS': session_end, 'idleSeconds': idle,
            'hardwareReadStartedMonotonicNS': hardware_start,
            'hardwareReadFinishedMonotonicNS': hardware_end,
            'hardwareIdleSeconds': hardware}


def require_initial_quiet(sample, minimum):
    for name in ('idleSeconds', 'hardwareIdleSeconds'):
        valid_seconds(sample[name], name)
    require(min(sample['idleSeconds'], sample['hardwareIdleSeconds']) >= minimum,
            'human input is active; no app launched')


def human_returned(initial_idle, elapsed, current_idle):
    for name, value in (('initial session idle', initial_idle), ('elapsed time', elapsed),
                        ('current session idle', current_idle)):
        valid_seconds(value, name)
    return current_idle + 2 < initial_idle + elapsed


def stop_controller(process, receipt):
    process.terminate()
    try:
        code = process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        receipt['controllerForcedKill'] = True
        code = process.wait(timeout=10)
    receipt.update(exitCode=code, controllerReaped=True)


def prepare(args):
    workloads = tuple(getattr(args, 'workloads', WORKLOADS))
    require(workloads and len(set(workloads)) == len(workloads)
            and set(workloads) <= set(WORKLOADS), 'workloads must be distinct published cases')
    candidate = args.candidate.resolve()
    qualified = candidate_preparation.verify(candidate)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    tooling = output / 'tooling/Tests'
    tooling.mkdir(parents=True)
    native = tooling / 'NativePerformance'
    native.mkdir()
    for name in TOOLING:
        shutil.copy2(TESTS / name, tooling / name)
    for name in ('compare_output.py', 'prepare.py'):
        shutil.copy2(HERE / name, native / name)
    helper = output / 'window-helper'
    shutil.copy2(args.window_helper.resolve(), helper)
    cmdy = candidate / qualified['binary']
    ghostty = args.ghostty_bin.resolve()
    binaries = {name: bench.binary_metadata(path) for name, path in (('cmdy', cmdy), ('ghostty', ghostty))}
    require(binaries['cmdy']['sha256'] == qualified['signed_binary_sha256'], 'candidate binary mismatch')
    require(binaries['ghostty']['sha256'] == args.ghostty_sha256, 'comparator binary mismatch')
    pins = {str(path.relative_to(output)): sha(path) for path in sorted(output.rglob('*')) if path.is_file()}
    cases = []
    for workload in workloads:
        case = output / ('drain-' + workload)
        command = [str(Path(sys.executable).resolve()), '-B', str(tooling / 'competitive_bench.py'),
            '--cmdy-bin', str(cmdy), '--ghostty-bin', str(ghostty), '--profile', args.profile,
            '--workload', workload, '--bytes', '3000000', '--font-size', '14',
            '--columns', '120', '--rows', '36', '--display-id', str(args.display_id),
            '--blocks', '6', '--samples', '20', '--warmups', '1', '--first', 'cmdy',
            '--timeout', '60', '--settle-seconds', '3', '--idle-seconds', '3',
            '--between-samples-seconds', '0.25', '--window-helper', str(helper),
            '--output', str(case), '--no-restore-frontmost']
        cases.append({'workload': workload, 'output': str(case), 'command': command})
    plan = {'schemaVersion': 1, 'createdUTC': utc(), 'output': str(output),
        'candidate': str(candidate), 'candidateManifestSHA256': sha(candidate / 'candidate.json'),
        'binaries': binaries, 'profile': args.profile, 'powerSource': args.power_source,
        'displayID': args.display_id, 'helper': str(helper), 'pins': pins, 'cases': cases,
        'policySHA256': sha(tooling / 'parity-policy.json'), 'measuredSamples': 240 * len(workloads),
        'warmups': 12 * len(workloads), 'expectedMetrics': 2 * len(workloads),
        'minimumHumanIdleSeconds': 300, 'maximumCaseSeconds': 600,
        'priorSamplesInherited': False, 'exclusions': [], 'foregroundAuthorized': True,
        'scope': 'raw PTY write to validated DSR response; no visible-frame claim'}
    write_new(output / 'plan.json', plan)
    print(json.dumps({'status': 'prepared-no-GUI', 'output': str(output), 'cases': len(workloads)}), flush=True)


def verify_inputs(output, plan, plan_hash, full_candidate=False):
    require(sha(output / 'plan.json') == plan_hash, 'comparison plan changed')
    for name, expected in plan['pins'].items():
        require(sha(output / name) == expected, 'frozen comparison tool changed: ' + name)
    candidate = Path(plan['candidate'])
    require(sha(candidate / 'candidate.json') == plan['candidateManifestSHA256'], 'candidate manifest changed')
    if full_candidate:
        candidate_preparation.verify(candidate)
    for name, expected in plan['binaries'].items():
        require(bench.binary_metadata(Path(expected['path'])) == expected, 'binary or plist changed: ' + name)


def check_environment(plan):
    power = bench.power_snapshot()
    require(power['signature']['source'] == plan['powerSource'], 'actual power source differs from plan')
    native = bench.window_command(Path(plan['helper']), 'conditions')
    signature = bench.native_condition_signature(native)
    require(not signature['lowPowerMode'], 'low-power mode is active')
    return {'power': power, 'native': native}


def audit_case(case):
    root = Path(case['output'])
    manifest = read(root / 'manifest.json')
    require(manifest['state'] == 'complete' and manifest.get('restoreFrontmostManagedExternally') is True,
            'incomplete comparison or foreground ownership not delegated')
    samples = [read(path) for path in sorted(root.glob('runs/*/sample-*.json'))]
    require(len(samples) == 252 and sum(not item['warmup'] for item in samples) == 240,
            'missing or extra complete workload samples')
    require(all(item['status'] == 'valid' and item['payloadBytes'] == 3_000_000
                and item['responseHex'] == item['expectedResponseHex'] for item in samples),
            'invalid native sample')
    launches = list(root.glob('runs/*/launch.json'))
    require(len(launches) == 12, 'missing native launches')
    pids = set()
    for path in launches:
        launch, cleanup = read(path), read(path.with_name('cleanup.json'))
        pids.update((launch['appPID'], launch['workerPID']))
        require(cleanup['appPID'] == launch['appPID'] and 'returncode' in cleanup, 'missing owned cleanup')
    for pid in pids:
        require(bench.process_identity(pid) is None, 'recorded process still exists: ' + str(pid))
    files = {str(path.relative_to(root)): sha(path) for path in sorted(root.rglob('*')) if path.is_file()}
    return {'measuredSamples': 240, 'warmups': 12, 'allRecordedPIDsAbsent': sorted(pids), 'files': files}


def finish_untimed(output, plan, record, finalizer):
    """Functional pilots share supervision, but cannot enter the timing gate."""
    require(type(plan.get('measuredSamples')) is int and plan['measuredSamples'] == 0
            and type(plan.get('warmups')) is int and plan['warmups'] == 0
            and plan.get('performanceAdmission') is False,
            'untimed finalizer requires an explicitly unmeasured plan')
    result = finalizer(output, plan)
    require(result.get('performanceAdmission') is False and result.get('qualifying') is False
            and type(result.get('measuredSamples')) is int and result['measuredSamples'] == 0
            and result.get('goalMet') is False
            and not any(key in result for key in ('gateCounts', 'parityGateSHA256')),
            'untimed finalizer cannot claim performance admission')
    write_new(output / 'untimed-result.json', result)
    record.update(status='complete-untimed-functional-pilot', performanceAdmission=False,
                  qualifying=False, goalMet=False, measuredSamples=0,
                  untimedResultSHA256=sha(output / 'untimed-result.json'))


def finish_results(output, plan, record, expected_metrics, completed_status, untimed_finalizer=None):
    if untimed_finalizer is not None:
        finish_untimed(output, plan, record, untimed_finalizer)
        return
    command = [str(Path(sys.executable).resolve()), '-B', str(output / 'tooling/Tests/parity_gate.py')]
    for case in plan['cases']:
        command += ['--evidence', case['output']]
    command += ['--policy', str(output / 'tooling/Tests/parity-policy.json'),
        '--cmdy-sha256', plan['binaries']['cmdy']['sha256'],
        '--ghostty-sha256', plan['binaries']['ghostty']['sha256'], '--output', str(output / 'parity-gate.json')]
    gate = subprocess.run(command, capture_output=True, text=True)
    (output / 'parity-gate.log').write_text(gate.stdout + gate.stderr)
    require(gate.returncode in (0, 1) and (output / 'parity-gate.json').is_file(), 'parity reader failed')
    result = read(output / 'parity-gate.json')
    require(not result['invalidEvidence'], 'raw comparison rejected by independent gate')
    counts = dict(Counter(item['status'] for item in result['results']))
    require(counts.get('not-measured') == 140 - expected_metrics, 'native case coverage differs')
    record.update(status=completed_status, gateCounts=counts,
        goalMet=result['passed'], parityGateSHA256=sha(output / 'parity-gate.json'))


def run(args, audit=audit_case, expected_metrics=None, completed_status='complete-native-output-evidence',
        untimed_finalizer=None, checkpoint=None, collection_finalizer=None):
    output = args.output.resolve()
    plan = read(output / 'plan.json')
    require((checkpoint is None) == (collection_finalizer is None),
            'block collection requires both checkpoint and finalizer')
    if checkpoint is not None:
        require(untimed_finalizer is None and plan.get('collectionOnly') is True
                and plan.get('performanceAdmission') is False,
                'block collection cannot admit performance metrics')
    if expected_metrics is None:
        expected_metrics = plan.get('expectedMetrics', 10)
    require(output == Path(plan['output']) and not (output / 'execution.json').exists(), 'existing run cannot be overwritten')
    plan_hash = sha(output / 'plan.json')
    verify_inputs(output, plan, plan_hash, full_candidate=True)
    helper = Path(plan['helper'])
    probe = bench.window_command(helper, 'probe', 14)
    require(all(probe.get(name) is True for name in plan.get('requiredPermissions', ['accessibilityTrusted'])),
            'existing native authorization unavailable')
    require(any(display['displayID'] == plan['displayID'] for display in probe['displays']), 'selected display unavailable')
    initial_activity = activity_sample()
    require_initial_quiet(initial_activity, plan['minimumHumanIdleSeconds'])
    initial_idle = initial_activity['idleSeconds']
    original = probe['frontmostPID']
    record = {'status': 'running', 'startedUTC': utc(), 'pid': os.getpid(), 'planSHA256': plan_hash,
        'humanIdleBeforeSeconds': initial_idle, 'originalForegroundPID': original,
        'activityClock': ACTIVITY_CLOCK, 'initialActivity': initial_activity,
        'cases': [], 'exclusions': [], 'osClipboardAccessed': False}
    write_new(output / 'execution.json', record)
    active = None
    stop_requested = False
    returned = False
    activity_uncertain = False
    last_activity = initial_activity
    started = initial_activity['sessionReadFinishedMonotonicNS'] / 1e9
    def observe_idle(phase):
        nonlocal activity_uncertain, last_activity
        try:
            observation = activity_sample()
            observation.update(phase=phase, returned=human_returned(initial_idle,
                observation['readStartedMonotonicNS'] / 1e9 - started,
                observation['idleSeconds']))
            last_activity = observation
        except Exception as error:
            activity_uncertain = True
            observation = {'phase': phase, 'clock': ACTIVITY_CLOCK, 'valid': False,
                           'error': str(error), 'readFinishedMonotonicNS': time.monotonic_ns()}
            with (output / 'hardware-idle.jsonl').open('a') as stream:
                stream.write(json.dumps(observation) + '\n')
            raise
        # Preserve every monitor poll, including the quiet boundary before an
        # interruption. These clocks must never be inferred from wall time.
        with (output / 'hardware-idle.jsonl').open('a') as stream:
            stream.write(json.dumps(observation) + '\n')
        return observation['returned']
    def save():
        bench.atomic_json(output / 'execution.json', record)
    def stop(_signal, _frame):
        nonlocal stop_requested
        stop_requested = True
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        for case in plan['cases']:
            require(not stop_requested, 'interrupted')
            verify_inputs(output, plan, plan_hash)
            before = check_environment(plan)
            returned = observe_idle('before-' + case['workload'])
            require(not returned, 'human input resumed; no next app launched')
            item = {'workload': case['workload'], 'status': 'running', 'before': before, 'startedUTC': utc()}
            record['cases'].append(item)
            save()
            print('START ' + case['workload'], flush=True)
            with (output / (case['workload'] + '.log')).open('xb') as log:
                active = subprocess.Popen(case['command'], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
                item['pid'] = active.pid
                save()
                case_started = time.monotonic()
                while active.poll() is None:
                    time.sleep(1)
                    returned = observe_idle('during-' + case['workload'])
                    if stop_requested or returned or time.monotonic() - case_started > plan['maximumCaseSeconds']:
                        item['abortReason'] = ('human input resumed' if returned else
                                               'interrupted' if stop_requested else 'case wall-time limit')
                        stop_controller(active, item)
                        break
                code = active.wait()
                item.update(exitCode=code, controllerReaped=True)
            save()
            require(code == 0 and not returned and not stop_requested, 'native case stopped: ' + case['workload'])
            case_audit = audit(case)
            write_new(output / (case['workload'] + '-raw-audit.json'), case_audit)
            item.update(status='complete', finishedUTC=utc(), measuredSamples=case_audit['measuredSamples'],
                        warmups=case_audit['warmups'],
                        auditSHA256=sha(output / (case['workload'] + '-raw-audit.json')))
            verify_inputs(output, plan, plan_hash)
            item['after'] = check_environment(plan)
            if checkpoint is not None:
                returned = observe_idle('checkpoint-' + case['workload'])
                require(not returned and not stop_requested,
                        'input or interruption before block checkpoint')
                item['checkpointSHA256'] = checkpoint(output, plan, record, item, last_activity)
            save()
            print('COMPLETE ' + case['workload'], flush=True)
        if collection_finalizer is None:
            finish_results(output, plan, record, expected_metrics, completed_status, untimed_finalizer)
        else:
            result = collection_finalizer(output, plan)
            require(result.get('performanceAdmission') is False and result.get('goalMet') is False
                    and not any(key in result for key in ('gateCounts', 'parityGateSHA256')),
                    'collection finalizer cannot admit performance metrics')
            write_new(output / 'collection-result.json', result)
            record.update(status='complete-native-block-collection', performanceAdmission=False,
                          goalMet=False, collectionResultSHA256=sha(output / 'collection-result.json'))
        verify_inputs(output, plan, plan_hash, full_candidate=True)
    except BaseException as error:
        record.update(status='stopped-with-retained-evidence', error=str(error))
        if active is not None and active.poll() is None:
            stop_controller(active, record['cases'][-1])
        raise
    finally:
        try:
            final_returned = observe_idle('before-foreground-restore')
            record['humanInputReturned'] = returned or final_returned
            record['humanIdleAfterSeconds'] = last_activity['idleSeconds']
            record['finalActivity'] = last_activity
            record['activityClockValid'] = not activity_uncertain
            if not record['humanInputReturned'] and not activity_uncertain:
                bench.restore_frontmost(record, helper, original, managed=False)
            else:
                record['foregroundRestoreSkippedReason'] = (
                    'activity clock unavailable' if activity_uncertain else 'session input resumed')
                record['status'] = 'stopped-with-retained-evidence'
                require(not final_returned, 'session input resumed during finalization')
        except Exception as error:
            if activity_uncertain:
                record.update(activityClockValid=False, foregroundRestoreSkippedReason='activity clock unavailable',
                              activityClockError=str(error))
            record.update(status='stopped-with-retained-evidence', finalizationError=str(error))
            raise
        finally:
            record['finishedUTC'] = utc()
            save()
    print(json.dumps({'status': record['status'],
                      **({'gateCounts': record['gateCounts']} if 'gateCounts' in record else {})}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    prep = sub.add_parser('prepare')
    prep.add_argument('--candidate', type=Path, required=True)
    prep.add_argument('--window-helper', type=Path, required=True)
    prep.add_argument('--ghostty-bin', type=Path, default=Path('/Applications/Ghostty.app/Contents/MacOS/ghostty'))
    prep.add_argument('--ghostty-sha256', required=True)
    prep.add_argument('--profile', choices=('matched', 'cmdy-defaults'), required=True)
    prep.add_argument('--power-source', choices=('AC Power', 'Battery Power'), required=True)
    prep.add_argument('--display-id', type=int, default=1)
    prep.add_argument('--workloads', nargs='+', choices=WORKLOADS, default=WORKLOADS,
                      help='distinct remaining published cases; do not rerun a completed case for significance')
    for value in (prep, sub.add_parser('run')):
        value.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    (prepare if args.action == 'prepare' else run)(args)


if __name__ == '__main__':
    main()
