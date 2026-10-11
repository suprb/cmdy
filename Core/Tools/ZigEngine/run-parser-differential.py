#!/usr/bin/env python3
"""Compare exact parser event packets using frozen executables and byte input."""
import argparse
import hashlib
import json
import pathlib
import struct
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--reference', type=pathlib.Path, required=True)
p.add_argument('--candidate', type=pathlib.Path, required=True)
p.add_argument('--input', type=pathlib.Path, required=True)
p.add_argument('--cases', type=pathlib.Path, required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
args = p.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
record = {'status': 'running', 'input_sha256': sha(args.input), 'cases_sha256': sha(args.cases), 'runs': []}

def save():
    (out/'comparison.json').write_text(json.dumps(record, indent=2))

save()
for name, binary in [('reference', args.reference), ('candidate', args.candidate)]:
    run = {'name': name, 'binary': str(binary.resolve()), 'binary_sha256': sha(binary), 'started': time.time()}
    record['runs'].append(run)
    save()
    with args.input.open('rb') as stdin, (out/(name+'.bin')).open('xb') as stdout, (out/(name+'.stderr')).open('xb') as stderr:
        try:
            child = subprocess.Popen([str(binary.resolve())], stdin=stdin, stdout=stdout, stderr=stderr)
        except OSError as error:
            run['launch_error'] = str(error)
            record['status'] = 'fail'
            save()
            raise
        run['pid'] = child.pid
        save()
        try:
            run['exit_code'] = child.wait(timeout=300)
        except subprocess.TimeoutExpired:
            child.kill()
            run['exit_code'] = child.wait()
            run['timeout'] = True
        run['reaped'] = True
    run.update(finished=time.time(), output_sha256=sha(out/(name+'.bin')), stderr_sha256=sha(out/(name+'.stderr')))
    if run['exit_code'] != 0:
        record['status'] = 'fail'
        save()
        raise SystemExit(1)
    save()

def packets(name):
    data = (out/(name+'.bin')).read_bytes()
    cursor = 0
    while cursor < len(data):
        assert len(data)-cursor >= 5, 'Truncated parser output header'
        count = struct.unpack_from('<I', data, cursor)[0]
        cursor += 4
        assert cursor+count < len(data), 'Truncated parser event packet'
        yield data[cursor:cursor+count], data[cursor+count]
        cursor += count+1

reference, candidate = list(packets('reference')), list(packets('candidate'))
cases = json.loads(args.cases.read_text())
assert len(reference) == len(candidate) == len(cases), 'Incomplete parser case output'
different = []
for index, (left, right) in enumerate(zip(reference, candidate)):
    if left != right:
        different.append({'index': index, 'case': cases[index], 'reference_state': left[1], 'candidate_state': right[1],
                          'reference_event_hex': left[0].hex(), 'candidate_event_hex': right[0].hex()})
record.update(status='fail' if different else 'pass', cases=len(cases), different=len(different))
if different:
    (out/'differences.json').write_text(json.dumps(different, indent=2))
assert record['input_sha256'] == sha(args.input) and record['cases_sha256'] == sha(args.cases)
save()
print(json.dumps({key: record[key] for key in ['status', 'cases', 'different']}))
raise SystemExit(bool(different))
