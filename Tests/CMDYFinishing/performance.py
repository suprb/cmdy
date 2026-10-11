"""CMDY-only, sequential before/after package measurements with retained failures.

Reuses the existing byte/frame oracles. This is not the paused Ghostty campaign
and does not weaken or claim admission to its six-block comparison gate.
"""
import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from types import SimpleNamespace
import uuid

TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TESTS))
sys.path.insert(0, str(TESTS / 'NativePerformance'))
import competitive_bench as bench
import paste_bench
import scroll_bench
import startup_recorder
import memory_bench
import memory_bench_payloads
import compare_resize
from resize_protocol import history
from resize import record as record_resize
from scroll_protocol import WheelCalibration

PRIOR = Path('/private/tmp/cmdy-goal-continuation-20260912-01')
HELPER = PRIOR / 'worker-qos-memory-ac-defaults-01/window_helper'
INPUT = PRIOR / 'worker-qos-input-ac-defaults-01/input-observer'
SCROLL = TESTS.parent / '.build/finishing-scroll-tools-04/scroll-observer'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--families', nargs='+', choices=['input', 'vim', 'busy', 'trace', 'output', 'paste', 'scroll', 'startup', 'resize', 'memory'], required=True)
    parser.add_argument('--blocks', type=int, default=3)
    parser.add_argument('--variants', nargs='+', choices=['baseline', 'candidate'], default=['baseline', 'candidate'])
    parser.add_argument('--paste-observer', type=Path,
        default=TESTS.parent / '.build/finishing-paste-tools-04/paste-observer')
    args = parser.parse_args()
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    tooling = root / 'tooling'; tooling.mkdir()
    for source in TESTS.iterdir():
        if source.is_file() and source.suffix in ('.py', '.swift', '.c', '.json'):
            shutil.copy2(source, tooling / source.name)
    runner_tooling = tooling / 'CMDYFinishing'; runner_tooling.mkdir()
    for source in Path(__file__).resolve().parent.iterdir():
        if source.is_file() and source.suffix in ('.py', '.swift'):
            shutil.copy2(source, runner_tooling / source.name)
    native_tooling = tooling / 'NativePerformance'; native_tooling.mkdir()
    for source in (TESTS / 'NativePerformance').glob('*.py'):
        shutil.copy2(source, native_tooling / source.name)
    binaries = {label: path.resolve() / 'Contents/MacOS/cmdy' for label, path in [('baseline', args.baseline), ('candidate', args.candidate)]}
    initial_power = bench.power_snapshot()
    initial_native = bench.window_command(HELPER, 'conditions')
    receipt = dict(status='running', scope='CMDY-only development checks; not Ghostty parity admission',
        binaries={name: bench.binary_metadata(path) for name, path in binaries.items()},
        power=initial_power, native=initial_native, clipboardAccessed=False, records=[],
        tools={str(p): bench.sha256(p) for p in [HELPER, INPUT, SCROLL]
            + ([args.paste_observer.resolve()] if 'paste' in args.families else [])},
        sourceSHA256={str(p.relative_to(tooling)): bench.sha256(p) for p in tooling.rglob('*') if p.is_file()})
    def save(): bench.atomic_json(root / 'result.json', receipt)
    def conditions():
        assert bench.power_snapshot()['signature'] == initial_power['signature'], 'power conditions changed'
        assert bench.native_condition_signature(bench.window_command(HELPER, 'conditions')) == bench.native_condition_signature(initial_native), 'native conditions changed'
    def verify_inputs():
        for name, digest in receipt['sourceSHA256'].items():
            assert bench.sha256(TESTS / name) == digest == bench.sha256(tooling / name), 'measurement source changed: ' + name
        for label, binary in binaries.items():
            assert bench.sha256(binary) == receipt['binaries'][label]['sha256'], 'measured executable changed: ' + label
        for path, digest in receipt['tools'].items():
            assert bench.sha256(Path(path)) == digest, 'measurement helper changed: ' + path
    def job(family, block, label):
        conditions()
        name = f'{family}-{block:02d}-{label}'
        print('START', name, flush=True)
        record = dict(name=name, family=family, block=block, variant=label, status='running')
        receipt['records'].append(record); save()
        binary = binaries[label]
        options = bench.BenchOptions(binary, binary, profile='cmdy-defaults', timeout=30, settle_seconds=3, tooling_dir=tooling)
        metadata = dict(toolingDirectory=str(tooling), runtime=dict(python=dict(path=str(Path(sys.executable).resolve()))),
            powerBefore=initial_power, nativeBefore=initial_native, displayID=1, binaries={'cmdy': receipt['binaries'][label]})
        def park(session):
            bench.atomic_json(session.directory / 'pointer-setup.json', bench.window_command(HELPER, 'park-pointer', session.app_pid))
        try:
            if family in ('input', 'vim', 'busy', 'trace'):
                command = [sys.executable, '-B', str(TESTS / 'input-latency-bench.py'), '--output', str(root / name),
                    '--cmdy-bin', str(binary), '--terminals', 'cmdy', '--helper', str(HELPER), '--observer', str(INPUT),
                    '--profile', 'cmdy-defaults', '--blocks', '1', '--samples', '12' if family == 'trace' else '40', '--settle-seconds', '3']
                if family in ('vim', 'trace'): command += ['--fixture', 'vim']
                if family == 'busy': command += ['--panes', '4']
                if family == 'trace': command += ['--diagnostic-frame-trace']
                with (root / (name + '.log')).open('x') as log:
                    child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                    try: code = child.wait(timeout=180)
                    finally:
                        if child.poll() is None: child.terminate(); child.wait(timeout=15)
                    record.update(command=command, exitCode=code, reaped=True)
                assert code == 0, 'input observer failed; retained raw log'
            elif family == 'output':
                record['workloads'] = []
                for workload in bench.WORKLOAD_PATTERNS:
                    payload = root / (name + '-' + workload + '.bin')
                    payload.write_bytes(bench.payload_bytes(workload, 3_000_000)); options.payload = payload
                    directory = root / 'runs' / (name + '-' + workload)
                    with bench.TerminalSession(options, HELPER, 'cmdy', directory, (120, 36)) as session:
                        session.launch(); session.window(activate=True); session.place_window(120, 120); session.fit_grid((120, 36), allow_resize=True)
                        time.sleep(3)
                        for index in range(3):
                            before = session.window()['windows']
                            item = session.request('drain', sequence=index, timeout=30)
                            bench.assert_grid(item['gridBefore'], (120, 36)); bench.assert_grid(item['gridAfter'], (120, 36))
                            assert session.window()['windows'] == before
                            item.update(workload=workload, warmup=index == 0, payloadSHA256=bench.sha256(payload))
                            record['workloads'].append(item)
                            bench.atomic_json(directory / f'sample-{index}.json', item)
                            time.sleep(.25)
            elif family == 'paste':
                observer = args.paste_observer.resolve()
                report, _ = paste_bench.run_owned(options, HELPER, observer, 'cmdy', root / 'runs' / name, uuid.uuid4().hex, metadata, prepare_window=park)
                record['observation'] = str(root / 'runs' / name / 'observation.json')
            elif family == 'scroll':
                directory = root / 'calibration' / name
                report, run = scroll_bench.run_owned(options, HELPER, SCROLL, 'cmdy', directory, uuid.uuid4().hex, metadata, prepare_window=park)
                raw = report['mapping']
                mapping = WheelCalibration('cmdy', options.profile, raw['upwardRawDelta'], raw['downwardRawDelta'], raw['rowsPerEvent'],
                    raw['units'], raw['isContinuous'], bench.sha256(tooling / 'scroll_protocol.py'), bench.sha256(binary),
                    run['canonicalConfigSHA256'], bench.sha256(directory / 'observation.json'), report['status'])
                mapping.validate(); record['calibration'] = asdict(mapping)
                report, _ = scroll_bench.run_owned(options, HELPER, SCROLL, 'cmdy', root / 'runs' / name, uuid.uuid4().hex, metadata, mapping, prepare_window=park)
                record['observation'] = str(root / 'runs' / name / 'observation.json')
            elif family == 'startup':
                tools = TESTS.parent / '.build/finishing-startup-tools-07'
                observer = tools / 'startup-observer'
                display = json.loads(subprocess.check_output([str(observer), '--probe-display', '1']))
                preparation = root / name / 'inputs'
                # The independently calibrated startup fixture is 98x29 at
                # matched line height. Do not substitute a later resized frame.
                record['profile'] = 'matched'
                startup_recorder.prepare(preparation, 'cmdy', binary, display, profile='matched')
                record['diagnostic'] = startup_recorder.record(preparation / 'prepared.json', observer,
                    tools / 'startup-observer-build.json', root / name / 'observation')
            elif family == 'memory':
                directory = root / name; directory.mkdir(); shutil.copytree(tooling, directory / 'tooling')
                payloads = memory_bench_payloads.create_payloads(directory / 'payloads')
                memory_args = SimpleNamespace(cmdy_bin=binary, ghostty_bin=binary, profile=options.profile, timeout=30,
                    settle_seconds=5, idle_cpu_seconds=5, after_seconds=[0, 1, 5], diagnostic_frame_trace=False,
                    history_helper=PRIOR / 'worker-qos-memory-ac-defaults-01/history_helper', window_helper=HELPER,
                    memory_helper=TESTS.parent / '.build/finishing-tools/memory-03', display_id=1,
                    post_sample_history=True, park_pointer_outside_window=True)
                reference = memory_bench.condition_signature(memory_bench.conditions(memory_args.history_helper))
                record['cases'] = [memory_bench.run_case(memory_args, directory, case, block, position, 'cmdy', reference)
                    for position, case in enumerate(payloads['cases'])]
            elif family == 'resize':
                directory = root / name; directory.mkdir()
                shutil.copytree(tooling, directory / 'tooling/Tests')
                nonce = uuid.uuid4().hex
                payload = directory / 'history.bin'; payload.write_bytes(history(nonce))
                tools = TESTS.parent / '.build/finishing-resize-tools'
                plan = dict(python=str(Path(sys.executable).resolve()), nonce=nonce, helper=str(HELPER),
                    binaries={name: receipt['binaries'][label] for name in ('cmdy', 'ghostty')},
                    displayID=1, historySHA256=bench.sha256(payload), observer=str(tools / 'resize-observer'),
                    observerBuild=str(tools / 'resize-observer-build.json'))
                record_resize(directory, plan, conditions, initial_native)
            conditions(); record['status'] = 'pass'
            print('PASS', name, flush=True)
        except Exception as error:
            record.update(status='fail', error=repr(error)); print('FAIL', name, repr(error), flush=True)
        finally: save()
    try:
        verify_inputs()
        for family in args.families:
            for block in range(1 if family == 'trace' else args.blocks):
                order = ['candidate'] if family == 'trace' else ['baseline', 'candidate'] if block % 2 == 0 else ['candidate', 'baseline']
                for label in (value for value in order if value in args.variants):
                    job(family, block, label)
            verify_inputs()
        receipt['sourceAndExecutableIntegrity'] = 'pass'
        receipt['status'] = 'pass' if all(r['status'] == 'pass' for r in receipt['records']) else 'partial'
    except BaseException as error:
        receipt.update(status='invalid', error=repr(error))
        raise
    finally: save()

if __name__ == '__main__': main()
