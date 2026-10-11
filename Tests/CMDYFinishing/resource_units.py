"""Independently check native CPU accounting against process_time on this host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
def sample(): return json.loads(subprocess.check_output([str(args.helper), str(os.getpid())]))
before = sample(); start = time.process_time_ns()
while time.process_time_ns() - start < 300_000_000: pass
elapsed = time.process_time_ns() - start
after = sample()
observed = sum(after[key] - before[key] for key in ('userTimeNS', 'systemTimeNS'))
assert after['cpuTimeUnit'] == 'nanoseconds' and .95 <= observed / elapsed <= 1.05
for key in ('user', 'system'):
    assert after[key + 'TimeNS'] == after[key + 'TimeTicks'] * after['timebaseNumer'] // after['timebaseDenom']
result = dict(status='pass', processTimeNS=elapsed, nativeTimeNS=observed, ratio=observed / elapsed,
    before=before, after=after, helperSHA256=hashlib.sha256(args.helper.read_bytes()).hexdigest())
with args.output.open('x') as stream: json.dump(result, stream, indent=2, sort_keys=True)
print(json.dumps({key: result[key] for key in ('status', 'processTimeNS', 'nativeTimeNS', 'ratio')}))
