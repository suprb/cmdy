"""Summarize only passed package observations; keep invalid records visible."""
import argparse
import collections
import hashlib
import json
import math
from pathlib import Path
import statistics

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input', type=Path, nargs='+', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--paired-only', action='store_true',
    help='Compare only blocks with passed baseline and candidate observations in the same run.')
args = parser.parse_args()
groups = collections.defaultdict(list)
rejected = []; inputs = []
def read(path): return json.loads(path.read_text())
def add(metric, unit, record, value):
    groups[(metric, unit, record['variant'])].append(
        dict(block=f"{root.resolve()}#{record['block']}", value=value))
for root in args.input:
    result = read(root / 'result.json')
    inputs.append(dict(path=str(root.resolve()), sha256=hashlib.sha256((root / 'result.json').read_bytes()).hexdigest(),
        binaries=result['binaries'], power=result['power'], native=result['native']))
    if result['status'] not in ('pass', 'partial'):
        rejected.append(dict(input=str(root), status=result['status'], reason='run did not finish with valid input integrity'))
        continue
    paired = {(record['family'], record['block']) for record in result['records']
        if all(any(other['family'] == record['family'] and other['block'] == record['block']
            and other['variant'] == variant and other['status'] == 'pass'
            for other in result['records']) for variant in ('baseline', 'candidate'))}
    for record in result['records']:
        family = record['family']; directory = root / record['name']
        if record['status'] != 'pass': rejected.append(dict(record, input=str(root.resolve()))); continue
        if args.paired_only and (family, record['block']) not in paired:
            rejected.append(dict(record, input=str(root.resolve()),
                exclusion='passed observation has no passed counterpart in this block'))
            continue
        if family in ('input', 'vim', 'busy'):
            for sample in read(directory / '00-cmdy/latency.json')['samples']:
                add(family, 'ms', record, sample['eventToFrameMs'])
        elif family == 'output':
            for sample in record['workloads']:
                if not sample['warmup']:
                    assert sample['payloadBytes'] == 3_000_000 and sample['responseHex'] == sample['expectedResponseHex']
                    add('output/' + sample['workload'], 'ms', record, sample['elapsedNS'] / 1e6)
        elif family == 'scroll':
            observation = read(root / 'runs' / record['name'] / 'observation.json')
            scale = observation['timebase']['numer'] / observation['timebase']['denom']
            for sample in observation['samples']:
                assert sample['status'] == 'valid' and sample['rowsMoved'] == 3
                add('scroll', 'ms', record,
                    (sample['stability']['first']['displayTicks'] - sample['event']['eventBeforeTicks']) * scale / 1e6)
        elif family == 'startup':
            observation = read(directory / 'observation/result.json')
            assert observation['diagnosticValid']
            add('startup/matched-profile', 'ms', record, observation['launchToFrameNS'] / 1e6)
        elif family == 'resize':
            observation = read(directory / 'observations/cmdy/event/result.json')
            assert observation['diagnosticValid']
            add('resize', 'ms', record, observation['requestToGeneratedCellViewportNS'] / 1e6)
        elif family == 'memory':
            for case in record['cases']:
                samples = case['samples']; name = case['case']
                last = samples[-1]['app']
                add('memory/' + name + '/RSS', 'MiB', record, last['residentBytes'] / 1048576)
                add('memory/' + name + '/footprint', 'MiB', record, last['physicalFootprintBytes'] / 1048576)
                add('memory/' + name + '/peak', 'MiB', record, last['lifetimeMaximumPhysicalFootprintBytes'] / 1048576)
                before, after = samples[1]['app'], samples[2]['app']
                assert before['cpuTimeUnit'] == after['cpuTimeUnit'] == 'nanoseconds'
                elapsed = (after['startedMonotonicNS'] - before['startedMonotonicNS']) / 1e9
                add('idleCPU/' + name, 'CPU ms/s', record,
                    sum(after[k] - before[k] for k in ('userTimeNS', 'systemTimeNS')) / 1e6 / elapsed)
summary = []
for (metric, unit, variant), rows in sorted(groups.items()):
    values = sorted(item['value'] for item in rows)
    summary.append(dict(metric=metric, unit=unit, variant=variant, samples=len(values), median=statistics.median(values),
        p95=values[math.ceil(.95 * len(values)) - 1], minimum=values[0], maximum=values[-1],
        blockMedians={block: statistics.median(item['value'] for item in rows if item['block'] == block)
            for block in sorted({item['block'] for item in rows})}))
result = dict(status='summarized-passed-observations', pairedOnly=args.paired_only,
    inputs=inputs, metrics=summary, rejected=rejected,
    limitations=['Small CMDY-only development comparison, not the paused Ghostty gate or a statistical superiority claim.',
        'Synthetic event to WindowServer pixels, not physical keyboard-to-photon latency.',
        'Startup and resize are independently validated development diagnostics; startup uses the matched profile.',
        'Trace-only observations are excluded from all timing aggregates.'])
with args.output.open('x') as stream: json.dump(result, stream, indent=2, sort_keys=True)
for row in summary: print(f"{row['metric']:40} {row['variant']:10} n={row['samples']:3} median={row['median']:.3f} p95={row['p95']:.3f} {row['unit']}")
