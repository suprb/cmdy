"""Counts/classes only, with strict lexical admission and owned PTY cleanup."""
import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from history_export_files import parse_owned_path, rejected_input_shape
from test_history_export import OwnedPTYTests


class RejectedShapeTests(unittest.TestCase):
    root = Path('/private/generated-owned-root')

    def shape(self, raw):
        with patch('history_export_files.open_directory', side_effect=AssertionError('must not open')):
            result = rejected_input_shape(raw, self.root)
        self.assertIs(result['qualifying'], False)
        self.assertIs(result['actionInvocationVerified'], False)
        self.assertIs(result['fileOpened'], False)
        self.assertEqual(result['inputBytesRetained'], 0)
        self.assertIs(result['inputHashRetained'], False)
        self.assertIs(result['filenameRetained'], False)
        self.assertNotIn(hashlib.sha256(raw).hexdigest(), json.dumps(result))
        with self.assertRaises(ValueError): parse_owned_path(raw, self.root)
        return result

    def test_distinguishes_decode_from_prefixed_leaf_rejection_without_io(self):
        prefix = str(self.root).encode() + b'/'
        nonascii = self.shape(prefix + 'generated-é.txt'.encode())
        self.assertFalse(nonascii['asciiOnly']); self.assertTrue(nonascii['exactOwnedDirectoryPrefix'])
        self.assertFalse(nonascii['leaf']['onlyDeclaredFilenameAlphabet'])
        for name, category in ((b'.generated.txt', 'dot'),):
            value = self.shape(prefix + name)
            self.assertTrue(value['asciiOnly']); self.assertTrue(value['exactOwnedDirectoryPrefix'])
            self.assertEqual(value['leaf']['firstByteClass'], category)
            self.assertTrue(value['leaf']['onlyDeclaredFilenameAlphabet'])

    def test_urlsafe_initial_characters_are_accepted_without_a_rejection_record(self):
        prefix = str(self.root).encode() + b'/'
        for name in (b'_generated.txt', b'-generated.txt', b'_generated/ghostty.txt',
                     b'-generated/ghostty.txt'):
            with self.subTest(name=name), \
                    patch('history_export_files.open_directory', side_effect=AssertionError('lexical check must not open')):
                self.assertEqual(parse_owned_path(prefix + name, self.root), name.decode('ascii'))
                self.assertIsNone(rejected_input_shape(prefix + name, self.root))

    def test_predefined_framing_flags_never_unwrap_or_admit(self):
        raw = str(self.root).encode() + b'/generated.txt'
        for framed, field in ((raw+b'\n','endsLF'), (raw+b'\r','endsCR'), (raw+b'\r\n','endsCRLF'),
                              (b"'"+raw+b"'",'startsSingleQuote'), (b'"'+raw+b'"','startsDoubleQuote'),
                              (b'\x1b[200~'+raw+b'\x1b[201~','startsBracketedPaste')):
            with self.subTest(field=field): self.assertTrue(self.shape(framed)[field])
        self.assertIsNone(rejected_input_shape(raw, self.root))

    def test_rejected_names_with_same_shape_are_indistinguishable(self):
        prefix = str(self.root).encode() + b'/'
        one = self.shape(prefix+b'.OpaqueFixtureOne.txt')
        two = self.shape(prefix+b'.OtherUnknownName.txt')
        self.assertEqual(one, two)
        text = json.dumps(one)
        for value in ('OpaqueFixtureOne', 'OtherUnknownName', str(self.root)):
            self.assertNotIn(value, text)

    def test_wrong_directory_traversal_and_controls_never_get_file_authority(self):
        values = [b'/elsewhere/generated.txt', str(self.root).encode()+b'/nested/../file.txt',
                  str(self.root).encode()+b'/generated\0.txt', b'\xff', b'']
        for raw in values:
            with self.subTest(bytes=len(raw)): self.shape(raw)

    def test_private_PTY_retains_shape_only_then_restores_and_reaps(self):
        for transform, field in ((lambda raw: raw+b'\n', 'endsLF'),
                                 (lambda raw: raw+b'\xc3\xa9', 'asciiOnly')):
            fixture = OwnedPTYTests('test_memory_drain_and_export_share_one_worker_tty_reader')
            record = fixture.run_worker('primary-1000', drain=True, wire_transform=transform)
            self.assertEqual(record['shape'][field], field == 'endsLF')
            self.assertTrue(record['shape']['exactOwnedDirectoryPrefix'])
            self.assertEqual(record['shape']['errorCode'], 'path-receipt-framing-unrecognized')


if __name__ == '__main__': unittest.main()
