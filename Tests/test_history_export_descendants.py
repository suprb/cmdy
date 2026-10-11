"""Generated private descendant intake; no app, capture, or native events."""
from copy import deepcopy
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from history_export_evidence import validate_file_proof
from history_export_files import inventory, parse_owned_path, read_generated_export
from history_export_protocol import expectation
import test_history_export as fixtures


class DescendantFileTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmdy-descendant-test-", dir="/private/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.exports = self.root / "exports"; self.exports.mkdir(mode=0o700)
        self.spec = expectation("primary-1000", fixtures.NONCE)
        self.raw = fixtures.physical_export(self.spec)
        self.retained = self.root / "generated-export.bin"
        self.path = self.exports / "owned-directory" / "generated.txt"

    def create(self, path=None):
        path = self.path if path is None else path
        self.assertTrue(path.is_relative_to(self.root))
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Only the test owns these newly generated ancestors.
        for parent in path.parents:
            if parent == self.root: break
            parent.chmod(0o700)
        path.write_bytes(self.raw); path.chmod(0o600)
        return path

    def read(self, before):
        return read_generated_export(str(self.path).encode(), self.exports, before, self.spec, self.retained)

    def test_nested_generated_export_complete_replay_and_same_inode_cleanup(self):
        before = inventory(self.exports); self.create()
        proof = self.read(before)
        self.assertEqual(proof["schemaVersion"], 2)
        self.assertEqual(validate_file_proof(proof, self.raw, self.spec, self.exports)["logicalRows"], 1000)
        self.assertFalse(self.path.exists()); self.assertTrue(self.path.parent.is_dir())
        self.assertEqual(self.retained.read_bytes(), self.raw)

    def test_prearm_inventory_includes_existing_descendant_identity(self):
        self.create(); before = inventory(self.exports)
        identity = self.path.stat()
        self.assertIn([identity.st_dev, identity.st_ino], before["identities"])
        with self.assertRaisesRegex(ValueError, "export-was-not-new"): self.read(before)
        self.assertEqual(self.path.read_bytes(), self.raw); self.assertFalse(self.retained.exists())

    def test_new_leaf_in_preexisting_private_ancestor_is_accepted(self):
        self.path.parent.mkdir(mode=0o700)
        before = inventory(self.exports); self.create()
        proof = self.read(before)
        self.assertNotEqual(before["directoryScans"][0]["before"]["mtime_ns"],
                            proof["ancestorChain"][1]["opened"]["mtime_ns"])
        validate_file_proof(proof, self.raw, self.spec, self.exports)

    def test_old_nested_inode_renamed_under_new_ancestor_is_still_rejected(self):
        old = self.create(self.exports / "old-directory" / "old.txt")
        before = inventory(self.exports)
        self.path.parent.mkdir(mode=0o700); old.rename(self.path)
        with self.assertRaisesRegex(ValueError, "export-was-not-new"): self.read(before)
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_flat_legacy_evidence_replays_but_cannot_admit_nested_paths(self):
        self.path = self.exports / "generated.txt"
        before = inventory(self.exports); self.create(); proof = self.read(before)
        legacy = deepcopy(proof); legacy["schemaVersion"] = 1
        legacy["beforeInventory"] = {key: before[key] for key in ("directory", "identities", "entryCount")}
        for key in ("ancestorChain", "pathTraversal", "rootNameRevalidated", "beforeUnlink",
                    "namedAtOpen", "namedAfterRead", "namedBeforeUnlink"): legacy.pop(key)
        validate_file_proof(legacy, self.raw, self.spec, self.exports)
        legacy["pathReceiptASCII"] = str(self.exports / "directory" / "generated.txt")
        legacy["pathBytes"] = len(legacy["pathReceiptASCII"])
        with self.assertRaisesRegex(ValueError, "legacy-file-proof-must-be-flat"):
            validate_file_proof(legacy, self.raw, self.spec, self.exports)
        with self.assertRaisesRegex(ValueError, "recursive-prearm-inventory-required"):
            self.read(legacy["beforeInventory"])

    def test_lexical_depth_components_traversal_and_framing_bounds_before_io(self):
        prefix = str(self.exports).encode() + b"/"
        self.assertEqual(parse_owned_path(prefix + b"one/two/three/file.txt", self.exports), "one/two/three/file.txt")
        for suffix in (b"a/b/c/d/file", b"a//file", b"a/../file", b"a/./file", b"a/.hidden", b"a/_file",
                       b"a/", b"a/\\file", b"a/file\n", b"a/file\x00", b"a/" + b"x" * 256):
            with self.subTest(length=len(suffix)), patch("history_export_files.open_directory") as opened:
                with self.assertRaises(ValueError):
                    read_generated_export(prefix + suffix, self.exports, {}, self.spec, self.retained)
                opened.assert_not_called()

    def test_global_inventory_count_and_depth_cannot_hide_subtrees(self):
        directory = self.exports / "old"; directory.mkdir(mode=0o700)
        for number in range(127): (directory / str(number)).touch(mode=0o600)
        self.assertEqual(inventory(self.exports)["entryCount"], 128)
        (directory / "extra").touch(mode=0o600)
        with self.assertRaisesRegex(ValueError, "inventory-bound"): inventory(self.exports)
        for item in directory.iterdir(): item.unlink()
        directory.rmdir()
        child = self.exports
        for component in ("a", "b", "c", "d"):
            child = child / component; child.mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError, "depth-bound"): inventory(self.exports)

    def test_inventory_symlink_privacy_and_changing_tree_fail_without_reading_contents(self):
        elsewhere = self.root / "separate"; elsewhere.mkdir(mode=0o700)
        (self.exports / "link").symlink_to(elsewhere, target_is_directory=True)
        with patch("history_export_files.os.read", side_effect=AssertionError("no file contents")):
            with self.assertRaisesRegex(ValueError, "entry-type-or-owner"): inventory(self.exports)
        (self.exports / "link").unlink(); self.path.parent.mkdir(mode=0o755); self.path.parent.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "not-private"): inventory(self.exports)
        self.path.parent.rmdir()
        original = os.listdir; changed = False
        def mutate(fd):
            nonlocal changed
            result = original(fd)
            if not changed:
                changed = True; (self.exports / "new").touch(mode=0o600)
            return result
        with patch("history_export_files.os.listdir", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "changed-during-inventory"): inventory(self.exports)

    def test_nested_symlink_and_nonprivate_ancestor_rejected_without_follow_or_cleanup(self):
        before = inventory(self.exports)
        outside = self.create(self.root / "separate" / "generated.txt")
        self.path.parent.symlink_to(outside.parent, target_is_directory=True)
        with patch("history_export_files.os.read", side_effect=AssertionError("must not follow")):
            with self.assertRaisesRegex(ValueError, "not-private"): self.read(before)
        self.assertTrue(self.path.parent.is_symlink()); self.assertEqual(outside.read_bytes(), self.raw)
        self.path.parent.unlink(); self.path.parent.mkdir(mode=0o700); self.path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "type-owner-mode-or-links"): self.read(before)
        self.assertTrue(self.path.is_symlink()); self.path.unlink(); self.create(); self.path.parent.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "not-private"): self.read(before)
        self.assertTrue(self.path.exists())

    def test_metadata_change_between_stat_and_open_does_not_authorize_failure_cleanup(self):
        before = inventory(self.exports); self.create(); original = os.open; changed = False
        def mutate(path, flags, *args, **kwargs):
            nonlocal changed
            if path == self.path.name and "dir_fd" in kwargs and not changed:
                changed = True; self.path.chmod(0o644)
            return original(path, flags, *args, **kwargs)
        with patch("history_export_files.os.open", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "changed-during-open"): self.read(before)
        self.assertTrue(changed); self.assertTrue(self.path.exists())
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o644); self.assertFalse(self.retained.exists())

    def replace_ancestor(self, root):
        old = self.root / "original-root" if root else self.path.parent.with_name("original-directory")
        ancestor = self.exports if root else self.path.parent
        ancestor.rename(old); ancestor.mkdir(mode=0o700); self.create()
        return old / ("owned-directory/generated.txt" if root else "generated.txt")

    def test_root_and_relative_ancestor_replacement_during_read_preserves_both_files(self):
        for root in (False, True):
            with self.subTest(root=root):
                if self.path.exists(): self.path.unlink()
                before = inventory(self.exports); self.create()
                original = os.read; replaced = []
                def mutate(fd, count):
                    result = original(fd, count)
                    if not replaced: replaced.append(self.replace_ancestor(root))
                    return result
                with patch("history_export_files.os.read", side_effect=mutate):
                    with self.assertRaisesRegex(ValueError, "changed"): self.read(before)
                self.assertEqual(replaced[0].read_bytes(), self.raw)
                self.assertEqual(self.path.read_bytes(), self.raw); self.assertFalse(self.retained.exists())

    def test_ancestor_replacement_before_unlink_preserves_detached_and_replacement_files(self):
        before = inventory(self.exports); self.create(); replaced = []
        from history_export_protocol import validate_export_bytes
        def mutate(raw, spec):
            result = validate_export_bytes(raw, spec)
            replaced.append(self.replace_ancestor(False)); return result
        with patch("history_export_files.validate_export_bytes", side_effect=mutate):
            with self.assertRaisesRegex(ValueError, "changed"): self.read(before)
        self.assertEqual(replaced[0].read_bytes(), self.raw); self.assertEqual(self.path.read_bytes(), self.raw)

    def test_independent_reader_rejects_incomplete_inventory_chain_and_cleanup_forgery(self):
        old = self.create(self.exports / "old" / "prior.txt")
        before = inventory(self.exports); self.create(); proof = self.read(before)
        edits = [lambda p: p["beforeInventory"].update(complete=False),
                 lambda p: p["beforeInventory"]["directoryScans"].pop(),
                 lambda p: p["beforeInventory"]["entries"][0].update(parentIdentity=[1, 1]),
                 lambda p: p["beforeInventory"]["directoryScans"][0].update(childCount=0),
                 lambda p: p["beforeInventory"]["identities"].pop(),
                 lambda p: p["ancestorChain"].pop(),
                 lambda p: p["ancestorChain"][1].update(component="other"),
                 lambda p: p["ancestorChain"][1].update(parentIdentity=[1, 1]),
                 lambda p: p["ancestorChain"][0]["namedAtOpen"].update(ino=1),
                 lambda p: p["ancestorChain"][1]["namedBeforeUnlink"].update(mode=0o40755),
                 lambda p: p["namedBeforeUnlink"].update(size=1),
                 lambda p: p.update(rootNameRevalidated=False),
                 lambda p: p.update(schemaVersion=1)]
        for edit in edits:
            altered = deepcopy(proof); edit(altered)
            with self.assertRaises(ValueError): validate_file_proof(altered, self.raw, self.spec, self.exports)
        self.assertEqual(old.read_bytes(), self.raw)


class DescendantPTYTests(unittest.TestCase):
    @staticmethod
    def export(spec, directory):
        folder = directory / "owned-session"; folder.mkdir(mode=0o700)
        nested = folder / "generated"; nested.mkdir(mode=0o700)
        path = nested / "history.txt"
        path.write_bytes(fixtures.physical_export(spec)); path.chmod(0o600)
        return path

    def test_nested_fragmented_private_PTY_transfer_replays_and_cleans_up(self):
        fixtures.OwnedPTYTests.run_worker(self, "primary-1000", drain=True, exporter=self.export)

    def test_preexisting_nested_private_PTY_file_fails_without_deletion_or_retention(self):
        saved = []
        def pre_arm(spec, directory): saved.append(self.export(spec, directory))
        fixtures.OwnedPTYTests.run_worker(self, "primary-1000", drain=True, pre_arm=pre_arm,
            exporter=lambda spec, directory: saved[0], expected_error="export-was-not-new")


if __name__ == "__main__": unittest.main()
