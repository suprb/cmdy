"""Private generated path/file checks only; no processes, native apps or helpers."""
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import compare_history as history


class ExecutableAliasTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cmdy-history-executable-', dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / 'owned'; self.directory.mkdir(mode=0o700)
        self.file = self.directory / 'generated-binary'
        self.raw = b'only-private-generated-fixture\x00' * 100
        self.file.write_bytes(self.raw); self.file.chmod(0o700)
        self.planned = dict(path=str(self.file), bytes=len(self.raw), sha256=hashlib.sha256(self.raw).hexdigest())
        self.alias = self.root / 'alias'; self.alias.symlink_to(self.directory, target_is_directory=True)
        self.observed = self.alias / self.file.name

    def test_exact_path_and_same_file_directory_alias_pass(self):
        self.assertTrue(history.same_executable_file(str(self.file), self.planned))
        self.assertTrue(history.same_executable_file(str(self.observed), self.planned))
        self.assertEqual(self.file.read_bytes(), self.raw)

    def test_actual_macos_tmp_alias_reproduces_text_mismatch_without_identity_mismatch(self):
        self.assertTrue(str(self.file).startswith('/private/tmp/'))
        observed = '/tmp/' + str(self.file)[len('/private/tmp/'):]
        self.assertNotEqual(observed, self.planned['path'])
        self.assertEqual(Path(observed).resolve(strict=True), self.file.resolve(strict=True))
        self.assertTrue(history.same_executable_file(observed, self.planned))

    def test_equal_content_copy_and_hardlink_are_not_canonical_path_aliases(self):
        copy = self.root / 'same-content'; copy.write_bytes(self.raw)
        hardlink = self.root / 'same-inode'; os.link(self.file, hardlink)
        self.assertEqual(hardlink.stat().st_ino, self.file.stat().st_ino)
        with patch.object(history.os, 'open', side_effect=AssertionError('unrelated canonical path must not be opened')):
            self.assertFalse(history.same_executable_file(str(copy), self.planned))
            self.assertFalse(history.same_executable_file(str(hardlink), self.planned))

    def test_relative_missing_invalid_and_unpinned_values_reject(self):
        for observed in ('', 'relative', '\0', str(self.root / 'missing'), 1, None):
            self.assertFalse(history.same_executable_file(observed, self.planned))
        for changed in (dict(path='relative'), dict(path=''), dict(bytes=True), dict(bytes=0),
                        dict(bytes=len(self.raw)+1), dict(sha256='f'*64), dict(sha256='F'*64), dict(sha256=None)):
            self.assertFalse(history.same_executable_file(str(self.observed), dict(self.planned, **changed)))
        self.assertFalse(history.same_executable_file(str(self.file), None))

    def test_leaf_symlink_and_nonregular_targets_reject_without_blocking(self):
        leaf = self.root / 'leaf-alias'; leaf.symlink_to(self.file)
        self.assertFalse(history.same_executable_file(str(leaf), self.planned))
        fifo = self.root / 'generated-fifo'; os.mkfifo(fifo, mode=0o600)
        for target in (self.root, fifo):
            self.assertFalse(history.same_executable_file(str(target), dict(self.planned, path=str(target))))

    def test_replacement_between_descriptor_opens_rejects_before_reading_and_closes_both(self):
        actual_open = os.open; descriptors = []
        detached = self.directory / 'detached'
        def opened(path, flags):
            if descriptors:
                self.file.rename(detached); self.file.write_bytes(self.raw); self.file.chmod(0o700)
            fd = actual_open(path, flags); descriptors.append(fd); return fd
        with patch.object(history.os, 'open', side_effect=opened), \
                patch.object(history.os, 'read', side_effect=AssertionError('mismatched inode must not be read')):
            self.assertFalse(history.same_executable_file(str(self.observed), self.planned))
        self.assertEqual(len(descriptors), 2)
        for fd in descriptors:
            with self.assertRaises(OSError): os.fstat(fd)
        self.assertEqual(detached.read_bytes(), self.raw); self.assertEqual(self.file.read_bytes(), self.raw)

    def test_content_mutation_during_read_rejects_and_preserves_the_changed_file(self):
        actual_read = os.read; changed = False
        def reading(fd, count):
            nonlocal changed
            value = actual_read(fd, count)
            if not changed:
                changed = True; self.file.write_bytes(b'X' * len(self.raw))
            return value
        with patch.object(history.os, 'read', side_effect=reading):
            self.assertFalse(history.same_executable_file(str(self.observed), self.planned))
        self.assertEqual(self.file.read_bytes(), b'X' * len(self.raw))

    def test_same_bytes_named_replacement_after_read_cannot_borrow_detached_descriptor(self):
        actual_read = os.read; replaced = False; detached = self.directory / 'detached'
        def reading(fd, count):
            nonlocal replaced
            value = actual_read(fd, count)
            if not replaced:
                replaced = True; self.file.rename(detached); self.file.write_bytes(self.raw); self.file.chmod(0o700)
            return value
        with patch.object(history.os, 'read', side_effect=reading):
            self.assertFalse(history.same_executable_file(str(self.observed), self.planned))
        self.assertTrue(detached.is_file()); self.assertTrue(self.file.is_file())

    def test_ancestor_alias_retarget_during_read_cannot_borrow_same_content(self):
        other = self.root / 'other'; other.mkdir(mode=0o700)
        other_file = other / self.file.name; other_file.write_bytes(self.raw); other_file.chmod(0o700)
        actual_read = os.read; changed = False
        def reading(fd, count):
            nonlocal changed
            value = actual_read(fd, count)
            if not changed:
                changed = True; self.alias.unlink(); self.alias.symlink_to(other, target_is_directory=True)
            return value
        with patch.object(history.os, 'read', side_effect=reading):
            self.assertFalse(history.same_executable_file(str(self.observed), self.planned))
        self.assertEqual(self.file.read_bytes(), self.raw); self.assertEqual(other_file.read_bytes(), self.raw)

    def test_second_open_failure_closes_first_descriptor_and_reads_nothing(self):
        actual_open = os.open; descriptors = []
        def opened(path, flags):
            if descriptors: raise OSError('generated second-open failure')
            fd = actual_open(path, flags); descriptors.append(fd); return fd
        with patch.object(history.os, 'open', side_effect=opened), \
                patch.object(history.os, 'read', side_effect=AssertionError('failed open must not read')):
            self.assertFalse(history.same_executable_file(str(self.observed), self.planned))
        with self.assertRaises(OSError): os.fstat(descriptors[0])


if __name__ == '__main__': unittest.main()
