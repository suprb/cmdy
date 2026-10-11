#!/usr/bin/env python3
"""Run one pinned headless engine probe, retaining partial output on failure."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import time

p=argparse.ArgumentParser()
p.add_argument('--probe',type=pathlib.Path,required=True)
p.add_argument('--input',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--timeout',type=int,default=600)
args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=False)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
record={'status':'running','probe':str(args.probe.resolve()),'input':str(args.input.resolve()),
        'probe_sha256':sha(args.probe),'input_sha256':sha(args.input),'started':time.time()}
receipt=args.output/'execution.json'
receipt.write_text(json.dumps(record,indent=2))
with args.input.open('rb') as stdin,(args.output/'states.jsonl').open('xb') as stdout,(args.output/'stderr.log').open('xb') as stderr:
    child=subprocess.Popen([str(args.probe.resolve())],stdin=stdin,stdout=stdout,stderr=stderr)
    record['pid']=child.pid
    receipt.write_text(json.dumps(record,indent=2))
    try:record['exit_code']=child.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        child.kill();record['exit_code']=child.wait();record['timeout']=True
    record['reaped']=True
record['finished']=time.time()
record['status']='pass' if record['exit_code']==0 else 'fail'
record['states_sha256']=sha(args.output/'states.jsonl')
record['stderr_sha256']=sha(args.output/'stderr.log')
assert sha(args.input)==record['input_sha256']
assert sha(args.probe)==record['probe_sha256']
receipt.write_text(json.dumps(record,indent=2))
print(json.dumps({key:record[key] for key in ['status','pid','exit_code','reaped']}))
raise SystemExit(record['exit_code']!=0)
