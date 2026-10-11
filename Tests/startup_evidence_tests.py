"""Generated raw evidence, source-binding and negative tests. No native actions."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from bench_ancestry import METHOD
from startup_evidence import METRIC, validate, signed_ns
from startup_grid import Witness, witness_digest, canonical
from startup_grid_evidence import PROTOCOL, FOREGROUND_METHOD, digest, validate_proof
from startup_recorder import prepare, record, stop_observer, cleanup_defaults

TOKEN="0123456789abcdef0123456789abcdef"
SPEC_SHA="1"*64

def foreground_query(owner, cocoa_pid=None):
    tick=owner['queriedTicks']
    value=dict(startedTicks=tick,finishedTicks=tick,queryStatus=0,pidStatus=0,timeoutStatus=0,
               trusted=True,pid=owner['foregroundPID'])
    return dict(before=deepcopy(value),after=deepcopy(value),cocoaTicks=tick,queriedTicks=tick,
                cocoaPID=owner['foregroundPID'] if cocoa_pid is None else cocoa_pid)

def append_foreground_frame(record, frame):
    record['foregroundDiagnostics'].extend(foreground_query(frame[k]) for k in ('before','after'))

def pixel_proof(columns=98,rows=29,generation=1,*,x_pitch=7,y_pitch=12,offset=0):
    visible=Witness(TOKEN,columns,rows,generation,1)
    raster=dict(width=1400,height=1000,xEdges=[30+offset+x_pitch*x for x in range(columns+1)],
        yEdges=[20+offset+y_pitch*y for y in range(rows+1)],sampleInsetPixels=2,edgeRoundingPixels=1)
    runs=[];pixels=bytearray()
    for red,green,blue in visible.cells().values():
        sample=[blue,green,red,255];count=(x_pitch-4)*(y_pitch-4)
        if runs and runs[-1][1:]==sample:runs[-1][0]+=count
        else:runs.append([count,*sample])
        pixels.extend(bytes(sample)*count)
    return dict(witness=dict(token=TOKEN,columns=columns,rows=rows,generation=generation,frameKind=1),
        raster=raster,checkedCells=columns*rows,checkedPixels=len(pixels)//4,generatedSHA256=witness_digest(visible),
        checkedPixelsSHA256=hashlib.sha256(pixels).hexdigest(),checkedPixelRuns=runs)

def ancestry(app,worker,start):
    tick=start
    def observed(endpoint):
        nonlocal tick
        link={k:endpoint[k] for k in ("pid","parentPID","uid","startSeconds","startMicroseconds")}
        link["realUID"]=endpoint["uid"]
        row=dict(api="sysctl(KERN_PROC_PID)",requestedPID=endpoint["pid"],observedPID=endpoint["pid"],
            result=0,errno=0,returnedBytes=648,expectedBytes=648,typedRecordComplete=True,startedTicks=tick,
            finishedTicks=tick+1,state=2,flags=0,traced=False,link=link)
        row.update({k:v for k,v in link.items() if k!="pid"});tick+=2;return row
    first=[observed(worker),observed(app)];second=[observed(app),observed(worker)]
    return dict(schemaVersion=1,method=METHOD,proven=True,atomicSnapshot=False,cleanupAuthority=False,
        expectedAppPID=app["pid"],expectedWorkerPID=worker["pid"],pinnedApp=deepcopy(app),pinnedWorker=deepcopy(worker),
        fullAppBefore=deepcopy(app),fullAppAfter=deepcopy(app),fullWorkerBefore=deepcopy(worker),fullWorkerAfter=deepcopy(worker),
        fullEndpointsBeforeExact=True,fullEndpointsAfterExact=True,everyParentAndLifetimeRepeatedExactly=True,
        startedTicks=start,finishedTicks=tick,
        firstWalk=dict(limit=32,reachedApp=True,stoppingReason="pinned-app-reached",observations=first),secondWalkReverse=second)

def attach_worker_trace(record, initial_grid=None, signal_ticks=()):
    """Generated v5 trace, with explicit real-initial versus first-target grids."""
    ready=record['workerReady'];grid=tuple(record['spec']['targetGrid']);finished=record['finishedTicks']
    initial=tuple(initial_grid or grid);ready.update(initialColumns=initial[0],initialRows=initial[1])
    signals=[dict(receivedTicks=tick) for tick in signal_ticks]
    count=lambda tick:sum(s['receivedTicks']<=tick for s in signals)
    event=record['workerEvents']['events'][0]
    core={k:v for k,v in event.items() if k not in ('signalCounter','signalCounterAtObserved','signalCounterAtStarted')}
    event=dict(core,signalCounterAtObserved=count(core['observedTicks']),
        signalCounterAtStarted=count(core['startedTicks']),signalCounter=count(core['completedTicks']))
    observations=[]
    def observe(reason,before,after,actual):
        observations.append(dict(index=len(observations),reason=reason,beforeTicks=before,afterTicks=after,
            columns=actual[0],rows=actual[1],signalCounterBefore=count(before),signalCounterAfter=count(after)))
    observe('initial',ready['startedTicks']+1,1110 if initial!=grid else core['observedTicks'],initial)
    if initial!=grid:observe('wake',1190,core['observedTicks'],grid)
    first=len(observations)-1
    observe('before-write',1250,1260,grid)
    for tick in signal_ticks:
        if core['startedTicks']<=tick<core['completedTicks']:observe('signal-during-write',tick,tick+1,grid)
    observe('after-write',core['completedTicks']+1,core['completedTicks']+2,grid)
    for tick in signal_ticks:
        if tick>core['completedTicks']+2:observe('wake',tick,tick+1,grid)
    live=dict(protocol=PROTOCOL,diagnosticOnly=True,token=ready['token'],pid=ready['pid'],targetGrid=list(grid),
        status='painted',error='',signalOverflow=False,recordedTicks=max(1510,max(signal_ticks,default=0)+10),
        firstTargetIndex=first,gridObservations=deepcopy(observations),signals=signals,paintAttempt=core,events=[event])
    final=deepcopy(live);observe('final',finished+10,finished+20,grid)
    final.update(status='stopped',recordedTicks=finished+90,gridObservations=observations)
    record['workerEvents']=live;record['workerFinalEvents']=final
    record['cleanup']['worker'].update(protocol=PROTOCOL,completedViewport=True)

def fixture(proof=None, target=(98,29), initial_grid=None, signal_ticks=()):
    columns,rows=target
    proof=proof or pixel_proof(columns,rows);key=digest(proof)
    app=dict(pid=20,parentPID=10,uid=501,startSeconds=20,startMicroseconds=1,executable="/owned/app")
    worker=dict(pid=30,parentPID=20,uid=501,startSeconds=21,startMicroseconds=2,executable="/owned/python")
    rectangle=dict(x=0,y=0,width=1400,height=1000)
    mode=dict(modeID=1,flags=0,width=1400,height=1000,pixelWidth=1400,pixelHeight=1000,refreshRate=120,rotation=0)
    spec=dict(schemaVersion=1,qualifying=False,token=TOKEN,targetGrid=list(target),captureShowsCursor=False,
        foregroundMethod=FOREGROUND_METHOD,
        executable=app["executable"],executableSHA256="a"*64,
        workerExecutable=worker["executable"],workerExecutableSHA256="b"*64,displayID=1,displayBounds=rectangle,
        displayMode=mode,lowPowerMode=False,thermalState=0)
    def owner(tick):return dict(identity=deepcopy(app),windowID=7,displayID=1,bounds=deepcopy(rectangle),
        foregroundPID=20,occluded=False,queriedTicks=tick)
    pre=dict(displayTicks=90,callbackTicks=91,checkedTicks=94,stage="prelaunch")
    first=dict(displayTicks=2000,callbackTicks=2001,checkedTicks=2004,stage="complete-generated",before=owner(2002),
        after=owner(2003),proofSHA256=key)
    finished=1_100_003_000;payload=Witness(TOKEN,columns,rows,1,1).frame_bytes()
    record=dict(schemaVersion=1,qualifying=False,status="diagnostic-only",case="startup/first-visible",metric=METRIC,
        protocol=PROTOCOL,spec=deepcopy(spec),specSHA256=SPEC_SHA,observerFailure=None,inputHashesUnchanged=True,
        captureExcludedSystemCursors={},
        launch=dict(beforeTicks=1000,afterTicks=2100,api="posix_spawn",calls=1,result=0,pid=20),appIdentity=app,workerIdentity=worker,
        ancestry=ancestry(app,worker,1_100_000_000),proofs={key:proof},frames=[pre,first],
        statuses=[dict(status=0,displayTicks=f["displayTicks"],callbackTicks=f["callbackTicks"]) for f in (pre,first)],
        prelaunchFrame=deepcopy(pre),firstFrame=deepcopy(first),finalProof=owner(finished-1),finishedTicks=finished,
        timebase=dict(numer=1,denom=1),metricsNS=dict(launchToFrameNS=1000,launchCallNS=1100,frameMinusLaunchReturnNS=-100,captureCallbackLagNS=1),
        workerReady=dict(token=TOKEN,executable=worker["executable"],ttyPath="/dev/ttys001",pid=30,parentPID=20,startedTicks=1100,
            initialColumns=columns,initialRows=rows),
        workerEvents=dict(token=TOKEN,pid=30,events=[dict(generation=1,columns=columns,rows=rows,observedTicks=1200,startedTicks=1300,
            completedTicks=1500,offeredBytes=len(payload),completedBytes=len(payload),payloadSHA256=hashlib.sha256(payload).hexdigest(),signalCounter=0)],signals=[]),
        finalTTYGrid=dict(columns=columns,rows=rows),workerTTY=dict(path="/dev/ttys001",startedTicks=finished-100,
            finishedTicks=finished-50,pid=30,uid=501,device=42,processDevice=42,characterDevice=True,
            processGroup=30,foregroundGroup=30,grid=dict(columns=columns,rows=rows)),
        cleanup=dict(appPID=20,workerPID=30,appReaped=True,workerGone=True,
            worker=dict(token=TOKEN,pid=30,error="",termiosRestored=True,flagsRestored=True,finishedTicks=finished+100,generation=1)))
    record['foregroundDiagnostics']=[foreground_query(owner) for owner in (first['before'],first['after'],record['finalProof'])]
    attach_worker_trace(record,initial_grid,signal_ticks)
    return record,spec

class StartupEvidenceTests(unittest.TestCase):
    def test_qualification_summary_accepts_passing_test_names_containing_skipped(self):
        from startup_build import passing_python_count
        log='test_skipped_target_is_rejected (GeneratedTests) ... ok\n\nRan 1 test in 0.001s\n\nOK\n'
        self.assertEqual(passing_python_count(log),1)

    def test_qualification_summary_rejects_actual_skips_failures_and_partial_output(self):
        from startup_build import passing_python_count
        for summary in ('OK (skipped=1)','FAILED (failures=1)','OK (expected failures=1)','', 'OK\nmore output'):
            with self.subTest(summary=summary),self.assertRaises(RuntimeError):
                passing_python_count('test_case ... skipped "not run"\n\nRan 1 test in 0.001s\n\n'+summary+'\n')
        with self.assertRaises(RuntimeError):passing_python_count('\nRan 0 tests in 0.001s\n\nOK\n')

    def test_fresh_ax_focus_remains_authoritative_when_cocoa_is_stale(self):
        value,spec=fixture()
        for query in value['foregroundDiagnostics']:query['cocoaPID']=999
        self.assertEqual(validate(value,spec,SPEC_SHA)['launchToFrameNS'],1000)
        for mode in ('missing','duplicate','pid','query-error','pid-error','timeout-error','untrusted','clock','method'):
            bad=deepcopy(value);other=deepcopy(spec)
            if mode=='missing':bad['foregroundDiagnostics'].pop(0)
            elif mode=='duplicate':bad['foregroundDiagnostics'].append(deepcopy(bad['foregroundDiagnostics'][0]))
            elif mode=='pid':bad['foregroundDiagnostics'][0]['after']['pid']=999
            elif mode=='query-error':bad['foregroundDiagnostics'][0]['before']['queryStatus']=-25204
            elif mode=='pid-error':bad['foregroundDiagnostics'][0]['before']['pidStatus']=-25200
            elif mode=='timeout-error':bad['foregroundDiagnostics'][0]['before']['timeoutStatus']=-25200
            elif mode=='untrusted':bad['foregroundDiagnostics'][0]['after']['trusted']=False
            elif mode=='clock':bad['foregroundDiagnostics'][0]['after']['startedTicks']=1
            elif mode=='method':other['foregroundMethod']='cached-Cocoa';bad['spec']=deepcopy(other)
            with self.subTest(mode=mode),self.assertRaises(ValueError):validate(bad,other,SPEC_SHA)

    def test_opening_transform_keeps_first_and_checks_every_scaled_cell(self):
        value,spec=fixture()
        value["frames"][1]["after"]["bounds"].update(x=1,width=1399)
        value["firstFrame"]=deepcopy(value["frames"][1])
        # Complete during movement, then the same logical content at a new
        # physical pitch. The earlier display clock remains the endpoint.
        moved=pixel_proof(x_pitch=8,y_pitch=13,offset=2)
        key=digest(moved);value["proofs"][key]=moved
        later=deepcopy(value["frames"][1])
        later.update(displayTicks=100_000_000,callbackTicks=100_000_001,
            checkedTicks=100_000_004,proofSHA256=key)
        later["before"]["queriedTicks"]=100_000_002;later["after"]["queriedTicks"]=100_000_003
        later["before"]["bounds"]=deepcopy(later["after"]["bounds"])
        value["frames"].append(later)
        append_foreground_frame(value,later)
        value["statuses"].append(dict(status=0,displayTicks=later["displayTicks"],callbackTicks=later["callbackTicks"]))
        value["finalProof"]["bounds"]=deepcopy(later["after"]["bounds"])
        self.assertEqual(validate(value,spec,SPEC_SHA)["launchToFrameNS"],1000)
        bad=deepcopy(value);bad["firstFrame"]=deepcopy(later)
        with self.assertRaisesRegex(ValueError,"substituted"):validate(bad,spec,SPEC_SHA)
        bad=deepcopy(value);bad["frames"][-1].update(stage="fixture-incomplete",proofSHA256=None)
        with self.assertRaisesRegex(ValueError,"remain complete"):validate(bad,spec,SPEC_SHA)
        bad=deepcopy(value);bad["frames"][-1]["after"]["bounds"].update(x=2,width=1398)
        bad["finalProof"]["bounds"]=deepcopy(bad["frames"][-1]["after"]["bounds"])
        with self.assertRaisesRegex(ValueError,"stability"):validate(bad,spec,SPEC_SHA)
        bad=deepcopy(value);bad["frames"][-1]["before"]["bounds"].update(x=32,width=1368)
        with self.assertRaisesRegex(ValueError,"bracketing owned crop"):validate(bad,spec,SPEC_SHA)
        bad=deepcopy(value);bad["frames"][-1]["after"]["bounds"].update(x=32,width=1368)
        with self.assertRaisesRegex(ValueError,"bracketing owned crop"):validate(bad,spec,SPEC_SHA)

    def test_late_raster_drift_cannot_inherit_settled_time(self):
        value,spec=fixture()
        for stamp,offset in [(100_000_000,1),(1_000_000_000,2)]:
            moved=pixel_proof(offset=offset);key=digest(moved);value["proofs"][key]=moved
            later=deepcopy(value["frames"][1])
            later.update(displayTicks=stamp,callbackTicks=stamp+1,checkedTicks=stamp+4,proofSHA256=key)
            later["before"]["queriedTicks"]=stamp+2;later["after"]["queriedTicks"]=stamp+3
            value["frames"].append(later);value["statuses"].append(dict(status=0,displayTicks=stamp,callbackTicks=stamp+1))
            append_foreground_frame(value,later)
        with self.assertRaisesRegex(ValueError,"stability"):validate(value,spec,SPEC_SHA)

    def test_only_capture_excluded_system_cursor_has_a_bounded_exception(self):
        value,spec=fixture()
        cursor=dict(windowID=4,ownerPID=468,layer=2147483630,
            ownerExecutable="/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
            firstQueryTicks=2002,lastQueryTicks=2100,queries=2)
        value["captureExcludedSystemCursors"]={"468/4":cursor}
        self.assertTrue(validate(value,spec,SPEC_SHA)["diagnosticValid"])
        for field,replacement in [("layer",2147483629),("ownerExecutable","/generated/overlay"),("queries",10001),("firstQueryTicks",999)]:
            bad=deepcopy(value);bad["captureExcludedSystemCursors"]["468/4"][field]=replacement
            with self.subTest(field=field),self.assertRaises(ValueError):validate(bad,spec,SPEC_SHA)
        spec["captureShowsCursor"]=True;value["spec"]=deepcopy(spec)
        with self.assertRaisesRegex(ValueError,"must exclude"):validate(value,spec,SPEC_SHA)
    def test_nondefault_grid_requires_predeclared_target_and_matching_worker(self):
        value,spec=fixture(target=(98,24))
        self.assertTrue(validate(value,spec,SPEC_SHA)["diagnosticValid"])
        value["finalTTYGrid"]["rows"]=25
        with self.assertRaises(ValueError):validate(value,spec,SPEC_SHA)
        value,spec=fixture(target=(98,24));spec["targetGrid"]=[98,29];value["spec"]=deepcopy(spec)
        with self.assertRaisesRegex(ValueError,"wrong initial grid"):validate(value,spec,SPEC_SHA)

    def test_missing_invalid_or_legacy_target_cannot_qualify(self):
        for target in (None,[],[98],[True,29],[98,0],[256,29]):
            value,spec=fixture();spec["targetGrid"]=target;value["spec"]=deepcopy(spec)
            with self.subTest(target=target),self.assertRaises((ValueError,TypeError)):
                validate(value,spec,SPEC_SHA)
        self.reject(lambda value:value.update(protocol="startup-full-generated-viewport-v1"))
        self.reject(lambda value:value.update(protocol="startup-full-generated-viewport-v2"))
        self.reject(lambda value:value.update(protocol="startup-full-generated-viewport-v3"))
        self.reject(lambda value:value.update(protocol="startup-full-generated-viewport-v4"))

    def test_transient_initial_grid_keeps_original_spawn_clock_and_one_target_paint(self):
        value,spec=fixture(initial_grid=(44,16),signal_ticks=(1150,))
        result=validate(value,spec,SPEC_SHA)
        self.assertEqual(result['workerTrace']['initialGrid'],[44,16])
        self.assertTrue(result['workerTrace']['waitedForTarget'])
        self.assertEqual(result['workerTrace']['generatedViewports'],1)
        self.assertEqual(result['launchToFrameNS'],1000)
        self.assertEqual(result['frameMinusLaunchReturnNS'],-100)

    def test_full_trace_rejects_replaced_initial_skipped_target_and_changed_live_prefix(self):
        for mode in ('initial','missing-trace','skipped-target','live-prefix','future-signal','changed-final-grid','second-paint'):
            value,spec=fixture(initial_grid=(44,16),signal_ticks=(1150,))
            final=value['workerFinalEvents']
            if mode=='initial':value['workerReady']['initialColumns']=98
            elif mode=='missing-trace':value.pop('workerFinalEvents')
            elif mode=='skipped-target':final['firstTargetIndex']+=1
            elif mode=='live-prefix':value['workerEvents']['gridObservations'][0]['rows']=17
            elif mode=='future-signal':final['signals'].append(dict(receivedTicks=value['cleanup']['worker']['finishedTicks']+1))
            elif mode=='changed-final-grid':final['gridObservations'][-1]['rows']=30
            elif mode=='second-paint':final['events'].append(deepcopy(final['events'][0]))
            with self.subTest(mode=mode),self.assertRaises((ValueError,KeyError)):
                validate(value,spec,SPEC_SHA)

    def test_signal_during_or_after_write_is_bound_to_its_own_timestamp(self):
        value,spec=fixture(signal_ticks=(1400,1600))
        self.assertTrue(validate(value,spec,SPEC_SHA)['diagnosticValid'])
        event=value['workerEvents']['events'][0]
        self.assertEqual((event['signalCounterAtObserved'],event['signalCounterAtStarted'],event['signalCounter']),(0,0,1))
        for key in ('signalCounterAtObserved','signalCounterAtStarted','signalCounter'):
            wrong=deepcopy(value)
            for trace in ('workerEvents','workerFinalEvents'):wrong[trace]['events'][0][key]=64
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'paint signal chronology'):
                validate(wrong,spec,SPEC_SHA)

    def test_complete_earliest_frame_can_precede_spawn_return(self):
        value,spec=fixture();result=validate(value,spec,SPEC_SHA)
        self.assertTrue(result["diagnosticValid"]);self.assertFalse(result["qualifying"])
        self.assertEqual(result["frameMinusLaunchReturnNS"],-100)

    def reject(self,mutate):
        value,spec=fixture();mutate(value)
        with self.assertRaises((ValueError,KeyError,TypeError)):validate(value,spec,SPEC_SHA)

    def test_prearmed_frame_cannot_be_missing_or_after_launch(self):
        for mutate in (lambda r:r["frames"].pop(0),lambda r:r["frames"][0].update(checkedTicks=1001),
                       lambda r:r["frames"][0].update(displayTicks=1001),lambda r:r["launch"].update(api="Process.run")):
            with self.subTest(mutate=mutate):self.reject(mutate)

    def test_complete_boolean_cannot_replace_pixels(self):
        self.reject(lambda r:r["frames"][1].pop("proofSHA256"))
        self.reject(lambda r:r.update(proofs={}))

    def test_first_wrong_grid_cannot_be_replaced_by_later_target(self):
        value,spec=fixture();wrong=pixel_proof(100,30);key=digest(wrong);value["proofs"][key]=wrong
        earlier=deepcopy(value["frames"][1]);earlier.update(displayTicks=1800,callbackTicks=1801,checkedTicks=1804,proofSHA256=key)
        earlier["before"]["queriedTicks"]=1802;earlier["after"]["queriedTicks"]=1803
        value["frames"].insert(1,earlier);value["statuses"].insert(1,dict(status=0,displayTicks=1800,callbackTicks=1801))
        append_foreground_frame(value,earlier)
        with self.assertRaisesRegex(ValueError,"wrong initial grid"):validate(value,spec,SPEC_SHA)

    def test_later_good_frame_cannot_be_selected_as_first(self):
        value,spec=fixture();later=deepcopy(value["frames"][1]);later.update(displayTicks=2200,callbackTicks=2201,checkedTicks=2204)
        later["before"]["queriedTicks"]=2202;later["after"]["queriedTicks"]=2203
        value["frames"].append(later);value["statuses"].append(dict(status=0,displayTicks=2200,callbackTicks=2201))
        append_foreground_frame(value,later)
        value["firstFrame"]=later
        with self.assertRaisesRegex(ValueError,"substituted"):validate(value,spec,SPEC_SHA)

    def test_interior_pixel_corruption_fails_even_after_rehashing_proof(self):
        value,spec=fixture();proof=next(iter(value["proofs"].values()))
        proof["checkedPixelRuns"][1000][1]^=31
        payload=b"".join(bytes(run[1:])*run[0] for run in proof["checkedPixelRuns"])
        proof["checkedPixelsSHA256"]=hashlib.sha256(payload).hexdigest();key=digest(proof)
        value["proofs"]={key:proof};value["frames"][1]["proofSHA256"]=key;value["firstFrame"]["proofSHA256"]=key
        with self.assertRaisesRegex(ValueError,"captured generated cell"):validate(value,spec,SPEC_SHA)

    def test_expected_grid_or_hash_cannot_replace_observed_cells(self):
        for field,new in (("checkedCells",98*2+27*2),("checkedPixels",0),("checkedPixelsSHA256","0"*64),("generatedSHA256","0"*64)):
            proof=pixel_proof();proof[field]=new
            with self.subTest(field=field),self.assertRaises(ValueError):validate_proof(proof,TOKEN)

    def test_rle_must_be_lossless_canonical_bounded_and_opaque(self):
        for mode in ("truncate","split","alpha","count","bool"):
            proof=pixel_proof();runs=proof["checkedPixelRuns"]
            if mode=="truncate":runs.pop()
            if mode=="split":runs.insert(0,[1,*runs[0][1:]]);runs[1][0]-=1
            if mode=="alpha":runs[1000][4]=100
            if mode=="count":runs[0][0]=10_000_001
            if mode=="bool":runs[0][0]=True
            with self.subTest(mode=mode),self.assertRaises(ValueError):validate_proof(proof,TOKEN)

    def test_frame_status_bijection_and_clock_order_are_required(self):
        for mutate in (lambda r:r["statuses"].pop(),lambda r:r["statuses"].append(deepcopy(r["statuses"][-1])),
            lambda r:r["frames"].reverse(),lambda r:r["frames"][1].update(callbackTicks=89),
            lambda r:r["statuses"][0].update(displayTicks=0),lambda r:r["statuses"][1].update(callbackTicks=2002)):
            with self.subTest(mutate=mutate):self.reject(mutate)

    def test_blank_restart_stop_and_suspend_fail_closed(self):
        for code in (2,3,4,5):
            with self.subTest(code=code):self.reject(lambda r:r["statuses"].append(dict(status=code,displayTicks=2100,callbackTicks=2101)))
        self.reject(lambda r:r["statuses"].insert(1,dict(status=2,displayTicks=2200,callbackTicks=1900)))

    def test_ownership_lifetime_foreground_occlusion_and_crop_fail_closed(self):
        for mutate in (lambda r:r["frames"][1]["before"].update(occluded=True),
            lambda r:r["frames"][1]["after"].update(foregroundPID=999),lambda r:r["frames"][1]["before"].update(windowID=8),
            lambda r:r["frames"][1]["after"]["identity"].update(startMicroseconds=3),
            lambda r:r["frames"][1]["before"].update(queriedTicks=1999),
            lambda r:r["finalProof"].update(displayID=2),lambda r:r["finalProof"]["bounds"].update(x=1)):
            with self.subTest(mutate=mutate):self.reject(mutate)

    def test_capture_size_cannot_be_substituted_by_expected_mode(self):
        value,spec=fixture();spec["displayMode"]["pixelWidth"]=1401;value["spec"]=deepcopy(spec)
        with self.assertRaisesRegex(ValueError,"capture mode"):validate(value,spec,SPEC_SHA)

    def test_clock_conversion_preserves_negative_callback_lag(self):
        self.assertEqual(signed_ns(9,10,dict(numer=125,denom=3)),-41)
        for end,start,tb in ((True,0,dict(numer=1,denom=1)),(1,0,dict(numer=1,denom=0)),
            ((1<<63)-1,0,dict(numer=1_000_000_000,denom=1))):
            with self.subTest(end=end),self.assertRaises(ValueError):signed_ns(end,start,tb)

    def test_metric_stability_and_final_guard_are_recomputed(self):
        for mutate in (lambda r:r["metricsNS"].update(launchToFrameNS=999),lambda r:r.update(finishedTicks=5000),
            lambda r:r["finalProof"].update(queriedTicks=2003),lambda r:r["metricsNS"].update(captureCallbackLagNS=True),
            lambda r:r.update(finishedTicks=16_000_000_000)):
            with self.subTest(mutate=mutate):self.reject(mutate)

    def test_worker_nonce_bytes_generation_and_causality_are_recomputed(self):
        for mutate in (lambda r:r["workerReady"].update(token="f"*32),lambda r:r["workerEvents"]["events"][0].update(completedBytes=1),
            lambda r:r["workerEvents"]["events"][0].update(payloadSHA256="0"*64),
            lambda r:r["workerEvents"]["events"][0].update(startedTicks=2001),
            lambda r:r["workerEvents"]["events"][0].update(generation=2),lambda r:r["workerEvents"]["events"][0].update(signalCounter=1),
            lambda r:r["workerReady"].update(initialColumns=99),
            lambda r:r["finalTTYGrid"].update(columns=99)):
            with self.subTest(mutate=mutate):self.reject(mutate)

    def test_kernel_ancestry_cannot_be_replaced_by_proven_flag(self):
        self.reject(lambda r:r["ancestry"]["secondWalkReverse"].pop())
        self.reject(lambda r:r["ancestry"]["fullWorkerAfter"].update(startSeconds=99))

    def test_controlling_terminal_and_cleanup_are_bound(self):
        for mutate in (lambda r:r["workerTTY"].update(foregroundGroup=999),lambda r:r["workerTTY"].update(device=43),
            lambda r:r["workerTTY"].update(path="/dev/ttys002"),lambda r:r["workerTTY"].update(characterDevice=False),
            lambda r:r["cleanup"].update(appReaped=False),lambda r:r["cleanup"].update(workerGone=False),
            lambda r:r["cleanup"]["worker"].update(termiosRestored=False),lambda r:r["cleanup"]["worker"].update(generation=2)):
            with self.subTest(mutate=mutate):self.reject(mutate)

    def test_native_generated_bgra_proof_has_identical_independent_semantics(self):
        path=os.environ.get("STARTUP_NATIVE_TEST_PROOF")
        if not path:self.skipTest("generated native proof is supplied by startup_build.py")
        value,spec=fixture(json.loads(Path(path).read_text()))
        self.assertTrue(validate(value,spec,SPEC_SHA)["diagnosticValid"])
        output=os.environ.get("STARTUP_GENERATED_RAW_OUTPUT")
        if output:
            root=Path(output);root.mkdir(mode=0o700,parents=True,exist_ok=False)
            raw=canonical(spec);spec_sha=hashlib.sha256(raw).hexdigest();value["specSHA256"]=spec_sha
            value["syntheticTestFixture"]=True
            (root/"spec.json").write_bytes(raw);(root/"record.json").write_bytes(canonical(value))
            (root/"validation.json").write_bytes(canonical(validate(value,spec,spec_sha)))
            changed=deepcopy(value);changed["frames"][0]["checkedTicks"]=1001
            (root/"capture-attached-after-launch.json").write_bytes(canonical(changed))
            with self.assertRaisesRegex(ValueError,"attached after"):
                validate(changed,spec,spec_sha)

    def test_preparation_is_isolated_and_never_launches(self):
        value,spec=fixture()
        display={k:spec[k] for k in ("displayID","displayMode","displayBounds","lowPowerMode","thermalState")}
        with tempfile.TemporaryDirectory() as directory,patch("subprocess.Popen",side_effect=AssertionError("unexpected launch")):
            root=Path(directory);app=root/"generated-app";app.write_bytes(b"generated inert executable")
            for name in ("cmdy","ghostty"):
                result=prepare(root/name,name,app,display,token=TOKEN)
                made=json.loads(Path(result["spec"]).read_text())
                self.assertFalse(result["qualifying"]);self.assertEqual(list((root/name/"worker").iterdir()),[])
                self.assertEqual(made["executableSHA256"],hashlib.sha256(app.read_bytes()).hexdigest())
                self.assertIn("exec ",(root/name/"zsh/.zshenv").read_text())
                self.assertNotIn("CMDY_FRAME_TRACE",made["environment"])
                for path,h in made["inputFiles"].items():self.assertEqual(hashlib.sha256(Path(path).read_bytes()).hexdigest(),h)
                self.assertEqual(Path(result["spec"]).stat().st_mode&0o777,0o600)
                with self.assertRaises(FileExistsError):prepare(root/name,name,app,display,token=TOKEN)

    def test_nondefault_preparation_pins_target_and_public_ghostty_request(self):
        _,spec=fixture();display={k:spec[k] for k in ("displayID","displayMode","displayBounds","lowPowerMode","thermalState")}
        with tempfile.TemporaryDirectory() as directory,patch("subprocess.Popen",side_effect=AssertionError("unexpected launch")):
            root=Path(directory);app=root/"inert-app";app.write_bytes(b"never executed")
            prepared=prepare(root/"inputs","ghostty",app,display,token=TOKEN,target_grid=(98,24))
            made=json.loads(Path(prepared["spec"]).read_text())
            self.assertEqual(prepared["targetGrid"],made["targetGrid"])
            self.assertEqual(made["targetGrid"],[98,24])
            config=(root/"inputs/ghostty.config").read_text()
            self.assertIn("window-width = 96\n",config);self.assertIn("window-height = 23\n",config)
            prepared["targetGrid"]=[98,25]
            (root/"inputs/prepared.json").write_text(json.dumps(prepared))
            with self.assertRaisesRegex(ValueError,"prepared target grid differs"):
                record(root/"inputs/prepared.json",root/"missing",root/"missing-build",root/"output")

    def test_changed_prepared_source_is_rejected_before_any_launch(self):
        _,spec=fixture();display={k:spec[k] for k in ("displayID","displayMode","displayBounds","lowPowerMode","thermalState")}
        with tempfile.TemporaryDirectory() as directory,patch("subprocess.Popen",side_effect=AssertionError("unexpected launch")):
            root=Path(directory);app=root/"generated-app";app.write_bytes(b"inert")
            prepare(root/"run","cmdy",app,display,token=TOKEN)
            (root/"run/tooling/startup_fixture.py").write_text("changed")
            with self.assertRaisesRegex(ValueError,"input changed"):
                record(root/"run/prepared.json",root/"missing-observer",root/"missing-build",root/"output")

    def test_owned_observer_cleanup_reaps_graceful_and_stalled_processes(self):
        import subprocess
        from unittest.mock import Mock
        for timeout in (False,True):
            child=Mock();child.poll.return_value=None
            if timeout:child.wait.side_effect=[subprocess.TimeoutExpired("generated",8),-9]
            stop_observer(child)
            child.terminate.assert_called_once()
            self.assertEqual(child.wait.call_count,2 if timeout else 1)
            self.assertEqual(child.kill.call_count,int(timeout))
        child=Mock();child.poll.return_value=0;stop_observer(child);child.terminate.assert_not_called()

    def test_native_failure_distinguishes_missing_or_invalid_raw_without_defaults_access(self):
        from unittest.mock import Mock
        from startup_build import OBSERVER_SOURCES
        from startup_recorder import HERE, PREPARATION_SOURCES, sha
        _,spec=fixture()
        display={k:spec[k] for k in ("displayID","displayMode","displayBounds","lowPowerMode","thermalState")}
        for malformed in (False,True):
            with self.subTest(malformed=malformed),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);app=root/"inert-app";app.write_bytes(b"never executed")
                prepare(root/"inputs","cmdy",app,display,token=TOKEN)
                observer=root/"inert-observer";observer.write_bytes(b"never executed")
                build=root/"build.json";build.write_text(json.dumps(dict(nativeObservationRun=False,
                    headlessQualified=True,binarySHA256=sha(observer),
                    sourceSHA256={name:sha(HERE/name) for name in OBSERVER_SOURCES},
                    toolingSHA256={name:sha(HERE/name) for name in PREPARATION_SOURCES})))
                output=root/"observation"
                child=Mock();child.pid=123;child.returncode=2;child.wait.return_value=2;child.poll.return_value=2
                def launch(*_,**__):
                    if malformed:(output/"raw.json").write_text("null")
                    return child
                expected="invalid" if malformed else "missing"
                with patch("subprocess.Popen",side_effect=launch), \
                        patch("subprocess.run",side_effect=AssertionError("unexpected defaults access")), \
                        self.assertRaisesRegex(ValueError,"raw receipt "+expected):
                    record(root/"inputs/prepared.json",observer,build,output)
                result=json.loads((output/"result.json").read_text())
                self.assertEqual(result["nativeReceipt"]["status"],expected)
                self.assertTrue(result["observerReaped"]);self.assertFalse(result["diagnosticValid"])
                self.assertEqual(result["ownedDefaultsCleanup"]["status"],"deferred")
                self.assertFalse(result["ownedDefaultsCleanup"]["complete"])
                if malformed:self.assertEqual((output/"raw.json").read_text(),"null")
                else:self.assertFalse((output/"raw.json").exists())

    def test_excessive_proof_inventory_is_not_admitted(self):
        self.reject(lambda r:r.update(proofs={str(i):{} for i in range(9)}))

    def test_defaults_cleanup_is_scoped_and_follows_owned_process_cleanup(self):
        import subprocess
        domain="com.cmdy.startup."+"a"*32
        spec=dict(environment=dict(CMDY_DEFAULTS_DOMAIN=domain));manifest=dict(terminal="cmdy",defaultsDomain=domain)
        raw=dict(cleanup=dict(appReaped=True,workerGone=True))
        outputs=[subprocess.CompletedProcess([],0,"<plist>generated only</plist>",""),
            subprocess.CompletedProcess([],0,"",""),subprocess.CompletedProcess([],1,"",f"Domain {domain} does not exist")]
        with patch("subprocess.run",side_effect=outputs) as run:
            result=cleanup_defaults(spec,manifest,raw)
            self.assertTrue(result["complete"]);self.assertTrue(result["persisted"])
            self.assertEqual([c.args[0] for c in run.call_args_list],[["/usr/bin/defaults","export",domain,"-"],
                ["/usr/bin/defaults","delete",domain],["/usr/bin/defaults","export",domain,"-"]])
        with patch("subprocess.run",side_effect=AssertionError("unexpected defaults access")):
            self.assertFalse(cleanup_defaults(spec,manifest,dict(cleanup=dict(appReaped=False,workerGone=False)))["complete"])
            self.assertTrue(cleanup_defaults(spec,dict(terminal="ghostty"),raw)["complete"])
            for other in ("com.cmdy", "com.apple.Terminal", domain+"/../other"):
                with self.subTest(other=other),self.assertRaises(ValueError):
                    cleanup_defaults(dict(environment=dict(CMDY_DEFAULTS_DOMAIN=other)),dict(terminal="cmdy",defaultsDomain=other),raw)

    def test_absent_suite_or_defaults_error_cannot_masquerade_as_a_delete(self):
        import subprocess
        domain="com.cmdy.startup."+"b"*32
        spec=dict(environment=dict(CMDY_DEFAULTS_DOMAIN=domain));manifest=dict(terminal="cmdy",defaultsDomain=domain)
        raw=dict(cleanup=dict(appReaped=True,workerGone=True))
        with patch("subprocess.run",return_value=subprocess.CompletedProcess([],1,"",f"Domain {domain} does not exist")) as run:
            result=cleanup_defaults(spec,manifest,raw);self.assertTrue(result["complete"]);self.assertFalse(result["persisted"])
            self.assertEqual(run.call_count,1)
        with patch("subprocess.run",return_value=subprocess.CompletedProcess([],1,"","permission denied")):
            self.assertFalse(cleanup_defaults(spec,manifest,raw)["complete"])

    def test_empty_post_delete_export_requires_exact_absence_evidence(self):
        import subprocess, plistlib
        domain="com.cmdy.startup."+"c"*32
        spec=dict(environment=dict(CMDY_DEFAULTS_DOMAIN=domain));manifest=dict(terminal="cmdy",defaultsDomain=domain)
        raw=dict(cleanup=dict(appReaped=True,workerGone=True))
        for error, accepted in [(f"Domain ({domain}) not found.\nDefaults have not been changed.\n", True),
                                ("permission denied", False),
                                ("Domain (com.cmdy) not found.\nDefaults have not been changed.\n", False)]:
            outputs=[subprocess.CompletedProcess([],0,plistlib.dumps({'fixture':True}).decode(),''),
                subprocess.CompletedProcess([],0,'',''),subprocess.CompletedProcess([],0,plistlib.dumps({}).decode(),''),
                subprocess.CompletedProcess([],1,'',error)]
            with patch('subprocess.run', side_effect=outputs):
                self.assertEqual(cleanup_defaults(spec,manifest,raw)['complete'],accepted)

if __name__=="__main__":unittest.main()
