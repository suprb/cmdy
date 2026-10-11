#!/usr/bin/env python3
"""Build a native probe from a separately frozen candidate source revision."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import time

p=argparse.ArgumentParser()
p.add_argument('--source',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
p.add_argument('--optimize',default='ReleaseSafe',choices=['Debug','ReleaseSafe','ReleaseFast'])
args=p.parse_args()
out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
shutil.copytree(args.source,out/'zig-source')
shutil.copyfile(pathlib.Path(__file__).with_name('NativeReference.zig'),out/'NativeReference.zig')
inputs=sorted(path for path in (out/'zig-source').rglob('*') if path.is_file())+[out/'NativeReference.zig']
pins={str(path.relative_to(out)):hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
record={'status':'building','inputs':pins,'started':time.time(),'command':[
    'zig','build-exe','-O',args.optimize,'-lc','--cache-dir',str(out/'cache'),'--global-cache-dir',str(out/'global-cache'),
    '--dep','engine','-Mroot='+str(out/'NativeReference.zig'),'-Mengine='+str(out/'zig-source/terminal.zig'),
    '-femit-bin='+str(out/'native-reference')]}
(out/'build.json').write_text(json.dumps(record,indent=2))
with (out/'build.stdout').open('xb') as stdout,(out/'build.stderr').open('xb') as stderr:
    child=subprocess.Popen(record['command'],stdout=stdout,stderr=stderr);record['pid']=child.pid
    (out/'build.json').write_text(json.dumps(record,indent=2))
    try:record['exit_code']=child.wait(timeout=600)
    except subprocess.TimeoutExpired:child.kill();record['exit_code']=child.wait();record['timeout']=True
    record['reaped']=True
record['finished']=time.time();record['status']='pass' if record['exit_code']==0 else 'fail'
if record['status']=='pass':record['executable_sha256']=hashlib.sha256((out/'native-reference').read_bytes()).hexdigest()
record['stderr_sha256']=hashlib.sha256((out/'build.stderr').read_bytes()).hexdigest()
assert all(hashlib.sha256((out/path).read_bytes()).hexdigest()==sha for path,sha in pins.items())
(out/'build.json').write_text(json.dumps(record,indent=2))
print(json.dumps({key:record[key] for key in ['status','pid','exit_code','reaped']}))
raise SystemExit(record['exit_code']!=0)
