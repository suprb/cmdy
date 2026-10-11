#!/usr/bin/env python3
"""Freeze and build the independent production Swift engine, without edits."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--frozen-core', type=pathlib.Path, required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
args = p.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
source = args.frozen_core.resolve() / 'Sources' / 'CmdyCore'
shutil.copytree(source, out / 'swift-source')
shutil.copyfile(pathlib.Path(__file__).with_name('SwiftReference.swift'), out / 'SwiftReference.swift')
inputs = sorted((out / 'swift-source').rglob('*.swift')) + [out / 'SwiftReference.swift']
pins = {str(path.relative_to(out)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
record = {'status': 'building', 'source': str(source), 'inputs': pins,
          'command': ['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '5',
                      '-target', 'arm64-apple-macosx26.0', '-module-name', 'FrozenCmdyReference',
                      '-module-cache-path', str(out / 'swift-cache'),
                      *map(str, inputs), '-o', str(out / 'swift-reference')],
          'started': time.time()}
(out / 'swift-build.json').write_text(json.dumps(record, indent=2))
with (out / 'swift-build.stdout').open('xb') as stdout, (out / 'swift-build.stderr').open('xb') as stderr:
    child = subprocess.Popen(record['command'], stdout=stdout, stderr=stderr)
    record['pid'] = child.pid
    (out / 'swift-build.json').write_text(json.dumps(record, indent=2))
    try:
        record['exit_code'] = child.wait(timeout=600)
    except subprocess.TimeoutExpired:
        child.kill()
        record['exit_code'] = child.wait()
        record['timed_out'] = True
    record['reaped'] = True
record['finished'] = time.time()
record['status'] = 'pass' if record['exit_code'] == 0 else 'fail'
record['stdout_sha256'] = hashlib.sha256((out / 'swift-build.stdout').read_bytes()).hexdigest()
record['stderr_sha256'] = hashlib.sha256((out / 'swift-build.stderr').read_bytes()).hexdigest()
if record['status'] == 'pass':
    record['executable_sha256'] = hashlib.sha256((out / 'swift-reference').read_bytes()).hexdigest()
assert all(hashlib.sha256((out / path).read_bytes()).hexdigest() == sha for path, sha in pins.items())
(out / 'swift-build.json').write_text(json.dumps(record, indent=2))
print(json.dumps({key: record[key] for key in ['status', 'exit_code', 'pid', 'reaped']}))
raise SystemExit(record['exit_code'] != 0)
