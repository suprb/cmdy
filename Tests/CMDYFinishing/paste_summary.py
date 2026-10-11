"""Audit CMDY-only paste blocks with the independent byte/frame evidence reader."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from paste_parity_evidence import checked_report, METRIC

def read(path): return json.loads(path.read_text())
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, nargs='+', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    blocks = []; values = []; identity = None; conditions = None
    for root in (p.resolve() for p in args.input):
        result = read(root / 'result.json')
        assert result['status'] == 'pass' and result['sourceAndExecutableIntegrity'] == 'pass'
        for name, digest in result['sourceSHA256'].items(): assert sha(root / 'tooling' / name) == digest
        for record in result['records']:
            assert record['family'] == 'paste' and record['status'] == 'pass'
            directory = root / 'runs' / record['name']
            run = read(directory / 'run.json'); report = read(directory / 'observation.json')
            launch = read(directory / 'launch.json'); binary = result['binaries'][record['variant']]
            if identity is None: identity = binary['sha256']; conditions = (result['power']['signature'], result['native'])
            assert identity == binary['sha256'] and conditions == (result['power']['signature'], result['native'])
            # The finishing wrapper is not a full parity manifest. Reconstruct
            # the per-run reader's context only from its retained receipts.
            metadata = dict(startedUTC=run['startedUTC'], finishedUTC=run['finishedUTC'], metric=METRIC,
                controllerPID=report['controllerPID'], displayID=1, profile=launch['profile'],
                binaries={'cmdy': binary, 'ghostty': binary},
                runtime={'python': {'path': launch['fixtureCommand'][0]}},
                toolingDirectory=str(root / 'tooling'), toolingSHA256=result['sourceSHA256'],
                powerBefore=result['power'], nativeBefore=result['native'])
            samples, _, _, _ = checked_report(directory, metadata, 'cmdy')
            assert len(samples) == 40
            values.extend(samples)
            blocks.append(dict(directory=str(directory), resultSHA256=sha(root / 'result.json'),
                observationSHA256=sha(directory / 'observation.json'), samples=40,
                medianMS=statistics.median(samples), p95MS=sorted(samples)[37]))
    values.sort()
    summary = dict(status='pass-independent-paste-audit', executableSHA256=identity, metric=METRIC,
        samples=len(values), blocks=blocks, medianMS=statistics.median(values),
        p95MS=values[math.ceil(.95 * len(values))-1], clipboardAccessed=False,
        conditions={'power': conditions[0], 'native': conditions[1]},
        limitations=['CMDY-only development evidence, not the paused competitive parity gate.',
            'Generated 64 KiB Unicode text through public Apple Events; synthetic dispatch to complete viewport.',
            'Per-run audit metadata reconstructed from retained finishing-wrapper receipts.'])
    with args.output.open('x') as stream: json.dump(summary, stream, indent=2, sort_keys=True)
    print(json.dumps({k: summary[k] for k in ('status','samples','medianMS','p95MS')}))

if __name__ == '__main__': main()
