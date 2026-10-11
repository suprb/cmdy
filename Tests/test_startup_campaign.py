"""Generated cohort and raw receipts. No app, capture, native events or permissions."""
from copy import deepcopy
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import startup_campaign_contract as contract
import startup_parity_evidence as evidence
import startup_recorder as recorder
from startup_evidence_tests import fixture, attach_worker_trace, TOKEN
from startup_evidence import validate

def cohort():
    rows=[]
    for step in contract.schedule(3):
        step['token']=f'{step["block"]*100+step["sample"]+3:032x}'
        index=step['index'];tick=1000+index*1000
        raw=dict(launch=dict(beforeTicks=tick),cleanup=dict(worker=dict(finishedTicks=tick+200)),
            timebase=dict(numer=1,denom=1),appIdentity=dict(pid=index*2+10,startSeconds=1,startMicroseconds=0),
            workerIdentity=dict(pid=index*2+11,startSeconds=1,startMicroseconds=0))
        row=dict(startedMonotonicNS=tick,finishedMonotonicNS=tick+300)
        rows.append((step,row,9999 if step['warmup'] else step['sample']+1,raw,f'owned.{index}',{'HOME':'/synthetic'}))
    return rows

def launch_fixture(root):
    raw,display=fixture();step=dict(name='00-cmdy-00',terminal='cmdy',input='inputs/00-cmdy-00',
                                  output='observations/00-cmdy-00',token=TOKEN)
    inputs=root/step['input'];output=root/step['output'];output.mkdir(parents=True)
    app=root/'app';app.write_bytes(b'generated app bytes - never executed')
    prepared=recorder.prepare(inputs,'cmdy',app,display,token=TOKEN)
    spec=contract.read(inputs/'spec.json')
    def rebind(value):
        if isinstance(value,dict):return {k:rebind(v) for k,v in value.items()}
        if isinstance(value,list):return [rebind(v) for v in value]
        if value=='/owned/app':return str(app)
        if value=='/owned/python':return spec['workerExecutable']
        return value
    raw=rebind(raw);raw.update(spec=spec,specSHA256=prepared['specSHA256']);raw['cleanup']['childStatus']=0
    plan=dict(profile='matched',targetGrid=[98,29],display=display,python=spec['workerExecutable'],
        pythonSHA256=spec['workerExecutableSHA256'],binaries={'cmdy':dict(path=str(app),sha256=contract.sha(app))},
        sourceSHA256=prepared['preparationSources'],frozenInputs=spec['inputFiles'])
    contract.write(output/'raw.json',raw);contract.write(output/'prepared.json',prepared)
    (root/'tooling').mkdir();contract.write(root/'tooling/startup-observer-build.json',{'generatedTest':True})
    contract.write(output/'observer-build.json',{'generatedTest':True})
    domain=prepared['defaultsDomain']
    defaults=dict(complete=True,status='already-absent',domain=domain,commands=[dict(
        arguments=['/usr/bin/defaults','export',domain,'-'],exitedAndReaped=True,exitCode=1,
        stdout='',stderr='Domain '+domain+' does not exist')])
    result=validate(raw,spec,prepared['specSHA256'])
    result.update(observerReaped=True,observerExitCode=0,observerPID=10,ownedDefaultsCleanup=defaults,
                  nativeReceipt=dict(sha256=contract.sha(output/'raw.json')))
    contract.write(output/'result.json',result)
    argv=[plan['python'],'-B',str(root/'tooling/startup_recorder.py'),'--record-diagnostic',str(inputs/'prepared.json'),
        '--observer',str(root/'tooling/startup-observer'),'--observer-build',str(root/'tooling/startup-observer-build.json'),
        '--output',str(output)]
    row=dict(pid=1,arguments=argv,exitCode=0,reaped=True,rawSHA256=contract.sha(output/'raw.json'),
        resultSHA256=contract.sha(output/'result.json'),ownedPIDsAbsent=[1,10,20,30])
    return plan,step,row

class StartupCampaignTests(unittest.TestCase):
    def test_hardware_command_uses_the_collector_returncode_schema(self):
        value=dict(command=['/usr/sbin/sysctl','hw.model','hw.memsize','hw.physicalcpu',
                            'hw.logicalcpu','machdep.cpu.brand_string'],returncode=0,stdout='generated hardware',stderr='')
        evidence.hardware_proved(value)
        for field,replacement in [('returncode',1),('returncode',False),('command',['echo','hardware']),
                                  ('stdout',''),('stderr','failed')]:
            bad=deepcopy(value);bad[field]=replacement;bad['exitCode']=0
            with self.subTest(field=field),self.assertRaises(ValueError):evidence.hardware_proved(bad)

    def test_v5_cannot_inherit_v4_reader_exceptions_or_changed_collection(self):
        inventories=('unknown','1261f01db58936400cef1bd900f9fb19d325f3a8db0de321b0357cff5e290754',
                     'c9d7744ec0fd487bf6049b1421b7905f231995ea232626d6d986748dbbc0a3de')
        for name in contract.SOURCES:
            self.assertTrue(contract.source_version_matches(name,'a'*64,'a'*64,'unknown'))
            for inventory in inventories:
                self.assertFalse(contract.source_version_matches(name,'a'*64,'b'*64,inventory))

    def test_empty_plist_export_requires_the_exact_scoped_delete_absence_proof(self):
        domain='com.cmdy.startup.'+'a'*32
        commands=[]
        for operation in ['export','delete','export','delete']:
            commands.append(dict(arguments=['/usr/bin/defaults',operation,domain]+(['-'] if operation=='export' else []),
                exitedAndReaped=True,exitCode=0,stdout='',stderr=''))
        commands[2]['stdout']='<?xml version="1.0"?><plist version="1.0"><dict/></plist>'
        commands[3].update(exitCode=1,stderr=f'Domain ({domain}) not found.\nDefaults have not been changed.')
        value=dict(complete=True,status='exported-and-deleted',domain=domain,commands=commands)
        evidence.defaults_proved(value,'cmdy',domain)
        for field,replacement in [('exitCode',0),('stdout','unexpected'),('stderr','not found')]:
            bad=deepcopy(value);bad['commands'][3][field]=replacement
            with self.subTest(field=field),self.assertRaises(ValueError):evidence.defaults_proved(bad,'cmdy',domain)
        bad=deepcopy(value);bad['commands'][2]['stdout']='<?xml version="1.0"?><plist version="1.0"><dict><key>live</key><true/></dict></plist>'
        with self.assertRaises(ValueError):evidence.defaults_proved(bad,'cmdy',domain)

    def test_frozen_contract_rejects_changed_counts_order_paths_and_qualification(self):
        root=Path('/generated/campaign');digest='a'*64
        steps=contract.schedule(7)
        for step in steps:step.update(input='inputs/'+step['name'],output='observations/'+step['name'])
        plan=dict(kind=contract.KIND,protocol=contract.PROTOCOL,prospective=True,priorSamplesInherited=False,
            blocks=6,samplesPerBlock=40,warmupsPerBlock=2,minimumInitialIdleSeconds=300,minimumSettledNS=200_000_000,
            minimumCompleteContentNS=1_000_000_000,powerSource='AC Power',profile='matched',policySHA256=contract.POLICY_SHA,
            generationPolicy=contract.GENERATION_POLICY,
            seed=7,steps=steps,sourceSHA256={n:digest for n in contract.SOURCES},observerSHA256=digest,
            binaries={'cmdy':{'path':'/app/Contents/MacOS/cmdy','sha256':digest},'ghostty':{'path':'/ghostty','sha256':digest}},
            python='/python',pythonSHA256=digest,helper='/helper',helperSHA256=digest,package='/package',packageSHA256=digest,
            frozenInputs={p:digest for p in ['/app/Contents/MacOS/cmdy','/ghostty','/python','/helper','/package/package.json']})
        qualified=dict(status='pass',sourcesUnchanged=True,nativeObservationRun=False,applicationLaunches=0,
            pythonTests=40,swiftChecks=64,sourceSHA256={n:digest for n in contract.QUALIFIED},
            commands=[dict(exitCode=0,exitedAndReaped=True)],observerSHA256=digest)
        build=dict(headlessQualified=True,nativeObservationRun=False,sourceSHA256={n:digest for n in contract.OBSERVER_SOURCES},
            toolingSHA256=qualified['sourceSHA256'],binarySHA256=digest)
        pkg=dict(app='/app',executableSHA256=digest,sourceArchiveSHA256=digest,nativeArchiveSHA256=digest,
                 nativeSourceKey=digest,rawExecutableSHA256=digest)
        for mode in ['valid','count','order','warmup','path','qualified','helper','legacy','past','generation','checks']:
            current=deepcopy(plan);q=deepcopy(qualified)
            if mode=='count':current['samplesPerBlock']=20
            elif mode=='order':current['steps'][0],current['steps'][1]=current['steps'][1],current['steps'][0]
            elif mode=='warmup':current['steps'][0]['warmup']=False
            elif mode=='path':current['steps'][0]['output']='../older-observation'
            elif mode=='qualified':q['commands'][0]['exitCode']=1
            elif mode=='helper':current['helperSHA256']='b'*64
            elif mode=='legacy':current['protocol']='startup-full-generated-viewport-v2'
            elif mode=='past':current['priorSamplesInherited']=True
            elif mode=='generation':current['generationPolicy']='zero-signals'
            elif mode=='checks':q['swiftChecks']=56
            values={root/'plan.json':current,root/'tooling/qualification.json':q,
                    root/'tooling/startup-observer-build.json':build,Path('/package/package.json'):pkg}
            with self.subTest(mode=mode),patch.object(contract,'read',side_effect=lambda p:values[Path(p)]),\
                    patch.object(contract,'sha',return_value=digest):
                if mode=='valid':self.assertEqual(contract.check_plan(root,verify_files=False),current)
                else:
                    with self.assertRaises(ValueError):contract.check_plan(root,verify_files=False)

    def test_schedule_has_six_balanced_blocks_and_separate_warmups(self):
        for seed in (0,1,2,2**63-1):
            rows=contract.schedule(seed);self.assertEqual(len(rows),504)
            firsts=[next(s['terminal'] for s in rows if s['block']==b) for b in range(6)]
            self.assertEqual(firsts.count('cmdy'),3);self.assertEqual(firsts.count('ghostty'),3)
            self.assertTrue(all(a!=b for a,b in zip(firsts,firsts[1:])))
            self.assertEqual(sum(s['warmup'] for s in rows),24)
            self.assertEqual(len({s['name'] for s in rows}),504)
        for seed in (-1,True,2**63):
            with self.assertRaises(ValueError):contract.schedule(seed)

    def test_aggregate_excludes_warmups_without_discarding_their_evidence(self):
        blocks=evidence.aggregate(cohort())
        self.assertEqual(len(blocks),6)
        for pair in blocks.values():
            self.assertEqual(pair,{'cmdy':list(range(1,41)),'ghostty':list(range(1,41))})

    def test_cohort_rejects_missing_samples_wrong_nonces_overlap_and_reused_lifetimes(self):
        for mode in ['missing','duplicate','nonce','warmup','native-overlap','outer-overlap','lifetime','domain','environment']:
            rows=cohort()
            if mode=='missing':rows.pop()
            elif mode=='duplicate':rows.append(deepcopy(rows[-1]))
            elif mode=='nonce':rows[0][0]['token']='f'*32
            elif mode=='warmup':rows[0][0]['warmup']=False
            elif mode=='native-overlap':rows[1][3]['launch']['beforeTicks']=1100
            elif mode=='outer-overlap':rows[1][1]['startedMonotonicNS']=1100
            elif mode=='lifetime':rows[1][3]['appIdentity']=deepcopy(rows[0][3]['appIdentity'])
            elif mode=='domain':rows[1]=(*rows[1][:4],rows[0][4],rows[1][5])
            elif mode=='environment':rows[1][5]['HOME']='/different'
            with self.subTest(mode=mode),self.assertRaises(ValueError):evidence.aggregate(rows)

    def test_native_raw_reconstruction_matches_a_complete_generated_launch(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name).resolve();plan,step,row=launch_fixture(root)
            value,raw,domain,env=evidence.validate_launch(root,plan,step,row)
            self.assertEqual(value,1000);self.assertEqual(raw['firstFrame']['displayTicks'],2000)

    def test_target_write_signals_require_full_trace_and_no_later_grid_change(self):
        for mode in ['valid','late-noop','transient','unaccounted','generation','final-grid']:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as name:
                root=Path(name).resolve();plan,step,row=launch_fixture(root)
                output=root/step['output'];path=output/'raw.json';raw=contract.read(path)
                attach_worker_trace(raw,initial_grid=(44,16) if mode=='transient' else None,
                    signal_ticks=(1150,) if mode=='transient' else (1400,1600) if mode=='late-noop' else (1400,))
                expected=validate(raw,contract.read(root/step['input']/'spec.json'),raw['specSHA256'])
                if mode=='unaccounted':raw['workerEvents']['events'][0]['signalCounter']=0
                elif mode=='generation':raw['cleanup']['worker']['generation']=2
                elif mode=='final-grid':raw['finalTTYGrid']['rows']+=1
                path.write_text(__import__('json').dumps(raw));row['rawSHA256']=contract.sha(path)
                result=contract.read(output/'result.json');result['nativeReceipt']['sha256']=row['rawSHA256']
                result.update(expected)
                (output/'result.json').write_text(__import__('json').dumps(result))
                row['resultSHA256']=contract.sha(output/'result.json')
                if mode in ('valid','late-noop','transient'):self.assertEqual(evidence.validate_launch(root,plan,step,row)[0],1000)
                else:
                    with self.assertRaises(ValueError):evidence.validate_launch(root,plan,step,row)

    def test_launch_contract_rejects_binary_profile_counts_summary_cleanup_and_shell_tampering(self):
        for mode in ['binary','profile','source','command','raw','cleanup','summary','shell','domain']:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as name:
                root=Path(name).resolve();plan,step,row=launch_fixture(root)
                if mode=='binary':plan['binaries']['cmdy']['sha256']='f'*64
                elif mode=='profile':plan['profile']='cmdy-defaults'
                elif mode=='source':plan['sourceSHA256']['startup_fixture.py']='f'*64
                elif mode=='command':row['arguments'].append('--qualify')
                elif mode=='raw':row['rawSHA256']='f'*64
                elif mode=='cleanup':row['ownedPIDsAbsent'].pop()
                elif mode=='shell':(root/step['input']/'zsh/.zshenv').write_text('echo invalid\n')
                else:
                    path=root/step['output']/'result.json';result=contract.read(path)
                    if mode=='summary':result['launchToFrameNS']=1
                    else:result['ownedDefaultsCleanup']['domain']='com.user.terminal'
                    path.write_text(__import__('json').dumps(result));row['resultSHA256']=contract.sha(path)
                with self.assertRaises(ValueError):evidence.validate_launch(root,plan,step,row)

    def test_gate_routes_only_the_new_cohort_manifest(self):
        import parity_gate
        with tempfile.TemporaryDirectory() as name:
            root=Path(name);contract.write(root/'manifest.json',{'benchmarkKind':contract.KIND})
            with patch.object(evidence,'load_startup_evidence',side_effect=ValueError('synthetic incomplete cohort')) as loader:
                result=parity_gate.evaluate([root],contract.read(contract.HERE/'parity-policy.json'),{'cmdy':'a'*64,'ghostty':'b'*64})
                loader.assert_called_once();self.assertEqual(result['invalidEvidence'][0]['reason'],'synthetic incomplete cohort')
                self.assertFalse(result['passed']);self.assertTrue(all(v['status']=='not-measured' for v in result['results']))

if __name__=='__main__':unittest.main()
