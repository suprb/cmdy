#!/usr/bin/env python3
"""Freeze the public-file-export memory/idle-CPU comparison; no builds or GUI in prepare."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

import compare_output as coordinator
from memory_public_history import (MEMORY_TOOLING, TRANSPORT, VISUAL_MEMORY_TOOLING,
    VISUAL_MEMORY_TRANSPORT, VISUAL_MEMORY_SCOPE)
from history_export_phase import POLICY
from history_export_build import SOURCES


def prepare(args):
    phase_enabled = getattr(args, "post_sample_history", False)
    candidate = args.candidate.resolve()
    qualified = coordinator.candidate_preparation.verify(candidate)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    tooling = output / 'tooling/Tests'
    native = tooling / 'NativePerformance'
    native.mkdir(parents=True)
    for name in tuple(dict.fromkeys((VISUAL_MEMORY_TOOLING if phase_enabled else MEMORY_TOOLING) + ('parity_gate.py', 'parity-policy.json'))):
        shutil.copy2(coordinator.TESTS / name, tooling / name)
    for name in ('compare_memory.py', 'compare_output.py', 'prepare.py'):
        shutil.copy2(coordinator.HERE / name, native / name)
    helper_paths = {}
    for name in ('window_helper', 'memory_helper', 'history_helper'):
        destination = output / name
        shutil.copy2(getattr(args, name).resolve(), destination)
        helper_paths[name] = destination
    for name in ('memory_qualification', 'history_build'):
        shutil.copy2(getattr(args, name).resolve(), output / (name + '.json'))
    memory = coordinator.read(output / 'memory_qualification.json')
    history = coordinator.read(output / 'history_build.json')
    coordinator.require(memory['status'] == 'pass' and memory['ownedProcessReaped'] is True
        and memory['sourceUnchanged'] is True and memory['binarySHA256'] == coordinator.sha(helper_paths['memory_helper'])
        and memory['sourceSHA256'] == coordinator.sha(tooling / 'TerminalMemorySnapshot.c'),
        'memory helper differs from its qualified source or binary')
    coordinator.require(history['status'] == 'pass' and history['reaped'] is True and history['sourcesUnchanged'] is True
        and history['binarySHA256'] == coordinator.sha(helper_paths['history_helper'])
        and set(history['sourceSHA256']) == set(SOURCES)
        and all(coordinator.sha(tooling / name) == checksum for name, checksum in history['sourceSHA256'].items()),
        'public export helper differs from its compiled source or binary')
    cmdy = candidate / qualified['binary']
    ghostty = args.ghostty_bin.resolve()
    binaries = {name: coordinator.bench.binary_metadata(path) for name, path in (('cmdy', cmdy), ('ghostty', ghostty))}
    coordinator.require(binaries['cmdy']['sha256'] == qualified['signed_binary_sha256'], 'candidate binary differs')
    coordinator.require(binaries['ghostty']['sha256'] == args.ghostty_sha256, 'comparator binary differs')
    destination = output / 'memory'
    command = [str(Path(sys.executable).resolve()), '-B', str(tooling / 'memory_bench.py'),
        '--output', str(destination), '--cmdy-bin', str(cmdy), '--ghostty-bin', str(ghostty),
        '--profile', args.profile, '--blocks', '6', '--first', 'cmdy', '--settle-seconds', '5',
        '--idle-cpu-seconds', '5', '--after-seconds', '0', '1', '5', '--display-id', str(args.display_id)]
    for name, path in helper_paths.items():
        command.extend(('--' + name.replace('_', '-'), str(path)))
    if phase_enabled: command.append('--post-sample-history')
    plan = dict(schemaVersion=2 if phase_enabled else 1, kind='public-history-memory-and-idle-cpu', createdUTC=coordinator.utc(),
        output=str(output), candidate=str(candidate), candidateManifestSHA256=coordinator.sha(candidate / 'candidate.json'),
        binaries=binaries, profile=args.profile, powerSource=args.power_source, displayID=args.display_id,
        helper=str(helper_paths['window_helper']), cases=[dict(workload='memory', output=str(destination), command=command)],
        pins={str(path.relative_to(output)): coordinator.sha(path) for path in sorted(output.rglob('*')) if path.is_file()},
        policySHA256=coordinator.sha(tooling / 'parity-policy.json'), measuredSamples=216, warmups=0,
        minimumHumanIdleSeconds=300, maximumCaseSeconds=1800, priorSamplesInherited=False, exclusions=[],
        foregroundAuthorized=True, requiredPermissions=['accessibilityTrusted', 'postEventAuthorized'],
        scope='owned-app RSS, physical footprint and settled idle CPU with exact public retained history',
        historyTransport=VISUAL_MEMORY_TRANSPORT if phase_enabled else TRANSPORT, nativeLaunches=36)
    if phase_enabled:
        plan.update(verificationPolicy=POLICY, verificationScope=VISUAL_MEMORY_SCOPE, childUmask=63)
        plan['cases'][0]['postSampleHistory'] = True
    coordinator.write_new(output / 'plan.json', plan)
    print(coordinator.json.dumps(dict(status='prepared-no-GUI', output=str(output), nativeLaunches=36)), flush=True)


def audit_case(case):
    phase_enabled = case.get('postSampleHistory') is True
    coordinator.require(phase_enabled == ('--post-sample-history' in case.get('command', [])),
        'memory phase command and explicit case mode differ')
    root = Path(case['output'])
    manifest = coordinator.read(root / 'manifest.json')
    records = coordinator.read(root / 'records.json')
    expected_launches = 6 if 'blockIndex' in case else 36
    coordinator.require(manifest['status'] == 'complete' and manifest['schemaVersion'] == (5 if phase_enabled else 4)
                        and manifest['historyTransport'] == (VISUAL_MEMORY_TRANSPORT if phase_enabled else TRANSPORT) and manifest['finalHashesVerified'] is True
                        and len(records) == expected_launches, 'public memory comparison incomplete')
    if phase_enabled:
        coordinator.require(manifest.get('verificationPolicy') == POLICY and manifest.get('verificationScope') == VISUAL_MEMORY_SCOPE
            and type(manifest.get('childUmask')) is int and manifest['childUmask'] == 63, 'memory phase manifest policy differs')
    launches = list(root.glob('runs/*/launch.json'))
    coordinator.require(len(launches) == expected_launches and all(row['status'] == 'valid' for row in records), 'memory launches missing')
    pids = set()
    for path in launches:
        launch = coordinator.read(path)
        cleanup = coordinator.read(path.with_name('cleanup.json'))
        finished = coordinator.read(path.with_name('history-finish.json'))
        coordinator.require(cleanup['appPID'] == launch['appPID'] and 'returncode' in cleanup
                            and finished['workerExit']['pid'] == launch['workerPID']
                            and finished['workerExit']['exited'] is True, 'memory app or worker cleanup incomplete')
        pids.update((launch['appPID'], launch['workerPID']))
    for pid in pids:
        coordinator.require(coordinator.bench.process_identity(pid) is None, 'memory-owned process still exists')
    return dict(measuredSamples=sum(len(row['samples']) for row in records), warmups=0,
        allRecordedPIDsAbsent=sorted(pids),
        files={str(path.relative_to(root)): coordinator.sha(path) for path in sorted(root.rglob('*')) if path.is_file()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    prep = actions.add_parser('prepare')
    for name in ('candidate', 'window-helper', 'memory-helper', 'history-helper', 'memory-qualification', 'history-build'):
        prep.add_argument('--' + name, type=Path, required=True)
    prep.add_argument('--ghostty-bin', type=Path, default=Path('/Applications/Ghostty.app/Contents/MacOS/ghostty'))
    prep.add_argument('--ghostty-sha256', required=True)
    prep.add_argument('--power-source', choices=('AC Power', 'Battery Power'), required=True)
    prep.add_argument('--profile', choices=('matched', 'cmdy-defaults'), required=True)
    prep.add_argument('--display-id', type=int, default=1)
    prep.add_argument('--post-sample-history', action='store_true')
    for action in (prep, actions.add_parser('run')):
        action.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args)
    else:
        coordinator.run(args, audit=audit_case, expected_metrics=9, completed_status='complete-native-memory-evidence')


if __name__ == '__main__':
    main()
