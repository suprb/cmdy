import plistlib
import unittest
from copy import deepcopy

from owned_defaults_cleanup import classify_owned_defaults_cleanup


class OwnedDefaultsTests(unittest.TestCase):
    domain = 'com.cmdy.bench.' + 'a' * 32

    def receipts(self):
        return (dict(command=['/usr/bin/defaults', 'export', self.domain, '-'], returncode=0,
                     stdout=plistlib.dumps({}).decode(), stderr=''),
                dict(command=['/usr/bin/defaults', 'delete', self.domain], returncode=1, stdout='',
                     stderr=f'2026-09-12 10:08:38.506 defaults[908:15581127] \nDomain ({self.domain}) not found.\nDefaults have not been changed.'))

    def test_exact_absent_empty_suite_is_classified(self):
        exported, deleted = self.receipts()
        self.assertEqual(classify_owned_defaults_cleanup(self.domain, exported, deleted), 'already-absent-empty-suite')
        deleted['stderr'] = f'Domain ({self.domain}) not found.\nDefaults have not been changed.'
        self.assertEqual(classify_owned_defaults_cleanup(self.domain, exported, deleted), 'already-absent-empty-suite')

    def test_successful_delete_preserves_existing_receipt_contract(self):
        exported, deleted = self.receipts(); deleted = dict(command=deleted['command'], returncode=0)
        self.assertEqual(classify_owned_defaults_cleanup(self.domain, exported, deleted), 'deleted')

    def test_absence_is_not_inferred_from_other_failures_or_values(self):
        variants = [
            ('export', 'stdout', plistlib.dumps({'retained': 1}).decode()),
            ('export', 'stdout', plistlib.dumps([]).decode()),
            ('export', 'stdout', ''), ('export', 'stdout', '<?xml version="1.0"?><plist><'),
            ('export', 'stderr', 'permission denied'), ('export', 'returncode', 1),
            ('export', 'returncode', False), ('delete', 'returncode', True),
            ('delete', 'returncode', 2), ('delete', 'stdout', 'unexpected output'),
            ('delete', 'stderr', f'Domain (com.user.existing) not found.\nDefaults have not been changed.'),
            ('delete', 'stderr', f'Domain ({self.domain}) not found.\nPermission denied.'),
            ('delete', 'stderr', f'Permission denied\nDomain ({self.domain}) not found.\nDefaults have not been changed.'),
            ('delete', 'command', ['/usr/bin/defaults', 'delete', 'com.user.existing']),
            ('export', 'command', ['/usr/bin/defaults', 'export', 'com.user.existing', '-']),
        ]
        for side, field, value in variants:
            with self.subTest(side=side, field=field, value=value):
                exported, deleted = deepcopy(self.receipts())
                (exported if side == 'export' else deleted)[field] = value
                with self.assertRaises(RuntimeError): classify_owned_defaults_cleanup(self.domain, exported, deleted)
        exported, deleted = self.receipts()
        with self.assertRaises(RuntimeError): classify_owned_defaults_cleanup('com.user.existing', exported, deleted)


if __name__ == '__main__': unittest.main()
