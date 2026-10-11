"""Prospective startup cohort contract. Pure file validation; no native actions."""
from pathlib import Path
import hashlib
import json
import random
import re

from startup_build import OBSERVER_SOURCES, PYTHON_SOURCES
from startup_grid_evidence import PROTOCOL

HERE = Path(__file__).resolve().parent
KIND = 'startup-full-viewport-campaign-v1'
GENERATION_POLICY = 'sole-target-generation; true-initial-grid-and-complete-ioctl-signal-trace; no-post-target-grid-change'
BLOCKS, SAMPLES, WARMUPS = 6, 40, 2
POLICY_SHA = 'f2b525aa70d86c41ab8809fd3017ea03ecbdccaf9a6a879051a997c928cfbfe5'
QUALIFIED = set(OBSERVER_SOURCES + PYTHON_SOURCES + ['startup_tests.swift',
    'startup_state_tests.swift', 'TERMINAL-STARTUP-BENCHMARKS.md', 'parity-policy.json'])
SOURCES = QUALIFIED | {'startup_campaign.py', 'startup_campaign_contract.py',
    'startup_parity_evidence.py', 'test_startup_campaign.py', 'TerminalBenchWindow.swift', 'parity_gate.py',
    'TERMINAL-STARTUP-CAMPAIGN.md',
    'NativePerformance/compare_output.py', 'NativePerformance/prepare.py'}

def require(value, message):
    if not value: raise ValueError(message)

def read(path):
    return json.loads(Path(path).read_text())

def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()

def write(path, value):
    with Path(path).open('x') as stream: json.dump(value, stream, indent=2); stream.write('\n')

def source_version_matches(name, frozen, current, inventory):
    # V5 requires a fresh qualification and full prospective collection. V4's
    # narrow reader-repair exceptions cannot authorize a changed worker protocol.
    if frozen == current: return True
    from startup_source_compatibility import completed_stop_extension_matches
    if completed_stop_extension_matches(name, frozen, current, inventory): return True
    from startup_source_compatibility import failure_metadata_extension_matches
    return failure_metadata_extension_matches(name, frozen, current, inventory)

def schedule(seed):
    require(type(seed) is int and 0 <= seed < 2**63, 'invalid schedule seed')
    initial = random.Random(seed).choice(['cmdy', 'ghostty'])
    rows = []
    for block in range(BLOCKS):
        first = initial if block % 2 == 0 else ('ghostty' if initial == 'cmdy' else 'cmdy')
        for terminal in (first, 'ghostty' if first == 'cmdy' else 'cmdy'):
            for sample in range(-WARMUPS, SAMPLES):
                rows.append(dict(index=len(rows), block=block, terminal=terminal, sample=sample,
                    warmup=sample < 0, name=f'{block:02d}-{terminal}-{sample+WARMUPS:02d}'))
    return rows

def check_plan(root, verify_files=True):
    root = Path(root).resolve(); plan = read(root / 'plan.json')
    require(plan['kind'] == KIND and plan['protocol'] == PROTOCOL and plan['prospective'] is True
        and plan['priorSamplesInherited'] is False and plan['blocks'] == BLOCKS
        and plan['samplesPerBlock'] == SAMPLES and plan['warmupsPerBlock'] == WARMUPS
        and plan['minimumInitialIdleSeconds'] == 300 and plan['minimumSettledNS'] == 200_000_000
        and plan['minimumCompleteContentNS'] == 1_000_000_000
        and plan['powerSource'] in ('AC Power', 'Battery Power')
        and plan['profile'] in ('matched', 'cmdy-defaults')
        and plan['generationPolicy'] == GENERATION_POLICY
        and plan['policySHA256'] == POLICY_SHA, 'startup prospective contract differs')
    expected = schedule(plan['seed'])
    require(len(plan['steps']) == len(expected), 'missing/extra startup launches')
    for row, wanted in zip(plan['steps'], expected, strict=True):
        require({key: row[key] for key in wanted} == wanted, 'startup order, warmup or sample index differs')
        require(row['input'] == f'inputs/{row["name"]}' and row['output'] == f'observations/{row["name"]}',
                'unsafe startup observation path')
    require(set(plan['sourceSHA256']) == SOURCES and set(plan['binaries']) == {'cmdy', 'ghostty'},
            'startup tooling/app inventory missing')
    q = read(root / 'tooling/qualification.json'); build = read(root / 'tooling/startup-observer-build.json')
    require(q['status'] == 'pass' and q['sourcesUnchanged'] is True and q['nativeObservationRun'] is False
        and q['applicationLaunches'] == 0 and q['pythonTests'] >= 40 and q['swiftChecks'] >= 64
        and set(q['sourceSHA256']) == QUALIFIED
        and all(c['exitCode'] == 0 and c['exitedAndReaped'] is True for c in q['commands'])
        and build['headlessQualified'] is True and build['nativeObservationRun'] is False
        and set(build['sourceSHA256']) == set(OBSERVER_SOURCES)
        and build['toolingSHA256'] == q['sourceSHA256']
        and build['binarySHA256'] == q['observerSHA256'] == plan['observerSHA256'],
        'startup native/source qualification differs')
    require(all(plan['sourceSHA256'][n] == q['sourceSHA256'][n] for n in QUALIFIED)
        and all(build['sourceSHA256'][n] == q['sourceSHA256'][n] for n in OBSERVER_SOURCES),
        'startup compiled and frozen tooling differ')
    if verify_files:
        inventory = hashlib.sha256(json.dumps(plan['sourceSHA256'], sort_keys=True,
            separators=(',', ':')).encode()).hexdigest()
        for name, digest in plan['sourceSHA256'].items():
            require(sha(root / 'tooling' / name) == digest
                and source_version_matches(name, digest, sha(HERE / name), inventory),
                    'startup source differs from trusted reader: ' + name)
        require(sha(root / 'tooling/startup-observer') == plan['observerSHA256'], 'startup observer changed')
        require(sha(root / 'tooling/parity-policy.json') == POLICY_SHA, 'startup policy changed')
        for path, digest in plan['frozenInputs'].items():
            require(sha(path) == digest, 'startup frozen input changed: ' + path)
    for terminal, binary in plan['binaries'].items():
        require(re.fullmatch('[0-9a-f]{64}', binary['sha256']) is not None
            and plan['frozenInputs'].get(binary['path']) == binary['sha256'], 'startup app not frozen')
    require(plan['frozenInputs'].get(plan['python']) == plan['pythonSHA256']
        and plan['frozenInputs'].get(plan['helper']) == plan['helperSHA256'], 'startup runtime/helper not frozen')
    package = Path(plan['package']); pkg = read(package / 'package.json')
    require(sha(package/'package.json') == plan['packageSHA256']
        and plan['frozenInputs'].get(str(package/'package.json')) == plan['packageSHA256']
        and str(Path(pkg['app'])/'Contents/MacOS/cmdy') == plan['binaries']['cmdy']['path']
        and pkg['executableSHA256'] == plan['binaries']['cmdy']['sha256']
        and sha(package/'source.tar.gz') == pkg['sourceArchiveSHA256']
        and all(re.fullmatch('[0-9a-f]{64}',pkg[k]) for k in ['nativeArchiveSHA256','nativeSourceKey','rawExecutableSHA256']),
        'startup packaged candidate/source identity differs')
    return plan
