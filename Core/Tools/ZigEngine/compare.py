#!/usr/bin/env python3
"""Compare every requested state/event; incomplete runs never qualify."""
import argparse
import hashlib
import json
import pathlib

p=argparse.ArgumentParser()
p.add_argument('--input',type=pathlib.Path,required=True)
p.add_argument('--reference',type=pathlib.Path,required=True)
p.add_argument('--candidate',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
args=p.parse_args()
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def load(root):
    receipt=json.loads((root/'execution.json').read_text())
    assert receipt['status']=='pass' and receipt['reaped'] and receipt['exit_code']==0
    assert receipt['input_sha256']==sha(args.input)
    assert receipt['states_sha256']==sha(root/'states.jsonl')
    with (root/'states.jsonl').open() as stream:return [json.loads(line) for line in stream]
def differences(a,b,path=''):
    if type(a) != type(b) and not (type(a) in (int,float) and type(b) in (int,float)):
        yield {'path':path,'reference':a,'candidate':b};return
    if isinstance(a,dict):
        for key in sorted(set(a)|set(b)):
            if key not in a or key not in b:yield {'path':path+'/'+key,'reference':a.get(key,'MISSING'),'candidate':b.get(key,'MISSING')}
            else:yield from differences(a[key],b[key],path+'/'+key)
    elif isinstance(a,list):
        if len(a)!=len(b):yield {'path':path+'/length','reference':len(a),'candidate':len(b)}
        for i,(x,y) in enumerate(zip(a,b)):yield from differences(x,y,path+'/'+str(i))
    elif a!=b:yield {'path':path,'reference':a,'candidate':b}

requests=json.loads(args.input.read_text());reference=load(args.reference);candidate=load(args.candidate)
assert len(requests)==len(reference)==len(candidate)
failures=[];count=0;points=0
for request,a,b in zip(requests,reference,candidate):
    assert request['name']==a['name']==b['name']
    expected=[-1]+[i for i,s in enumerate(request['steps']) if s.get('checkpoint',True)]
    assert [p['step'] for p in a['checkpoints']]==[p['step'] for p in b['checkpoints']]==expected
    case_bad=False
    for x,y in zip(a['checkpoints'],b['checkpoints']):
        points+=1
        diff=list(differences(x['state'],y['state']))
        if diff:
            case_bad=True
            failures.append({'name':request['name'],'step':x['step'],'difference_count':len(diff),'first_differences':diff[:40]})
    if case_bad:count+=1
result={'status':'pass' if not failures else 'fail','cases':len(requests),'checkpoints':points,
        'different_cases':count,'different_checkpoints':len(failures),'input_sha256':sha(args.input),
        'reference_sha256':sha(args.reference/'states.jsonl'),'candidate_sha256':sha(args.candidate/'states.jsonl'),
        'failures':failures}
with args.output.open('x') as stream:json.dump(result,stream,indent=2)
print(json.dumps({k:result[k] for k in ['status','cases','checkpoints','different_cases','different_checkpoints']}))
raise SystemExit(bool(failures))
