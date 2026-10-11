"""Failure-only generated prefix counts; no app, helper, clipboard or capture."""
from copy import deepcopy
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import Mock, patch

import history_export_protocol as protocol
from history_export_worker import retain_missing_row
import test_history_export as fixtures

FIELDS = {"schemaVersion", "purpose", "qualifying", "expectedRows", "matchedPrefixRows", "expectedRowIndex",
          "physicalLineCount", "physicalCursor", "leadingEmptyRows", "trailingEmptyRows", "rawBytes"}
WORKER_FIELDS = FIELDS | {"pid", "nonce", "armedTicks", "finishedTicks"}


def prefix(spec, count, *, wrapped=False, leading=0, trailing=1):
    rows = protocol.expected_bytes(spec).split(b"\r\n")[:-1][:count]
    if wrapped: rows = [row[index:index+120] for row in rows for index in range(0, len(row), 120)]
    return b"\n" * leading + b"\n".join(rows) + b"\n" * trailing


def rejection(raw, spec):
    try: protocol.validate_export_bytes(raw, spec)
    except ValueError as failure: return failure
    raise AssertionError("partial generated fixture must remain rejected")


class PrefixDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.spec = protocol.expectation('primary-1000', fixtures.NONCE)

    def test_exact_prefix_counts_identify_first_missing_zero_based_row(self):
        for count in (1, 7, 500, 964, 999):
            raw = prefix(self.spec, count, leading=2, trailing=3)
            failure = rejection(raw, self.spec); value = protocol.missing_row_metadata(failure)
            self.assertIs(type(failure), ValueError); self.assertEqual(str(failure), 'missing-generated-row')
            self.assertEqual(value, dict(schemaVersion=1, purpose='missing-generated-row-prefix-counts', qualifying=False,
                expectedRows=1000, matchedPrefixRows=count, expectedRowIndex=count,
                physicalLineCount=count, physicalCursor=count, leadingEmptyRows=2, trailingEmptyRows=3, rawBytes=len(raw)))
            text = json.dumps(value)
            self.assertNotIn(fixtures.NONCE, text); self.assertNotIn('sha', text.lower()); self.assertNotIn('path', text.lower())

    def test_empty_input_keeps_size_failure_but_bounded_blank_input_has_zero_prefix(self):
        failure = rejection(b'', self.spec)
        self.assertEqual(str(failure), 'export-size-outside-bound'); self.assertIsNone(protocol.missing_row_metadata(failure))
        for raw in (b' ', b'\n', b' \r\n\n'):
            value = protocol.missing_row_metadata(rejection(raw, self.spec))
            self.assertEqual((value['matchedPrefixRows'], value['expectedRowIndex'], value['physicalLineCount'], value['physicalCursor']), (0,0,0,0))
            self.assertEqual(value['rawBytes'], len(raw)); self.assertEqual(value['trailingEmptyRows'], 0)

    def test_wrapped_prefix_counts_complete_logical_rows_and_consumed_physical_lines(self):
        spec = protocol.expectation('resize', fixtures.NONCE)
        raw = prefix(spec, 8, wrapped=True, leading=1, trailing=2)
        value = protocol.missing_row_metadata(rejection(raw, spec))
        self.assertEqual((value['matchedPrefixRows'], value['expectedRowIndex'], value['physicalLineCount'], value['physicalCursor']), (8,8,16,16))
        self.assertEqual((value['leadingEmptyRows'], value['trailingEmptyRows'], value['rawBytes']), (1,2,len(raw)))
        for case, count in (('alternate-continuous', 1), ('primary-5000', 4999)):
            spec = protocol.expectation(case, fixtures.NONCE)
            value = protocol.missing_row_metadata(rejection(prefix(spec, count), spec))
            self.assertEqual(value['expectedRows'], spec['logicalRows']); self.assertEqual(value['physicalCursor'], count)

    def test_middle_corruption_missing_first_row_and_half_wrapped_row_get_no_annotation(self):
        rows = protocol.expected_bytes(self.spec).split(b'\r\n')[:-1]
        bad = [b'\n'.join(rows[:3]+[b'UnrecognizedPrivateText']+rows[4:7])+b'\n',
               b'\n'.join(rows[1:7])+b'\n', b'\n'.join(rows[:2]+rows[:2])+b'\n',
               prefix(self.spec, 7)+b'\x00', prefix(self.spec, 7)+b'\xff', b'\n'*10000]
        for raw in bad:
            error = rejection(raw, self.spec)
            self.assertNotEqual(str(error), 'missing-generated-row'); self.assertIsNone(protocol.missing_row_metadata(error))
            self.assertFalse(hasattr(error, '_cmdy_missing_row_counts'))
        spec = protocol.expectation('resize', fixtures.NONCE)
        row = protocol.expected_bytes(spec).split(b'\r\n')[0]
        self.assertIsNone(protocol.missing_row_metadata(rejection(row[:120]+b'\n', spec)))

    def test_same_original_exception_object_and_message_survive_annotation(self):
        original = ValueError('missing-generated-row'); real = protocol.require
        def required(condition, code):
            if code == 'missing-generated-row' and not condition: raise original
            real(condition, code)
        with patch.object(protocol, 'require', side_effect=required):
            failure = rejection(prefix(self.spec, 7), self.spec)
        self.assertIs(failure, original); self.assertEqual(str(original), 'missing-generated-row')
        self.assertEqual(protocol.missing_row_metadata(original)['matchedPrefixRows'], 7)

    def test_annotation_construction_failure_preserves_original_error(self):
        original = ValueError('missing-generated-row'); real = protocol.require
        def required(condition, code):
            if code == 'missing-generated-row' and not condition: raise original
            real(condition, code)
        with patch.object(protocol, 'require', side_effect=required), \
                patch.object(protocol, 'validated_missing_row_counts', side_effect=MemoryError('generated diagnostic failure')):
            self.assertIs(rejection(prefix(self.spec, 7), self.spec), original)
        self.assertFalse(hasattr(original, '_cmdy_missing_row_counts'))

    def test_whitelist_rejects_forged_fields_types_bounds_and_inconsistent_counts(self):
        original = protocol.missing_row_metadata(rejection(prefix(self.spec, 7), self.spec))
        class FalseString(str):
            def __eq__(self, other): return True
            def __ne__(self, other): return False
        edits = [lambda d: d.update(path='UnknownPrivatePath'), lambda d: d.update(rawSHA256='a'*64),
                 lambda d: d.update(contents='UnknownPrivateText'), lambda d: d.update(schemaVersion=True),
                 lambda d: d.update(qualifying=True), lambda d: d.update(purpose=FalseString('UnknownPrivateText')),
                 lambda d: d.update(expectedRows=999), lambda d: d.update(matchedPrefixRows=1000),
                 lambda d: d.update(expectedRowIndex=8), lambda d: d.update(physicalCursor=8),
                 lambda d: d.update(physicalLineCount=15, physicalCursor=15), lambda d: d.update(physicalLineCount=6, physicalCursor=6),
                 lambda d: d.update(leadingEmptyRows=74), lambda d: d.update(trailingEmptyRows=74),
                 lambda d: d.update(rawBytes=0), lambda d: d.update(rawBytes=protocol.FILE_LIMIT+1),
                 lambda d: d.update(rawBytes=1), lambda d: d.pop('rawBytes')]
        for key in FIELDS - {'purpose','qualifying'}:
            for value in (True, -1, 1.0, '7', 1 << 63):
                edits.append(lambda d, key=key, value=value: d.update({key:value}))
        for edit in edits:
            value = deepcopy(original); edit(value); error = ValueError('missing-generated-row')
            error._cmdy_missing_row_counts = value
            clock = Mock(side_effect=AssertionError('invalid metadata must not query time'))
            with patch('history_export_worker.save') as save:
                self.assertFalse(retain_missing_row(error, Path('/never-written'), nonce=fixtures.NONCE, armed_ticks=1, now=clock))
                save.assert_not_called(); clock.assert_not_called()

    def test_unrelated_errors_with_forged_attached_metadata_are_ignored(self):
        counts = protocol.missing_row_metadata(rejection(prefix(self.spec, 1), self.spec))
        class OtherValueError(ValueError): pass
        for error in (ValueError('other-error'), OSError('UnknownPrivatePath'), OtherValueError('missing-generated-row')):
            error._cmdy_missing_row_counts = counts
            self.assertIsNone(protocol.missing_row_metadata(error))

    def test_fixed_worker_record_is_bounded_private_and_does_not_retain_rows(self):
        error = rejection(prefix(self.spec, 7), self.spec)
        with tempfile.TemporaryDirectory(prefix='cmdy-prefix-test-', dir='/private/tmp') as name:
            root = Path(name)
            self.assertTrue(retain_missing_row(error, root, nonce=fixtures.NONCE, armed_ticks=10, now=lambda:20))
            path = root/'missing-generated-row.json'; value = json.loads(path.read_text())
            self.assertEqual(set(value), WORKER_FIELDS); self.assertLess(path.stat().st_size, 1024)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual((value['pid'],value['nonce'],value['armedTicks'],value['finishedTicks']), (os.getpid(),fixtures.NONCE,10,20))
            self.assertFalse(value['qualifying']); self.assertEqual(value['matchedPrefixRows'],7)
            self.assertNotIn(protocol.expected_bytes(self.spec).split(b'\r\n')[0].decode(),path.read_text())

    def test_worker_write_failure_preserves_error_and_rejects_bad_nonce_or_ticks(self):
        error = rejection(prefix(self.spec, 7), self.spec)
        with patch('history_export_worker.save', side_effect=OSError('generated write failure')):
            with self.assertRaises(ValueError) as caught:
                try: raise error
                except ValueError as original:
                    self.assertFalse(retain_missing_row(original, Path('/not-used'), nonce=fixtures.NONCE, armed_ticks=10, now=lambda:20))
                    raise
        self.assertIs(caught.exception,error); self.assertEqual(str(error),'missing-generated-row')
        for nonce,arm,end in (('bad',1,2),(fixtures.NONCE,0,2),(fixtures.NONCE,True,2),
                              (fixtures.NONCE,2,1),(fixtures.NONCE,1,True),(fixtures.NONCE,1,1<<63)):
            with patch('history_export_worker.save') as save:
                self.assertFalse(retain_missing_row(error,Path('/not-used'),nonce=nonce,armed_ticks=arm,now=lambda:end))
                save.assert_not_called()
        for pid in (True, 0, -1, 1 << 31):
            with patch('history_export_worker.os.getpid', return_value=pid), patch('history_export_worker.save') as save:
                self.assertFalse(retain_missing_row(error,Path('/not-used'),nonce=fixtures.NONCE,armed_ticks=1,now=lambda:2))
                save.assert_not_called()


class PrefixDiagnosticPTYTests(unittest.TestCase):
    def run_partial(self, *, block_write=False):
        raw_sizes=[]
        def exporter(spec,directory):
            path=directory/'UnretainedGeneratedPrefix.txt';raw=prefix(spec,7,leading=2,trailing=3);raw_sizes.append(len(raw))
            path.write_bytes(raw);path.chmod(0o600)
            if block_write:
                target=directory.parent/'fixture/.missing-generated-row.json.tmp'
                target.write_bytes(b'owned-test-write-blocker');target.chmod(0o600)
            return path
        def verify(fixture,cleanup,ready,armed):
            path=fixture/'missing-generated-row.json'
            self.assertEqual(cleanup['errorCode'],'missing-generated-row');self.assertEqual(cleanup['status'],'failed')
            self.assertEqual(cleanup['inputBytesRetained'],0);self.assertFalse(cleanup['rejectedInputShapeRecorded'])
            self.assertFalse((fixture/'export.json').exists());self.assertFalse((fixture/'generated-export.bin').exists())
            self.assertFalse((fixture/'directory-rejection.json').exists())
            if block_write:
                self.assertFalse(path.exists())
                self.assertEqual((fixture/'.missing-generated-row.json.tmp').read_bytes(),b'owned-test-write-blocker')
            else:
                value=json.loads(path.read_text());self.assertEqual(set(value),WORKER_FIELDS)
                self.assertEqual((value['expectedRows'],value['matchedPrefixRows'],value['expectedRowIndex']), (1000,7,7))
                self.assertEqual((value['physicalLineCount'],value['physicalCursor'],value['leadingEmptyRows'],value['trailingEmptyRows']), (7,7,2,3))
                self.assertEqual(value['rawBytes'],raw_sizes[0]);self.assertEqual(value['pid'],ready['pid'])
                self.assertEqual(value['nonce'],ready['nonce']);self.assertEqual(value['armedTicks'],armed['arm']['armedTicks'])
                self.assertLessEqual(value['finishedTicks'],cleanup['finishedTicks'])
                self.assertFalse(value['qualifying']);self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
                for text in ('UnretainedGeneratedPrefix',ready['temporaryDirectory'],'SHA256','pathReceipt'):
                    self.assertNotIn(text,path.read_text())
        fixtures.OwnedPTYTests.run_worker(self,'primary-1000',drain=True,exporter=exporter,
            expected_error='missing-generated-row',failure_observer=verify,failed_export_unlinked=True)

    def test_private_PTY_retains_only_prefix_counts_and_cleans_owned_rejected_file(self):
        self.run_partial()

    def test_private_PTY_diagnostic_write_failure_keeps_original_rejection_and_cleanup(self):
        self.run_partial(block_write=True)


if __name__=='__main__':unittest.main()
