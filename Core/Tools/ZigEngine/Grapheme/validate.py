#!/usr/bin/env python3
"""Qualify pinned native cell-text code against an unchanged production Cell."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

p=argparse.ArgumentParser()
p.add_argument('--frozen-core',type=Path,required=True)
p.add_argument('--cache',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
args=p.parse_args()
here=Path(__file__).resolve().parent
core=here.parents[2]
out=args.output.resolve(); out.mkdir(parents=True,exist_ok=False)
sys.dont_write_bytecode = True
spec=importlib.util.spec_from_file_location('data',here/'generate.py')
data=importlib.util.module_from_spec(spec);spec.loader.exec_module(data)
sources=data.inputs(args.cache)

cases=[]
for n,line in enumerate(sources['ucd/auxiliary/GraphemeBreakTest.txt'].splitlines()):
    fields=line.split('#',1)[0].split()
    if fields: cases.append({'name':f'uax29-{n+1}','scalars':[int(v,16) for v in fields if v not in ('÷','×')]})
width=args.frozen_core/'Sources/CmdyCore/Generated/UnicodeWidthTables.swift'
section=width.read_text().split('static let zeroWidth:')[1].split('static let wide:')[0]
zero=[s for lo,hi in re.findall(r'\.init\(0x([0-9A-Fa-f]+), 0x([0-9A-Fa-f]+)\)',section)
      for s in range(int(lo,16),int(hi,16)+1)]
prefixes=[[0x41],[0x41,0x301],[0x41,0x200d],[0x1f469],[0x1f469,0x200d],
          [0x1f469,0x301,0x200d],[0x1f1e6],[0x1f1e6,0x1f1e7],
          [0x915,0x94d],[0x915,0x94d,0x200d],[0x1100],[0xac00],[0x600],[13],[10],[0x110000],[0]]
for scalar in zero:
    for n,prefix in enumerate(prefixes):
        cases.append({'name':f'zero-{scalar:x}-{n}','scalars':prefix+[scalar,0x301,0x41]})
for lead in [0,0xd800,0xdfff,0x110000,0xffffffff,0x41,0x1f469]:
    for extra in [[],[0xd800],[0x110000,0x301],[0x200d,0xd800,0x1f33e],[0,0x301],[0x200b,0x301]]:
        cases.append({'name':f'raw-{len(cases)}','scalars':[lead]+extra})
for seq in [[0x1f469,0x200d,0x200d,0x1f33e],[0x1f469,0x301,0x200d,0x1f33e],
            [0x1f1e6,0x1f1e7,0x1f1e8],[0x1f1e6,0x301,0x1f1e7],
            [0x915,0x94d,0x200c,0x915],[0x915,0x94d,0x200d,0x915],
            [0x1100,0x1161,0x11a8],[0xac00,0x11a8,0x11a9],[0x600,0x600,0x41,0x301]]:
    cases.append({'name':f'context-{len(cases)}','scalars':seq})
(out/'cases.json').write_text(json.dumps(cases,separators=(',',':')))
for name in ['cell_text.zig','grapheme_properties.zig']:
    shutil.copyfile(core/'Zig'/name,out/name)
(out/'testdata').mkdir()
shutil.copyfile(core/'Zig/testdata/grapheme_break_tests.bin',out/'testdata/grapheme_break_tests.bin')
for name in ['NativeProbe.zig','NativeProbe.h','SwiftReference.swift']:
    shutil.copyfile(here/name,out/name)
shutil.copyfile(args.frozen_core/'Sources/CmdyCore/Cell.swift',out/'Cell.swift')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
pins={str(f.relative_to(out)):sha(f) for f in out.rglob('*') if f.is_file()}
record={'status':'running','pins':pins,'zero_width_scalars':len(zero),'explicit_cases':len(cases),'commands':[]}
receipt=out/'receipt.json'
def run(name,cmd,stdin=None):
    item={'name':name,'command':list(map(str,cmd)),'started':time.time()}
    record['commands'].append(item);receipt.write_text(json.dumps(record,indent=2))
    with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
        child=subprocess.Popen(item['command'],stdin=stdin,stdout=stdout,stderr=stderr)
        item['pid']=child.pid;receipt.write_text(json.dumps(record,indent=2))
        try: item['exit_code']=child.wait(timeout=300)
        except subprocess.TimeoutExpired:
            child.kill();item['exit_code']=child.wait();item['timed_out']=True
        item['reaped']=True
    item['finished']=time.time()
    item['stdout_sha256']=sha(out/(name+'.stdout'));item['stderr_sha256']=sha(out/(name+'.stderr'))
    receipt.write_text(json.dumps(record,indent=2))
    if item['exit_code'] != 0:
        record['status']='fail';receipt.write_text(json.dumps(record,indent=2));raise SystemExit(name+' failed; see '+str(out))
run('native-build',['zig','build-lib','-static','-O','ReleaseSafe','-target','aarch64-macos.26.0.0','-lc',
    '--dep','cell_text','-Mroot='+str(out/'NativeProbe.zig'),'-Mcell_text='+str(out/'cell_text.zig'),
    '--cache-dir',out/'zig-cache','--global-cache-dir',out/'zig-global-cache','-femit-bin='+str(out/'libprobe.a')])
run('swift-build',['xcrun','swiftc','-O','-parse-as-library','-swift-version','5','-target','arm64-apple-macosx26.0',
    '-module-cache-path',out/'swift-cache','-import-objc-header',out/'NativeProbe.h',out/'Cell.swift',out/'SwiftReference.swift',out/'libprobe.a','-o',out/'probe'])
with (out/'cases.json').open('rb') as stdin:run('comparison',[out/'probe'],stdin)
assert all(sha(out/name)==value for name,value in pins.items())
record['status']='pass';receipt.write_text(json.dumps(record,indent=2))
print((out/'comparison.stdout').read_text())
