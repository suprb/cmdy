#!/usr/bin/env python3
"""Prepare fresh startup cohorts, then explicitly supervise isolated native runs."""
from pathlib import Path
import argparse
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
import uuid

from startup_campaign_contract import (BLOCKS, SAMPLES, WARMUPS, KIND, PROTOCOL, POLICY_SHA, GENERATION_POLICY,
    SOURCES, QUALIFIED, HERE, check_plan, read, sha, write, require, schedule)
import startup_recorder as recorder
import competitive_bench as bench
sys.path.insert(0, str(HERE / 'NativePerformance'))
import compare_output as activity

def prepare(args):
    root = args.output.resolve(); root.mkdir(mode=0o700, parents=True, exist_ok=False)
    tooling = root / 'tooling'; tooling.mkdir()
    qroot = args.qualification.resolve(); q = read(qroot / 'results.json')
    require(q['status'] == 'pass' and set(q['sourceSHA256']) == QUALIFIED, 'qualified observer required')
    for name in SOURCES:
        source = qroot / 'tooling' / name if name in QUALIFIED else HERE / name
        target = tooling / name; target.parent.mkdir(parents=True, exist_ok=True)
        require(sha(source) == sha(HERE / name), 'qualified source differs: ' + name)
        shutil.copy2(source, target)
    for source, name in [(qroot/'results.json','qualification.json'),
                         (qroot/'startup-observer-build.json','startup-observer-build.json'),
                         (qroot/'startup-observer','startup-observer')]: shutil.copy2(source, tooling/name)
    python = recorder.native_python_executable(); helper = args.window_helper.resolve()
    package = args.package.resolve(); pkg = read(package / 'package.json')
    candidate = Path(pkg['app'])/'Contents/MacOS/cmdy'; ghostty = args.ghostty.resolve()
    require(sha(candidate) == pkg['executableSHA256'] and sha(ghostty) == args.ghostty_sha256,
            'candidate/comparator identity differs')
    require(sha(package/'source.tar.gz') == pkg['sourceArchiveSHA256'], 'candidate source archive differs')
    # Metadata only; no capture, permission request, app launch or native event.
    with (root/'display.json').open('xb') as out:
        subprocess.run([str(tooling/'startup-observer'),'--probe-display',str(args.display_id)],
                       stdout=out, check=True, timeout=10)
    display = read(root/'display.json'); target = [args.columns,args.rows]
    seed = secrets.randbits(63); rows = schedule(seed); tokens = {}
    for row in rows:
        pair = (row['block'],row['sample'])
        token = tokens.setdefault(pair,uuid.uuid4().hex)
        row.update(input='inputs/'+row['name'],output='observations/'+row['name'],token=token)
        recorder.prepare(root/row['input'],row['terminal'],candidate if row['terminal']=='cmdy' else ghostty,
                         display,profile=args.profile,token=token,target_grid=tuple(target))
    files = [p for folder in [root,package,ghostty.parent.parent.parent] for p in folder.rglob('*') if p.is_file()]
    files += [python,helper,Path('/bin/zsh')]
    plan = dict(schemaVersion=1,kind=KIND,protocol=PROTOCOL,prospective=True,priorSamplesInherited=False,
        createdMonotonicNS=time.monotonic_ns(),blocks=BLOCKS,samplesPerBlock=SAMPLES,warmupsPerBlock=WARMUPS,
        seed=seed,steps=rows,profile=args.profile,powerSource=args.power_source,targetGrid=target,
        minimumInitialIdleSeconds=300,minimumSettledNS=200_000_000,minimumCompleteContentNS=1_000_000_000,
        displayID=args.display_id,display=display,python=str(python),pythonSHA256=sha(python),
        helper=str(helper),helperSHA256=sha(helper),observerSHA256=sha(tooling/'startup-observer'),
        policySHA256=POLICY_SHA,generationPolicy=GENERATION_POLICY,package=str(package),packageSHA256=sha(package/'package.json'),
        binaries={n:bench.binary_metadata(p) for n,p in [('cmdy',candidate),('ghostty',ghostty)]},
        sourceSHA256={n:sha(tooling/n) for n in sorted(SOURCES)},
        frozenInputs={str(p):sha(p) for p in sorted(set(files))})
    write(root/'plan.json',plan); check_plan(root)
    print(json.dumps(dict(status='prepared',launches=len(rows),measured=BLOCKS*SAMPLES*2,
        warmups=BLOCKS*WARMUPS*2,planSHA256=sha(root/'plan.json'))),flush=True)

def absent(pid):
    try: os.kill(pid,0)
    except ProcessLookupError: return True
    return False

def supervise(root):
    plan = check_plan(root); run = read(root/'run-process.json')
    require(run['pid'] == os.getppid() and run['planSHA256'] == sha(root/'plan.json'), 'owned supervisor parent differs')
    record = dict(status='waiting-for-quiet',pid=os.getpid(),parentPID=os.getppid(),
                  planSHA256=sha(root/'plan.json'),steps=[])
    def save():
        (root/'episode.json').write_text(json.dumps(record,indent=2)+'\n')
    def conditions():
        value = bench.window_command(Path(plan['helper']),'conditions')
        bench.native_condition_signature(value)
        require(value['lowPowerMode'] is False,'low power mode changed')
        return value
    child = None
    def interrupted(*_): raise InterruptedError('startup campaign interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    save()
    try:
        deadline=time.monotonic()+900
        while True:
            current=activity.activity_sample();record['latestActivity']=current;save()
            remaining=300-min(current['idleSeconds'],current['hardwareIdleSeconds'])
            if remaining<=0: break
            require(time.monotonic()<deadline,'no eligible idle slot within 15 minutes')
            print('Waiting for quiet:',round(remaining),'seconds',flush=True);time.sleep(min(30,remaining))
        record.update(initialActivity=current,initialPower=bench.power_snapshot(),initialNative=conditions(),
            machine=bench.window_command(Path(plan['helper']),'probe',14),
            hardware=bench.command_result(['/usr/sbin/sysctl','hw.model','hw.memsize','hw.physicalcpu',
                                          'hw.logicalcpu','machdep.cpu.brand_string']),status='running')
        power=record['initialPower']['signature'];require(power['source']==plan['powerSource'],'power differs')
        record['fontSHA256']=sha(record['machine']['font']['file']);save()
        initial=current['idleSeconds'];started=current['sessionReadFinishedMonotonicNS']
        def guard():
            current=activity.activity_sample()
            current['returned']=activity.human_returned(initial,(current['readStartedMonotonicNS']-started)/1e9,current['idleSeconds'])
            with (root/'activity.jsonl').open('a') as stream: stream.write(json.dumps(current)+'\n')
            require(not current['returned'],'session activity resumed; campaign excluded')
        for step in plan['steps']:
            guard();require(bench.power_snapshot()['signature']==power,'power changed')
            native=conditions();require(bench.native_condition_signature(native)==bench.native_condition_signature(record['initialNative']),
                                        'native conditions changed')
            if step['sample']==-WARMUPS: print('START block',step['block']+1,step['terminal'],flush=True)
            argv=[plan['python'],'-B',str(root/'tooling/startup_recorder.py'),'--record-diagnostic',
                str(root/step['input']/'prepared.json'),'--observer',str(root/'tooling/startup-observer'),
                '--observer-build',str(root/'tooling/startup-observer-build.json'),'--output',str(root/step['output'])]
            row=dict(name=step['name'],arguments=argv,startedMonotonicNS=time.monotonic_ns(),native=native)
            record['steps'].append(row);save()
            with (root/(step['name']+'.log')).open('xb') as out:
                child=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=out,stderr=subprocess.STDOUT)
                row['pid']=child.pid;save();deadline=time.monotonic()+65;next_guard=time.monotonic()+2
                while child.poll() is None:
                    time.sleep(.1)
                    if time.monotonic()>=next_guard:guard();next_guard=time.monotonic()+2
                    require(time.monotonic()<deadline,'startup controller timeout')
                row.update(exitCode=child.wait(),reaped=True,finishedMonotonicNS=time.monotonic_ns());save()
            output=root/step['output'];result=read(output/'result.json');raw=read(output/'raw.json')
            row.update(rawSHA256=sha(output/'raw.json'),resultSHA256=sha(output/'result.json'));save()
            cleanup=raw.get('cleanup',{})
            require(result.get('observerReaped') and result.get('ownedDefaultsCleanup',{}).get('complete')
                and cleanup.get('appReaped') and cleanup.get('workerGone'),'owned cleanup unproved; no next launch')
            pids=[child.pid,result['observerPID'],cleanup['appPID'],cleanup['workerPID']]
            require(all(absent(pid) for pid in pids),'owned process still present');row['ownedPIDsAbsent']=pids;save()
            require(row['exitCode']==0 and result['diagnosticValid'],'invalid launch; preserve campaign and stop')
            if step['sample']==SAMPLES-1:print('DONE block',step['block']+1,step['terminal'],flush=True)
        guard();record.update(finalPower=bench.power_snapshot(),finalNative=conditions(),
                             machineAfter=bench.window_command(Path(plan['helper']),'probe',14))
        require(record['finalPower']['signature']==power,'final power changed')
        check_plan(root);record.update(status='completed',finishedMonotonicNS=time.monotonic_ns());save()
    except BaseException as error:
        record.update(status='invalid',error=repr(error))
        if child is not None and child.poll() is None:
            child.terminate()
            try:child.wait(timeout=15)
            except subprocess.TimeoutExpired:child.kill();child.wait();record['forcedControllerKill']=True
        if child is not None and record['steps']:
            record['steps'][-1].update(exitCode=child.returncode,reaped=child.poll() is not None)
        raise
    finally:save()

def run(root):
    plan=check_plan(root)
    write(root/'run-process.json',dict(pid=os.getpid(),planSHA256=sha(root/'plan.json')))
    child=subprocess.Popen([plan['python'],'-B',str(root/'tooling/startup_campaign.py'),'supervise','--output',str(root)])
    try: code=child.wait()
    finally:
        if child.poll() is None: child.terminate();child.wait(timeout=25)
        write(root/'supervisor-process.json',dict(pid=child.pid,parentPID=os.getpid(),reaped=True,exitCode=child.returncode))
    if code:raise SystemExit(code)
    manifest=dict(schemaVersion=1,benchmarkKind=KIND,state='completed',planSHA256=sha(root/'plan.json'),
        episodeSHA256=sha(root/'episode.json'),activitySHA256=sha(root/'activity.jsonl'))
    write(root/'manifest.json',manifest)
    print(json.dumps(dict(status='completed-native-campaign',measured=BLOCKS*SAMPLES*2,warmups=BLOCKS*WARMUPS*2)),flush=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='action',required=True)
    prep=sub.add_parser('prepare')
    prep.add_argument('--package',type=Path,required=True);prep.add_argument('--qualification',type=Path,required=True)
    prep.add_argument('--window-helper',type=Path,required=True);prep.add_argument('--ghostty',type=Path,required=True)
    prep.add_argument('--ghostty-sha256',required=True);prep.add_argument('--display-id',type=int,default=1)
    prep.add_argument('--profile',choices=['matched','cmdy-defaults'],required=True)
    prep.add_argument('--power-source',choices=['AC Power','Battery Power'],required=True)
    prep.add_argument('--columns',type=int,required=True);prep.add_argument('--rows',type=int,required=True)
    for p in [prep,sub.add_parser('run'),sub.add_parser('supervise')]:p.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.action=='prepare':prepare(args)
    elif args.action=='run':run(args.output.resolve())
    else:supervise(args.output.resolve())

if __name__=='__main__':main()
