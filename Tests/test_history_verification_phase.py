"""Generated-only phase, ordering and private-PTY checks; no native helper/app."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import history_export_phase as phase
from history_export_binding import install_binding, validate_binding, cmdy_store_bytes
from history_export_controller import control, binding_config
from history_export_evidence import validate_transfer, validate_viewport
from history_export_protocol import expectation, expected_bytes, memory_payload, digest, validate_export_bytes
from memory_parity_evidence import validate_post_sample_history_phase
from memory_public_history import PublicHistorySession
from terminal_bench_worker import expected_reply
import test_history_export as fixtures
from test_history_scope import file_transfer_fixture


def phase_fixture(case='primary-1000'):
    spec=expectation(case,fixtures.NONCE); payload=memory_payload(spec); footer,reply=expected_reply(36,120,0)
    drained=dict(sequence=0,elapsedNS=10,startedMonotonicNS=10,finishedMonotonicNS=20,
        payloadBytes=len(payload),footerHex=footer.hex(),responseHex=reply.hex(),expectedResponseHex=reply.hex(),
        gridBefore=dict(columns=120,rows=36),gridAfter=dict(columns=120,rows=36))
    prepared=dict(expectation=spec,grid=dict(columns=120,rows=36),bytes=len(payload),sha256=digest(payload),drain=drained)
    contract=phase.contract(case)
    value=dict(schemaVersion=1,contract=contract,workerPID=123,nonce=fixtures.NONCE,drainFinishedMonotonicNS=20,
        boundary=dict(kind='untimed-drain',finishedMonotonicNS=20),startedTicks=51,finishedTicks=79,
        startedMonotonicNS=50,finishedMonotonicNS=80,gridBefore=contract['grid'],gridAfter=contract['grid'],
        writtenBytes=contract['payloadBytes'],responseHex=contract['expectedReplyHex'])
    return spec,prepared,value


def transfer_phase_fixture(case='primary-1000'):
    document,raw=file_transfer_fixture(case);spec,prepared,value=phase_fixture(case)
    value.update(workerPID=document['workerReady']['pid'],startedTicks=250,finishedTicks=260)
    document.update(schemaVersion=3,workerPrepared=prepared,verificationPhase=value)
    document['nativeSpec'].update(verificationPolicy=phase.POLICY,exportCase=case)
    document['workerReady'].update(verificationPolicy=phase.POLICY,startedTicks=1,
        payloadBytes=prepared['bytes'],payloadSHA256=prepared['sha256'])
    document['workerArm']['verificationPhase']=value
    document['action']['intendedAction']=phase.contract(case)['action']
    return document,raw


class VerificationPhaseTests(unittest.TestCase):
    def test_fixed_primary_bytes_and_zero_alternate_bytes_leave_payloads_unchanged(self):
        for case in phase.CASES:
            before=memory_payload(expectation(case,fixtures.NONCE)); value=phase.contract(case)
            self.assertEqual(value['grid'],dict(columns=120,rows=36))
            if case.startswith('primary'):
                self.assertEqual(bytes.fromhex(value['payloadHex']),b'\x1b[36;1H'+b'\r\n'*35+b'\x1b[6n')
                self.assertEqual(value['payloadBytes'],81);self.assertEqual(value['blankLines'],35)
                self.assertEqual(value['expectedReplyHex'],b'\x1b[36;1R'.hex())
            else:
                self.assertEqual((value['payloadHex'],value['payloadBytes'],value['blankLines'],value['expectedReplyHex']),('',0,0,''))
                self.assertEqual(value['action'],'write_screen_file:paste')
            self.assertEqual(before,memory_payload(expectation(case,fixtures.NONCE)))

    def test_complete_original_counts_and_padding_limits_stay_exact(self):
        for case,count in [('primary-1000',1000),('primary-5000',5000),('alternate-continuous',35)]:
            spec=expectation(case,fixtures.NONCE);raw=expected_bytes(spec).replace(b'\r\n',b'\n')
            self.assertEqual(validate_export_bytes(raw,spec)['logicalRows'],count)
            self.assertEqual(validate_export_bytes(raw+b'\n'*36,spec)['trailingEmptyRows'],37)
            with self.assertRaisesRegex(ValueError,'outer-padding'):validate_export_bytes(raw+b'\n'*37,spec)
            with self.assertRaises(ValueError):validate_export_bytes(b'\n'.join(raw.split(b'\n')[:-36]),spec)
        spec=expectation('alternate-continuous',fixtures.NONCE)
        with self.assertRaises(ValueError):validate_export_bytes(b'A'*120+b'\n'+expected_bytes(spec),spec)

    def test_policy_and_case_selection_cannot_borrow_legacy_or_resize(self):
        self.assertEqual(phase.selected_action(),'write_scrollback_file:paste')
        for case,policy in [('resize',phase.POLICY),('alternate-continuous',None),(None,phase.POLICY),('primary-1000','unknown')]:
            with self.assertRaises(ValueError):phase.selected_action(case,policy)

    def test_missing_duplicate_reordered_and_unprepared_phase_reject(self):
        spec,prepared,value=phase_fixture()
        self.assertEqual(phase.authorize_phase('prepared',phase.POLICY,spec,prepared,value['boundary']),value['contract'])
        for mode in ('ready','verified','armed','received'):
            with self.assertRaises(ValueError):phase.authorize_phase(mode,phase.POLICY,spec,prepared,value['boundary'])
        with self.assertRaises(ValueError):phase.authorize_phase('prepared',None,spec,prepared,value['boundary'])
        for mode in ('ready','prepared','armed','received'):
            with self.assertRaises(ValueError):phase.authorize_arm(mode,phase.POLICY)
        phase.authorize_arm('verified',phase.POLICY);phase.authorize_arm('prepared',None)

    def test_phase_replay_rejects_wrong_bytes_reply_grid_identity_types_and_order(self):
        spec,prepared,value=phase_fixture()
        self.assertFalse(phase.validate_phase(value,spec,123,prepared,timebase=(1,1))['qualifying'])
        edits=[lambda d:d.update(workerPID=999),lambda d:d.update(workerPID=True),lambda d:d.update(nonce='a'*32),
            lambda d:d.update(schemaVersion=True),lambda d:d.update(writtenBytes=0),lambda d:d.update(responseHex=b'\x1b[35;1R'.hex()),
            lambda d:d.update(gridAfter=dict(columns=119,rows=36)),lambda d:d.update(startedMonotonicNS=19),
            lambda d:d.update(finishedTicks=90),lambda d:d.update(drainFinishedMonotonicNS=19),
            lambda d:d['boundary'].update(finishedMonotonicNS=21),lambda d:d['contract'].update(blankLines=36),
            lambda d:d['contract'].update(schemaVersion=True),lambda d:d['contract'].update(payloadHex=''),
            lambda d:d.update(contents='unrecognized'),lambda d:d.update(path='/unrecognized')]
        for edit in edits:
            wrong=deepcopy(value);edit(wrong)
            with self.assertRaises(ValueError):phase.validate_phase(wrong,spec,123,prepared,timebase=(1,1))

    def test_all_six_samples_must_finish_before_phase_and_keep_original_offsets(self):
        spec,prepared,value=phase_fixture();value.update(startedMonotonicNS=100,startedTicks=101,finishedTicks=109,finishedMonotonicNS=110)
        labels=['matched-grid-before-settle','settled-idle-baseline','settled-idle-cpu-end','post-output-0s','post-output-1s','post-output-5s']
        samples=[dict(label=label,guardStartedMonotonicNS=21+i*10,guardFinishedMonotonicNS=25+i*10,
            requestedOffsetSeconds=None if i<3 else (0,1,5)[i-3]) for i,label in enumerate(labels)]
        value['boundary']=dict(kind='all-memory-samples',finishedMonotonicNS=75)
        self.assertFalse(validate_post_sample_history_phase(samples,value,spec,123,prepared,(1,1))['memoryAdmission'])
        for edit in (lambda s:s.pop(),lambda s:s.reverse(),lambda s:s.append(deepcopy(s[-1])),
                     lambda s:s[-1].update(guardFinishedMonotonicNS=101),lambda s:s[-1].update(requestedOffsetSeconds=6)):
            wrong=deepcopy(samples);edit(wrong)
            with self.assertRaises((ValueError,RuntimeError)):validate_post_sample_history_phase(wrong,value,spec,123,prepared,(1,1))

    def test_cleanup_replay_rejects_missing_duplicate_reordered_phase(self):
        spec,prepared,value=phase_fixture()
        cleanup=dict(status='pass',pid=123,nonce=fixtures.NONCE,finishedTicks=150,
            controls=[dict(op=op,ticks=tick) for op,tick in [('drain',9),('verify-history',49),('arm',90),('status',110),('finish',140)]])
        arm=dict(armedTicks=95)
        phase.validate_phase_cleanup(cleanup,value,arm)
        for edit in (lambda d:d['controls'].pop(1),lambda d:d['controls'].insert(2,deepcopy(d['controls'][1])),
                     lambda d:d['controls'].reverse(),lambda d:d['controls'][1].update(ticks=81)):
            wrong=deepcopy(cleanup);edit(wrong)
            with self.assertRaises(ValueError):phase.validate_phase_cleanup(wrong,value,arm)

    def test_real_binding_stores_select_only_case_specific_paste_action(self):
        for case in phase.CASES:
            with tempfile.TemporaryDirectory(dir='/private/tmp') as name:
                root=Path(name)
                for terminal in ('cmdy','ghostty'):
                    directory=root/terminal;directory.mkdir(mode=0o700);config=directory/'config';config.write_text('font-size = 14\n')
                    receipt=install_binding(terminal,config,case=case,policy=phase.POLICY)
                    self.assertEqual(receipt['intendedAction'],phase.contract(case)['action'])
                    self.assertFalse(receipt['actionInvocationVerified'])
                    validate_binding(terminal,config,receipt,case=case,policy=phase.POLICY)
                    with self.assertRaises(ValueError):validate_binding(terminal,config,dict(receipt,intendedAction='copy'),case=case,policy=phase.POLICY)
                    if case=='alternate-continuous':
                        with self.assertRaises(ValueError):validate_binding(terminal,config,receipt)
                command=json.loads(cmdy_store_bytes(case=case,policy=phase.POLICY))['mappings'][0]['command']['value']
                self.assertEqual(command,'writeScreenPaste' if case=='alternate-continuous' else 'writeScrollbackPaste')
                self.assertIn(phase.contract(case)['action'],binding_config('',case=case,verification_policy=phase.POLICY))

    def test_phased_full_transfers_replay_without_visual_or_partial_admission(self):
        for case in phase.CASES:
            document,raw=transfer_phase_fixture(case)
            result=validate_transfer(document,raw);self.assertFalse(result['qualifying']);self.assertFalse(result['viewportVerified'])
            for edit in (lambda d:d.update(schemaVersion=2),lambda d:d.pop('verificationPhase'),
                         lambda d:d['workerArm'].pop('verificationPhase'),lambda d:d['nativeSpec'].update(exportCase='resize'),
                         lambda d:d['workerReady'].update(payloadBytes=0),
                         lambda d:d['beforeOwner']['window'].update(queriedTicks=251),
                         lambda d:d['action'].update(intendedAction='copy_to_clipboard'),
                         lambda d:d['verificationPhase'].update(finishedMonotonicNS=101)):
                wrong=deepcopy(document);edit(wrong)
                with self.assertRaises((ValueError,KeyError)):validate_transfer(wrong,raw)
            with self.assertRaises(ValueError):validate_viewport({},document['expectation'],document['nativeSpec'])
            with self.assertRaises(ValueError):validate_transfer(document,raw[:len(raw)//2])

    def test_new_session_cannot_silently_enable_existing_memory_or_visual_admission(self):
        public=object.__new__(PublicHistorySession);public.verification_policy=phase.POLICY
        with self.assertRaisesRegex(RuntimeError,'no qualified memory/visual admission'):
            public.verify(None,None,None,None,verification_boundary={})

    def test_existing_full_memory_reader_rejects_resealed_new_transport(self):
        import memory_parity_evidence as evidence
        from memory_public_history import VERIFICATION_TRANSPORT
        from test_memory_public_evidence import build_fixture, run_path, write, PublicMemoryEvidenceTests
        with tempfile.TemporaryDirectory(dir='/private/tmp') as name:
            root=Path(name);_,records=build_fixture(root);record=records[0];run=run_path(root,record)
            record['historyVerification'].update(schemaVersion=2,transport=VERIFICATION_TRANSPORT)
            write(run/'history-verification.json',record['historyVerification'])
            write(run/'memory.json',record);write(root/'records.json',records)
            with self.assertRaisesRegex(ValueError,'public history record differs'):
                evidence.load_memory_evidence(root,PublicMemoryEvidenceTests.pins)

    def test_controller_routes_phase_before_arm_and_keeps_visual_scope_closed(self):
        import history_export_controller as controller
        for case in phase.CASES:
            document,raw=transfer_phase_fixture(case);value=document['verificationPhase']
            with tempfile.TemporaryDirectory(dir='/private/tmp') as name:
                root=Path(name);fixture=root/'fixture';fixture.mkdir(mode=0o700)
                retained=fixture/'generated-export.bin';retained.write_bytes(raw);retained.chmod(0o600)
                cleanup=dict(status='pass',pid=value['workerPID'],nonce=fixtures.NONCE,finishedTicks=1200,
                    controls=[dict(op=op,ticks=tick) for op,tick in [('drain',9),('verify-history',249),('arm',290),('finish',1100)]])
                (fixture/'cleanup.json').write_text(json.dumps(cleanup))
                request=dict(schemaVersion=2,terminal='cmdy',case=case,nonce=fixtures.NONCE,
                    workerReady=document['workerReady'],workerCapability='f'*32,nativeSpec=document['nativeSpec'],
                    verificationPolicy=phase.POLICY,verificationBoundary=value['boundary'],fixtureDirectory=str(fixture))
                replies=[dict(mode='prepared',prepared=document['workerPrepared']),
                    dict(verificationPhase=value,prepared=document['workerPrepared']),dict(arm=document['workerArm']),
                    dict(mode='received',proof=document['export']),{}]
                with patch.object(controller,'validate_native_build',return_value={}), \
                        patch.object(controller,'native_request',side_effect=[dict(owner=document['beforeOwner']),document['action'],dict(owner=document['afterOwner'])]) as native, \
                        patch.object(controller,'control',side_effect=replies) as control_calls:
                    result=controller.collect_export(Path('/not-executed'),Path('/not-read'),request,root/'collected',viewport=False)
                    self.assertFalse(result['qualifying']);self.assertTrue(result['workerFinished'])
                    self.assertEqual([call.args[2] for call in control_calls.call_args_list],['status','verify-history','arm','status','finish'])
                    self.assertEqual([call.args[1] for call in native.call_args_list],['inspect','post-key','inspect'])
                    self.assertTrue(all(call.args[2]['exportCase']==case for call in native.call_args_list))
                with patch.object(controller,'validate_native_build') as build, patch.object(controller,'native_request') as native:
                    with self.assertRaises(ValueError):controller.collect_export(Path('/not-executed'),Path('/not-read'),request,root/'rejected',viewport=True)
                    build.assert_not_called();native.assert_not_called()


class VerificationPhasePTYTests(unittest.TestCase):
    def test_private_PTY_wrong_DSR_stops_before_arm_without_retaining_response(self):
        def observe(fixture,cleanup):
            self.assertEqual(cleanup['errorCode'],'verification-exact-DSR-failed')
            self.assertEqual(cleanup['status'],'failed');self.assertEqual(cleanup['inputBytesRetained'],0)
            self.assertFalse((fixture/'arm.json').exists());self.assertFalse((fixture/'export.json').exists())
            self.assertFalse((fixture/'verification-phase.json').exists());self.assertTrue(cleanup['controlSocketRemoved'])
        with self.assertRaisesRegex(ValueError,'worker-response-incomplete-or-unbounded'):
            fixtures.OwnedPTYTests.run_worker(self,'primary-1000',drain=True,verification_policy=phase.POLICY,
                reject_verification_reply=True,phase_failure_observer=observe)

    def test_primary1000_primary5000_and_alternate_keep_complete_generated_files(self):
        for case in phase.CASES:
            def observe(fixture,cleanup,ready,armed,emitted):
                value=json.loads((fixture/'verification-phase.json').read_text())
                prepared=json.loads((fixture/'prepared.json').read_text())
                spec=prepared['expectation'];phase.validate_phase(value,spec,ready['pid'],prepared)
                phase.validate_phase_cleanup(cleanup,value,armed['arm'])
                self.assertEqual(ready['verificationPolicy'],phase.POLICY)
                self.assertEqual(armed['arm']['verificationPhase'],value)
                control_bytes=bytes.fromhex(value['contract']['payloadHex'])
                if control_bytes:self.assertEqual(emitted.count(control_bytes),1)
                else:self.assertNotIn(b'\x1b[36;1H'+b'\r\n'*35,emitted)
                self.assertEqual(json.loads((fixture/'export.json').read_text())['validation']['logicalRows'],spec['logicalRows'])
            fixtures.OwnedPTYTests.run_worker(self,case,drain=True,verification_policy=phase.POLICY,success_observer=observe)

    def test_private_PTY_rejects_missing_and_duplicate_phase_before_file_export(self):
        class ExpectedRejection(Exception):pass
        for duplicate in (False,True):
            def before_arm(spec,exports):
                fixture=exports.parent/'fixture';ready=json.loads((fixture/'ready.json').read_text())
                prepared=json.loads((fixture/'prepared.json').read_text())
                try:
                    if duplicate:control(ready,'f'*32,'verify-history',boundary=dict(kind='untimed-drain',finishedMonotonicNS=prepared['drain']['finishedMonotonicNS']))
                    else:control(ready,'f'*32,'arm')
                except (ValueError,OSError):pass
                deadline=time.monotonic()+3
                while not (fixture/'cleanup.json').exists() and time.monotonic()<deadline:time.sleep(.01)
                cleanup=json.loads((fixture/'cleanup.json').read_text())
                self.assertEqual(cleanup['status'],'failed')
                self.assertEqual(cleanup['errorCode'],'verification-must-follow-one-original-drain' if duplicate else 'arm-must-follow-one-preparation-or-verification')
                self.assertFalse((fixture/'export.json').exists());self.assertFalse((fixture/'generated-export.bin').exists())
                self.assertTrue(cleanup['controlSocketRemoved']);raise ExpectedRejection()
            with self.assertRaises(ExpectedRejection):
                fixtures.OwnedPTYTests.run_worker(self,'primary-1000',drain=True,verification_policy=phase.POLICY,
                    run_verification=duplicate,pre_arm=before_arm)

    def test_private_PTY_partial_history_still_fails_after_valid_verification(self):
        def exporter(spec,exports):
            path=exports/'generated-prefix.txt';path.write_bytes(b'\n'.join(expected_bytes(spec).split(b'\r\n')[:965])+b'\n');path.chmod(0o600);return path
        def observe(fixture,cleanup,ready,armed):
            self.assertTrue((fixture/'verification-phase.json').is_file())
            self.assertEqual(json.loads((fixture/'missing-generated-row.json').read_text())['matchedPrefixRows'],965)
        fixtures.OwnedPTYTests.run_worker(self,'primary-1000',drain=True,verification_policy=phase.POLICY,
            exporter=exporter,expected_error='missing-generated-row',failed_export_unlinked=True,failure_observer=observe)


if __name__=='__main__':unittest.main()
