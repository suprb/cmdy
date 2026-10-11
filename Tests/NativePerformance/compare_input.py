#!/usr/bin/env python3
"""Freeze the three single-pane input cases for the shared foreground supervisor."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

import compare_output as coordinator

TOOLING = ('input-latency-bench.py', 'input-latency-worker.py', 'editor-latency-worker.py',
    'competitive_bench.py', 'terminal_bench_worker.py', 'TerminalBenchWindow.swift',
    'TerminalInputObserver.swift', 'parity_gate.py', 'parity-policy.json')


def prepare(args):
    candidate = args.candidate.resolve()
    qualified = coordinator.candidate_preparation.verify(candidate)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    tooling = output / 'tooling/Tests'
    native = tooling / 'NativePerformance'
    native.mkdir(parents=True)
    for name in TOOLING:
        shutil.copy2(coordinator.TESTS / name, tooling / name)
    for name in ('compare_input.py', 'compare_output.py', 'prepare.py'):
        shutil.copy2(coordinator.HERE / name, native / name)
    helper, observer = output / 'window-helper', output / 'input-observer'
    shutil.copy2(args.window_helper.resolve(), helper)
    shutil.copy2(args.observer.resolve(), observer)
    coordinator.require(coordinator.sha(observer) == args.observer_sha256, 'qualified observer binary differs')
    coordinator.require(coordinator.sha(tooling / 'TerminalInputObserver.swift') == args.observer_source_sha256,
                        'qualified observer source differs')
    shutil.copy2(args.observer_receipt.resolve(), output / 'observer-qualification.json')
    receipt = coordinator.read(output / 'observer-qualification.json')
    coordinator.require(receipt.get('binarySHA256') == args.observer_sha256
                        and receipt.get('sourceSHA256') == args.observer_source_sha256
                        and receipt.get('exitCode') == 0 and receipt.get('waited') is True
                        and receipt.get('sourceUnchanged') is True,
                        'observer qualification does not bind the supplied source and binary')
    cmdy = candidate / qualified['binary']
    ghostty = args.ghostty_bin.resolve()
    binaries = {name: coordinator.bench.binary_metadata(path) for name, path in (('cmdy', cmdy), ('ghostty', ghostty))}
    coordinator.require(binaries['cmdy']['sha256'] == qualified['signed_binary_sha256'], 'candidate binary differs')
    coordinator.require(binaries['ghostty']['sha256'] == args.ghostty_sha256, 'comparator binary differs')
    cases = []
    for name, fixture, marker in (('local-row', 'raw-marker', 'local-row'),
                                  ('full-screen', 'raw-marker', 'full-screen'), ('editor', 'vim', 'local-row')):
        destination = output / ('input-' + name)
        command = [str(Path(sys.executable).resolve()), '-B', str(tooling / 'input-latency-bench.py'),
            '--cmdy-bin', str(cmdy), '--ghostty-bin', str(ghostty), '--helper', str(helper),
            '--observer', str(observer), '--terminals', 'cmdy,ghostty', '--grid', '120x36',
            '--profile', args.profile, '--fixture', fixture, '--marker-mode', marker,
            '--panes', '1', '--blocks', '6', '--samples', '40', '--settle-seconds', '3',
            '--output', str(destination)]
        cases.append(dict(workload=name, output=str(destination), command=command, displayID=args.display_id))
    plan = dict(schemaVersion=1, kind='three-single-pane-input-cases', createdUTC=coordinator.utc(), output=str(output),
        candidate=str(candidate), candidateManifestSHA256=coordinator.sha(candidate / 'candidate.json'),
        binaries=binaries, profile=args.profile, powerSource=args.power_source, displayID=args.display_id,
        helper=str(helper), cases=cases,
        pins={str(path.relative_to(output)): coordinator.sha(path) for path in sorted(output.rglob('*')) if path.is_file()},
        policySHA256=coordinator.sha(tooling / 'parity-policy.json'), measuredSamples=1440, warmups=0,
        minimumHumanIdleSeconds=300, maximumCaseSeconds=600, priorSamplesInherited=False, exclusions=[],
        foregroundAuthorized=True, requiredPermissions=['accessibilityTrusted', 'screenCaptureAuthorized', 'postEventAuthorized'],
        scope='synthetic key to WindowServer frame for local row, full screen and generated Vim edits')
    coordinator.write_new(output / 'plan.json', plan)
    print(coordinator.json.dumps(dict(status='prepared-no-GUI', output=str(output), cases=3)), flush=True)


def audit_case(case):
    root = Path(case['output'])
    summary = coordinator.read(root / 'summary.json')
    metadata = coordinator.read(root / 'metadata.json')
    coordinator.require(summary['valid'] is True and summary['displayID'] == case['displayID']
                        and metadata['requestedBlocks'] == 6
                        and metadata['samplesPerBlock'] == 40 and metadata['panes'] == 1,
                        'input case incomplete or counts differ')
    expected = {f'{block:02d}-{terminal}' for block in range(6) for terminal in ('cmdy', 'ghostty')}
    launches = list(root.glob('*/launch.json'))
    coordinator.require({path.parent.name for path in launches} == expected, 'input launches missing or duplicated')
    pids = set()
    for path in launches:
        launch = coordinator.read(path)
        observer = coordinator.read(path.with_name('observer-process.json'))
        status = coordinator.read(path.with_name('observer-status.json'))
        cleanup = coordinator.read(path.with_name('cleanup.json'))
        stopped = coordinator.read(path.with_name('fixture-stop.json'))
        samples = coordinator.read(path.parent / 'fixture/received.json')
        coordinator.require(observer['reaped'] is True and observer['returncode'] == 0
                            and not observer.get('interrupted') and not observer.get('forcedKill'),
                            'event observer did not finish normally and reap')
        coordinator.require(all(observer[name] == status[name] for name in ('command', 'returncode', 'stdout', 'stderr')),
                            'retained observer process and status differ')
        coordinator.require(stopped['complete'] is True and cleanup['appPID'] == launch['appPID']
                            and 'returncode' in cleanup and len(samples) == 40,
                            'input fixture or app cleanup incomplete')
        pids.update((launch['appPID'], launch['workerPID'], observer['pid']))
    for pid in pids:
        coordinator.require(coordinator.bench.process_identity(pid) is None, 'input-owned process still exists')
    return dict(measuredSamples=480, warmups=0, allRecordedPIDsAbsent=sorted(pids),
        files={str(path.relative_to(root)): coordinator.sha(path) for path in sorted(root.rglob('*')) if path.is_file()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    prep = commands.add_parser('prepare')
    for name in ('candidate', 'window-helper', 'observer', 'observer-receipt'):
        prep.add_argument('--' + name, type=Path, required=True)
    for name in ('observer-sha256', 'observer-source-sha256', 'ghostty-sha256'):
        prep.add_argument('--' + name, required=True)
    prep.add_argument('--ghostty-bin', type=Path, default=Path('/Applications/Ghostty.app/Contents/MacOS/ghostty'))
    prep.add_argument('--profile', choices=('matched', 'cmdy-defaults'), required=True)
    prep.add_argument('--power-source', choices=('AC Power', 'Battery Power'), required=True)
    prep.add_argument('--display-id', type=int, default=1)
    for command in (prep, commands.add_parser('run')):
        command.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args)
    else:
        coordinator.run(args, audit=audit_case, expected_metrics=6, completed_status='complete-native-input-evidence')


if __name__ == '__main__':
    main()
