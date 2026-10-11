"""Read-only startup cohort admission. Never execute code from an artifact."""
from pathlib import Path
import json
import math
import plistlib
import re
import shlex

from startup_campaign_contract import (BLOCKS, SAMPLES, WARMUPS, KIND, HERE,
    check_plan, read, sha, require)
from startup_evidence import validate, signed_ns, METRIC
from startup_grid import Witness
from startup_recorder import PREPARATION_SOURCES
from competitive_bench import BenchOptions, terminal_config, launch_environment, native_condition_signature

def hardware_proved(value):
    require(value['command']==['/usr/sbin/sysctl','hw.model','hw.memsize','hw.physicalcpu',
                               'hw.logicalcpu','machdep.cpu.brand_string']
        and type(value['returncode']) is int and value['returncode']==0
        and isinstance(value['stdout'],str) and value['stdout'].strip()
        and isinstance(value['stderr'],str) and not value['stderr'].strip(), 'startup hardware command failed or differs')

def defaults_proved(value, terminal, domain):
    require(value['complete'] is True, 'owned defaults cleanup incomplete')
    if terminal == 'ghostty':
        require(value['status'] == 'not-applicable', 'comparator defaults cleanup differs');return
    require(value['domain'] == domain and value['status'] in ('already-absent','exported-and-deleted'),
            'owned defaults identity differs')
    operations = (['export'] if value['status']=='already-absent' else
                  ['export','delete','export','delete'] if len(value['commands'])==4 else ['export','delete','export'])
    require(len(value['commands'])==len(operations),'defaults command inventory differs')
    for operation,item in zip(operations,value['commands'],strict=True):
        require(item['arguments']==['/usr/bin/defaults',operation,domain]+(['-'] if operation=='export' else [])
            and item['exitedAndReaped'] is True and type(item['exitCode']) is int,'defaults command differs')
    last=value['commands'][-1]
    if len(operations)==4:
        exported=value['commands'][2]
        require(all(v['exitCode']==0 for v in value['commands'][:3]) and not exported['stderr'].strip()
            and plistlib.loads(exported['stdout'].encode())=={}
            and last['exitCode']==1 and not last['stdout'].strip()
            and f'Domain ({domain}) not found.' in last['stderr']
            and 'Defaults have not been changed.' in last['stderr'], 'empty-export defaults absence not proved')
        return
    require(last['exitCode']!=0 and re.search(r'Domain\s+'+re.escape(domain)+r'\s+does not exist',
        last['stdout']+last['stderr']) is not None and all(v['exitCode']==0 for v in value['commands'][:-1]),
        'owned defaults absence not proved')

def validate_launch(root, plan, step, row):
    inputs=root/step['input'];output=root/step['output'];terminal=step['terminal']
    prepared=read(inputs/'prepared.json');spec=read(inputs/'spec.json')
    require((output/'raw.json').stat().st_size<=32*1024*1024,'unbounded startup raw evidence')
    raw=read(output/'raw.json');result=read(output/'result.json')
    require(prepared==read(output/'prepared.json') and prepared['terminal']==terminal
        and prepared['profile']==plan['profile'] and prepared['targetGrid']==plan['targetGrid']
        and prepared['spec']==str(inputs/'spec.json') and prepared['specSHA256']==sha(inputs/'spec.json')
        and spec['targetGrid']==plan['targetGrid'] and spec['token']==step['token']
        and spec['executable']==plan['binaries'][terminal]['path']
        and spec['executableSHA256']==plan['binaries'][terminal]['sha256']
        and spec['workerExecutable']==plan['python'] and spec['workerExecutableSHA256']==plan['pythonSHA256']
        and all(spec[k]==plan['display'][k] for k in ('displayID','displayBounds','displayMode','thermalState','lowPowerMode')),
        'startup launch preparation, profile, display or binary differs')
    require(set(prepared['preparationSources'])==set(PREPARATION_SOURCES)
        and all(v==plan['sourceSHA256'][k] for k,v in prepared['preparationSources'].items()),
        'startup preparation source differs')
    config=inputs/('cmdy-config/config' if terminal=='cmdy' else 'ghostty.config')
    grid=plan['targetGrid'];options=BenchOptions(Path(spec['executable']),Path(spec['executable']),profile=plan['profile'],font_size=14)
    require(config.read_text()==terminal_config(terminal,options,(grid[0]-2,grid[1]-1) if terminal=='ghostty' else None,inputs/'work'),
            'startup public configuration differs')
    command=[plan['python'],'-B',str(inputs/'tooling/startup_fixture.py'),'--directory',str(inputs/'worker'),
             '--token',step['token'],'--timeout','25','--columns',str(grid[0]),'--rows',str(grid[1])]
    expected_files=[inputs/'tooling/startup_fixture.py',inputs/'tooling/startup_grid.py',
                    inputs/'zsh/.zshenv',config,inputs/'cmdy-config/app-update-state.json']
    require(prepared['fixtureCommand']==command and (inputs/'zsh/.zshenv').read_text()=='unsetopt RCS\nexec '+shlex.join(command)+'\n'
        and spec['arguments']==([] if terminal=='cmdy' else ['--config-default-files=false','--config-file='+str(config)])
        and spec['cwd']==str(inputs/'work') and spec['appLog']==str(inputs/'app.log')
        and spec['workerDirectory']==str(inputs/'worker')
        and set(spec['inputFiles'])=={str(p) for p in expected_files}
        and all(sha(p)==v==plan['frozenInputs'].get(p) for p,v in spec['inputFiles'].items())
        and all(sha(inputs/'tooling'/n)==plan['sourceSHA256'][n] for n in ['startup_fixture.py','startup_grid.py']),
        'startup fixture bytes, shell or app arguments differ')
    domain=prepared['defaultsDomain'];environment=spec['environment']
    require(re.fullmatch(r'com\.cmdy\.startup\.[0-9a-f]{32}',domain) is not None
        and environment==launch_environment(environment,inputs,inputs/'work',domain), 'startup launch environment differs')
    require(raw.get('syntheticTestFixture') is not True,'synthetic startup evidence excluded')
    checked=validate(raw,spec,prepared['specSHA256'])
    events=raw['workerEvents']['events'];witness=Witness(step['token'],*grid,1,1);payload=witness.frame_bytes()
    import hashlib
    final=raw['workerFinalEvents']
    require(len(events)==1 and events[0]['generation']==1
        and final['events']==events and checked['workerTrace']['generatedViewports']==1
        and checked['workerTrace']['targetGrid']==grid
        and events[0]['offeredBytes']==events[0]['completedBytes']==len(payload)
        and events[0]['payloadSHA256']==hashlib.sha256(payload).hexdigest(), 'startup sole target generation differs')
    expected_command=[plan['python'],'-B',str(root/'tooling/startup_recorder.py'),'--record-diagnostic',
        str(inputs/'prepared.json'),'--observer',str(root/'tooling/startup-observer'),
        '--observer-build',str(root/'tooling/startup-observer-build.json'),'--output',str(output)]
    require(row['arguments']==expected_command and row['exitCode']==0 and row['reaped'] is True
        and result['observerReaped'] is True and result['observerExitCode']==0
        and raw['appIdentity']['parentPID']==result['observerPID']
        and row['rawSHA256']==sha(output/'raw.json')==result['nativeReceipt']['sha256']
        and row['resultSHA256']==sha(output/'result.json')
        and all(result[k]==v for k,v in checked.items())
        and read(output/'observer-build.json')==read(root/'tooling/startup-observer-build.json'),
        'startup controller, raw receipt or compiled observer binding differs')
    require(row['ownedPIDsAbsent']==[row['pid'],result['observerPID'],raw['cleanup']['appPID'],raw['cleanup']['workerPID']],
            'startup cleanup inventory differs')
    defaults_proved(result['ownedDefaultsCleanup'],terminal,domain)
    value=checked['launchToFrameNS']
    require(type(value) is int and value>0,'nonpositive startup timing')
    return value,raw,domain,{k:environment[k] for k in ('HOME','USER','LOGNAME','__CF_USER_TEXT_ENCODING') if k in environment}

def aggregate(rows):
    """Bounded exact cohort assembly; all warmups retained but never measured."""
    blocks={};warmups={};pairs={};domains=set();lifetimes=set();previous_native=previous_outer=0
    base_environment=None
    for step,row,value,raw,domain,environment in rows:
        require(domain not in domains,'startup defaults domain reused');domains.add(domain)
        if base_environment is None:base_environment=environment
        require(environment==base_environment,'startup shared base environment changed')
        require(type(row['startedMonotonicNS']) is int and previous_outer<row['startedMonotonicNS']<row['finishedMonotonicNS'],
                'startup outer launches overlap or reverse')
        previous_outer=row['finishedMonotonicNS']
        start=signed_ns(raw['launch']['beforeTicks'],0,raw['timebase'])
        end=signed_ns(raw['cleanup']['worker']['finishedTicks'],0,raw['timebase'])
        require(previous_native<start<end,'startup native launches overlap or reverse');previous_native=end
        for name in ['appIdentity','workerIdentity']:
            identity=raw[name];key=(identity['pid'],identity['startSeconds'],identity['startMicroseconds'])
            require(key not in lifetimes,'startup process lifetime reused');lifetimes.add(key)
        pair=(step['block'],step['sample']);joined=pairs.setdefault(pair,{})
        require(step['terminal'] not in joined,'duplicate startup sample/app');joined[step['terminal']]=step['token']
        target=warmups if step['warmup'] else blocks
        target.setdefault(step['block'],{}).setdefault(step['terminal'],[]).append(value)
    require(len(pairs)==BLOCKS*(SAMPLES+WARMUPS)
        and all(set(p)=={'cmdy','ghostty'} and p['cmdy']==p['ghostty'] for p in pairs.values())
        and len({p['cmdy'] for p in pairs.values()})==len(pairs),'startup nonce/pair inventory differs')
    for groups,count in [(blocks,SAMPLES),(warmups,WARMUPS)]:
        require(set(groups)==set(range(BLOCKS)) and all(set(p)=={'cmdy','ghostty'}
            and all(len(v)==count for v in p.values()) for p in groups.values()),'startup sample/warmup inventory differs')
    return blocks

def _load_startup_evidence(directory,expected_binaries=None):
    root=Path(directory).resolve();plan=check_plan(root);manifest=read(root/'manifest.json');episode=read(root/'episode.json')
    require(manifest['schemaVersion']==1 and manifest['benchmarkKind']==KIND and manifest['state']=='completed'
        and manifest['planSHA256']==episode['planSHA256']==sha(root/'plan.json')
        and manifest['episodeSHA256']==sha(root/'episode.json') and manifest['activitySHA256']==sha(root/'activity.jsonl')
        and episode['status']=='completed' and not episode.get('forcedControllerKill'), 'startup campaign incomplete or changed')
    binaries={n:v['sha256'] for n,v in plan['binaries'].items()}
    require(expected_binaries is None or expected_binaries==binaries,'startup pinned binaries differ')
    parent=read(root/'run-process.json');supervisor=read(root/'supervisor-process.json')
    require(parent['pid']==episode['parentPID']==supervisor['parentPID'] and supervisor['pid']==episode['pid']
        and supervisor['reaped'] is True and supervisor['exitCode']==0
        and parent['planSHA256']==manifest['planSHA256'],'startup supervisor binding differs')
    initial=episode['initialActivity'];activity=list(map(json.loads,(root/'activity.jsonl').read_text().splitlines()))
    require(min(initial['idleSeconds'],initial['hardwareIdleSeconds'])>=300 and activity
        and plan['createdMonotonicNS']<initial['readStartedMonotonicNS'],'startup initial idle/preparation order differs')
    previous=initial['sessionReadFinishedMonotonicNS']
    for row in activity:
        elapsed=(row['readStartedMonotonicNS']-initial['sessionReadFinishedMonotonicNS'])/1e9
        require(previous<=row['readStartedMonotonicNS']<=row['sessionReadFinishedMonotonicNS']
            and row['returned'] is False and math.isfinite(row['idleSeconds'])
            and row['idleSeconds']+2>=initial['idleSeconds']+elapsed,'startup activity returned or clock reversed')
        previous=row['sessionReadFinishedMonotonicNS']
    power=episode['initialPower']['signature'];native=native_condition_signature(episode['initialNative']);machine=episode['machine']
    require(power==episode['finalPower']['signature'] and power['source']==plan['powerSource'] and power['settings']
        and native==native_condition_signature(episode['finalNative']) and native['lowPowerMode'] is False
        and machine['ok'] is True and machine['screenCaptureAuthorized'] is True
        and machine['font']['postScriptName']=='Menlo-Regular' and machine['font']['sizePoints']==14
        and all(machine[k]==episode['machineAfter'][k] for k in ['font','displays'])
        and sha(machine['font']['file'])==episode['fontSHA256'],'startup machine, font, power or native conditions differ')
    hardware_proved(episode['hardware'])
    require(len(episode['steps'])==len(plan['steps'])
        and sorted(p.name for p in (root/'observations').iterdir())==sorted(s['name'] for s in plan['steps']),
        'startup observation inventory differs')
    def rows():
        for step,row in zip(plan['steps'],episode['steps'],strict=True):
            require(row['name']==step['name'] and native_condition_signature(row['native'])==native,
                    'startup step order/native conditions differ')
            value,raw,domain,environment=validate_launch(root,plan,step,row)
            yield step,row,value,raw,domain,environment
    blocks=aggregate(rows())
    require(initial['sessionReadFinishedMonotonicNS']<=episode['steps'][0]['startedMonotonicNS']
        and activity[-1]['readStartedMonotonicNS']>=episode['steps'][-1]['finishedMonotonicNS']
        and episode['finishedMonotonicNS']>=activity[-1]['sessionReadFinishedMonotonicNS'],'startup guard coverage differs')
    return dict(path=str(root),case='startup/first-visible',kind='input',metric=METRIC,profile=plan['profile'],power=power,
        binaries=binaries,grid=plan['targetGrid'],blocks=blocks,display=plan['displayID'],font=machine['font'],
        fontSHA256=episode['fontSHA256'],displays=machine['displays'],observerEnvironment=native,hardware=episode['hardware']['stdout'])

def load_startup_evidence(directory,expected_binaries=None):
    try:return _load_startup_evidence(directory,expected_binaries)
    except (KeyError,TypeError,IndexError,AttributeError,OSError,RuntimeError) as error:
        raise ValueError('incomplete or malformed startup campaign: '+str(error)) from error
