"""Generated file evidence and cross-protocol negatives; no native actions."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from history_export_evidence import validate_owner, validate_transfer, validate_viewport, validate_resize_pilot
from history_export_protocol import FILE_PROOF_SCOPE
from test_history_export import transfer_fixture
import test_history_export as existing


def file_window(window):
    value = deepcopy(window); value.pop('occluded', None)
    value.update(schemaVersion=2, proofScope=FILE_PROOF_SCOPE, visualVisibilityVerified=False,
                 onScreen=True, alpha=1)
    return value


def file_transfer_fixture(case='primary-1000'):
    document, raw = transfer_fixture(case)
    document['schemaVersion'] = 2; document['nativeSpec']['proofScope'] = FILE_PROOF_SCOPE
    for owner in (document['beforeOwner'], document['afterOwner'],
                  document['action']['beforeOwner'], document['action']['afterOwner']):
        owner['window'] = file_window(owner['window'])
    return document, raw


class HistoryScopeTests(unittest.TestCase):
    def test_session_requires_explicit_file_scope_and_keeps_memory_default(self):
        from memory_public_history import PublicHistorySession
        for file_only in (False, True):
            document, raw = file_transfer_fixture() if file_only else transfer_fixture('primary-1000')
            with self.subTest(fileOnly=file_only), tempfile.TemporaryDirectory(dir='/private/tmp') as name:
                directory = Path(name); fixture = directory / 'fixture'; fixture.mkdir(mode=0o700)
                retained = fixture / 'generated-export.bin'; retained.write_bytes(raw); retained.chmod(0o600)
                (fixture / 'export.json').write_text(json.dumps(document['export']))
                public = object.__new__(PublicHistorySession)
                public.verification_policy = None
                public.directory = directory; public.fixture = fixture; public.nonce = document['expectation']['nonce']
                public.expected = document['expectation']
                public.session = SimpleNamespace(app_pid=document['nativeSpec']['pid'], terminal='cmdy',
                    worker_identity=(document['nativeSpec']['workerPID'], 'generated-identity'), ready=document['workerReady'],
                    options=SimpleNamespace(cmdy_bin=Path('/generated/cmdy')))
                public.control = lambda op: {'arm': document['workerArm']} if op == 'arm' else {'mode': 'received', 'proof': document['export']}
                observed = []
                def native(arguments):
                    observed.append(json.loads(Path(arguments[-1]).read_text()))
                    if arguments[1] == 'post-key': return document['action']
                    return {'owner': document['beforeOwner'] if len(observed) == 1 else document['afterOwner']}
                with patch('memory_public_history.sha256', return_value='a' * 64):
                    result = public.verify(Path('/generated/helper'), native,
                        {'windows': [{'windowID': 10, 'displayID': 1}]}, (1, 1), **({'file_transport': True} if file_only else {}))
                self.assertEqual(result['transfer']['schemaVersion'], 2 if file_only else 1)
                self.assertEqual([v.get('proofScope') for v in observed], [FILE_PROOF_SCOPE if file_only else None] * 3)
                self.assertFalse(result['transferValidation']['viewportVerified'])

    def test_complete_generated_file_transfers_make_no_visual_claim(self):
        for case, count in [('primary-1000', 1000), ('primary-5000', 5000), ('alternate-continuous', 35)]:
            document, raw = file_transfer_fixture(case)
            result = validate_transfer(document, raw)
            self.assertEqual(result['generatedHistory']['logicalRows'], count)
            self.assertFalse(result['viewportVerified']); self.assertFalse(result['qualifying'])
            self.assertNotIn('occluded', document['beforeOwner']['window'])

    def test_version_scope_and_false_visual_claim_cannot_be_mixed(self):
        document, raw = file_transfer_fixture()
        changes = [lambda d: d.update(schemaVersion=1),
            lambda d: d['nativeSpec'].pop('proofScope'),
            lambda d: d['nativeSpec'].update(proofScope='unknown'),
            lambda d: d['afterOwner']['window'].update(occluded=False),
            lambda d: d['afterOwner']['window'].update(visualVisibilityVerified=True),
            lambda d: d['afterOwner']['window'].pop('visualVisibilityVerified'),
            lambda d: d['afterOwner']['window'].update(schemaVersion=1)]
        for mutate in changes:
            wrong = deepcopy(document); mutate(wrong)
            with self.assertRaises(ValueError): validate_transfer(wrong, raw)
        old, raw = transfer_fixture('primary-1000')
        self.assertFalse(validate_transfer(old, raw)['viewportVerified'])
        old['afterOwner']['window']['occluded'] = True
        with self.assertRaises(ValueError): validate_transfer(old, raw)

    def test_file_scope_keeps_process_grid_file_action_and_clock_checks(self):
        document, raw = file_transfer_fixture()
        changes = [lambda d: d['afterOwner']['window'].update(foregroundPID=999),
            lambda d: d['afterOwner']['window'].update(onScreen=False),
            lambda d: d['afterOwner']['window'].update(alpha=0.5),
            lambda d: d['afterOwner']['window']['bounds'].update(width=0),
            lambda d: d['afterOwner']['window']['bounds'].update(x=float('nan')),
            lambda d: d['afterOwner']['grid'].update(columns=119),
            lambda d: d['afterOwner'].update(workerForegroundGroup=99),
            lambda d: d['afterOwner']['ancestry']['secondWalkReverse'].pop(),
            lambda d: d['action'].update(targetPID=999),
            lambda d: d['action'].update(eventCount=1),
            lambda d: d['action'].update(beforeTicks=1),
            lambda d: d['export']['opened'].update(mode=0o100644),
            lambda d: d['export']['chunks'][0].update(bytes=1)]
        for mutate in changes:
            wrong = deepcopy(document); mutate(wrong)
            with self.assertRaises(ValueError): validate_transfer(wrong, raw)
        with self.assertRaises(ValueError): validate_transfer(document, raw[:-100])

    def test_file_scope_is_not_a_resize_history_viewport(self):
        document, raw = file_transfer_fixture('resize')
        with self.assertRaises(ValueError): validate_transfer(document, raw)
        with self.assertRaises(ValueError): validate_resize_pilot(document, raw, {})

    def test_observe_and_resize_reject_file_proofs_even_with_forged_occluded_false(self):
        from resize_evidence import validate_proof
        from resize_calibration_evidence import validate_discovery
        from test_resize_calibration import rehash
        document, raw, cleanup = existing.ViewportEvidenceTests().fixture()
        observation = document['beforeViewport']
        proof = file_window(observation['beforeOwner']['window']); proof['occluded'] = False
        wrong = deepcopy(observation); wrong['beforeOwner']['window'] = proof
        with self.assertRaises(ValueError): validate_viewport(wrong, document['expectation'], document['nativeSpec'])
        with self.assertRaises(ValueError): validate_owner(dict(document['beforeOwner'], window=proof), document['nativeSpec'])
        with self.assertRaises(ValueError): validate_proof(proof, {})
        discovery = deepcopy(observation['discovery']); evidence = json.loads(discovery['evidenceUTF8'])
        evidence['window'] = proof; rehash(discovery, evidence)
        with self.assertRaises(ValueError): validate_discovery(discovery)
        self.assertTrue(validate_resize_pilot(document, raw, cleanup)['viewportVerified'])

    def test_startup_rejects_file_proof_even_with_forged_occluded_false(self):
        from startup_evidence_tests import fixture, SPEC_SHA
        from startup_evidence import validate
        value, spec = fixture()
        self.assertTrue(validate(value, spec, SPEC_SHA)['diagnosticValid'])
        value['finalProof'] = file_window(value['finalProof']); value['finalProof']['occluded'] = False
        with self.assertRaises(ValueError): validate(value, spec, SPEC_SHA)


if __name__ == '__main__': unittest.main()
