"""Failure-only metadata from generated private directory checks; no native UI."""
from copy import deepcopy
import json
import os
from pathlib import Path
import stat
import unittest
from unittest.mock import Mock, patch

import history_export_files as files
from history_export_worker import retain_directory_rejection
import test_history_export as history
import test_history_export_descendants as descendants

FIELDS = {"schemaVersion", "purpose", "qualifying", "phase", "directory", "ordinal",
          "observedType", "permissionBits", "uidMatches", "sameDevice"}
WORKER_FIELDS = FIELDS | {"pid", "nonce", "armedTicks", "finishedTicks"}


def rejected(value=None, context=("open", 1, 7)):
    value = dict(mode=stat.S_IFDIR | 0o755, uid=501, dev=7) if value is None else value
    try:
        files.private_directory(value, 501, rejection_context=context)
    except ValueError as failure:
        return failure
    raise AssertionError("fixture must fail the existing directory guard")


class DirectoryDiagnosticTests(unittest.TestCase):
    setUp = descendants.DescendantFileTests.setUp
    create = descendants.DescendantFileTests.create
    read = descendants.DescendantFileTests.read

    def assert_record(self, error, *, phase, ordinal, kind="directory", mode=0o755, uid=True, device=True):
        self.assertIs(type(error), ValueError)
        self.assertEqual(str(error), "owned-directory-is-not-private")
        record = files.directory_rejection_metadata(error)
        self.assertEqual(set(record), FIELDS)
        self.assertEqual(record, dict(schemaVersion=1, purpose="failed-owned-directory-check", qualifying=False,
            phase=phase, directory="registered-root" if ordinal == 0 else "relative-ancestor", ordinal=ordinal,
            observedType=kind, permissionBits=mode, uidMatches=uid, sameDevice=device))
        return record

    def test_mode_type_uid_and_device_are_bounded_classes_only(self):
        cases = [(stat.S_IFDIR | 0o755, 501, 7, "directory", 0o755, True, True),
                 (stat.S_IFREG | 0o600, 501, 7, "regular", 0o600, True, True),
                 (stat.S_IFLNK | 0o777, 501, 7, "symlink", 0o777, True, True),
                 (stat.S_IFIFO | 0o600, 501, 7, "other", 0o600, True, True),
                 (stat.S_IFDIR | 0o700, 502, 8, "directory", 0o700, False, False)]
        for mode, uid, device, kind, bits, matches, same in cases:
            with self.subTest(kind=kind, uid=uid):
                error = rejected(dict(mode=mode, uid=uid, dev=device, ino=987654321,
                                      name="NeverRetainThisName", contents="NeverRetainTheseContents"))
                value = self.assert_record(error, phase="open", ordinal=1, kind=kind, mode=bits, uid=matches, device=same)
                text = json.dumps(value)
                for secret in ("NeverRetain", "987654321", "contents", '"uid"', '"dev"'): self.assertNotIn(secret, text)

    def test_original_ValueError_object_type_and_message_survive_annotation(self):
        original = ValueError("owned-directory-is-not-private")
        with patch("history_export_files.require", side_effect=original):
            actual = rejected()
        self.assertIs(actual, original)
        self.assert_record(actual, phase="open", ordinal=1)

    def test_diagnostic_construction_failure_does_not_replace_the_guard_error(self):
        original = ValueError("owned-directory-is-not-private")
        with patch("history_export_files.require", side_effect=original), \
             patch("history_export_files.annotate_directory_failure", side_effect=RuntimeError("diagnostic construction failed")):
            self.assertIs(rejected(), original)
        error = rejected(dict(mode=stat.S_IFDIR | 0o755, uid=501))
        self.assertEqual(str(error), "owned-directory-is-not-private")
        self.assertIsNone(files.directory_rejection_metadata(error))

    def test_contexts_are_per_error_without_shared_mutation(self):
        first = rejected(context=("after-read", 0, 7))
        before = files.directory_rejection_metadata(first)
        second = rejected(context=("before-unlink", 3, 8))
        self.assert_record(second, phase="before-unlink", ordinal=3, device=False)
        second._cmdy_directory_rejection["phase"] = "open"
        self.assertEqual(files.directory_rejection_metadata(first), before)

    def test_invalid_context_and_stat_bounds_never_attach_metadata(self):
        for context in (None, ["open", 1, 7], ("unknown/path", 1, 7), ("open", -1, 7), ("open", 4, 7),
                        ("open", True, 7), ("open", 1, 0), ("open", 1, 1 << 63), ("open", 1, True)):
            with self.subTest(context=context):
                self.assertIsNone(files.directory_rejection_metadata(rejected(context=context)))
        for field, value in (("mode", True), ("mode", -1), ("mode", (1 << 32) | 0o755), ("uid", -1),
                             ("uid", True), ("uid", 1 << 32), ("dev", 0), ("dev", True), ("dev", 1 << 63)):
            data = dict(mode=stat.S_IFDIR | 0o755, uid=501, dev=7); data[field] = value
            error = ValueError("owned-directory-is-not-private")
            files.annotate_directory_failure(error, ("open", 1, 7), mode=data["mode"], uid=data["uid"],
                                             expected_uid=501, device=data["dev"])
            self.assertIsNone(files.directory_rejection_metadata(error))
        # This impossible stat value fails the unchanged platform predicate
        # before any privacy-guard ValueError, so it must remain unrelated.
        with self.assertRaises(OverflowError) as caught:
            files.private_directory(dict(mode=-1, uid=501, dev=7), 501, rejection_context=("open", 1, 7))
        self.assertIsNone(files.directory_rejection_metadata(caught.exception))

    def test_whitelist_rejects_extra_fields_and_forged_metadata_before_clock_or_write(self):
        class FalseString(str):
            def __eq__(self, other): return True
            def __ne__(self, other): return False
        edits = [lambda d: d.update(path="DoNotRetain"), lambda d: d.update(phase="other"),
                 lambda d: d.update(ordinal=4), lambda d: d.update(ordinal=True),
                 lambda d: d.update(directory="registered-root"), lambda d: d.update(permissionBits=0o10000),
                 lambda d: d.update(uidMatches=1), lambda d: d.update(sameDevice=1),
                 lambda d: d.update(purpose=FalseString("DoNotRetain")),
                 lambda d: d.update(directory=FalseString("DoNotRetain")),
                 lambda d: d.update(permissionBits=0o700)]
        for edit in edits:
            error = rejected(); edit(error._cmdy_directory_rejection)
            clock = Mock(side_effect=AssertionError("must not query a clock"))
            with patch("history_export_worker.save") as save:
                self.assertFalse(retain_directory_rejection(error, self.root, nonce=history.NONCE, armed_ticks=1, now=clock))
                save.assert_not_called(); clock.assert_not_called()

    def test_root_open_retains_the_same_failed_stat_even_if_mode_is_repaired(self):
        self.exports.chmod(0o755)
        original = files.annotate_directory_failure
        def repair(failure, context, **values):
            self.exports.chmod(0o700)
            original(failure, context, **values)
        with patch("history_export_files.annotate_directory_failure", side_effect=repair):
            with self.assertRaises(ValueError) as caught:
                files.open_directory(self.exports, rejection_context=("open", 0, self.exports.stat().st_dev))
        self.assert_record(caught.exception, phase="open", ordinal=0)
        self.assertEqual(stat.S_IMODE(self.exports.stat().st_mode), 0o700)

    def test_actual_ancestor_ordinals_one_through_three(self):
        for ordinal in range(1, 4):
            self.path = self.exports.joinpath(*(f"p{ordinal}-{n}" for n in range(ordinal)), "generated.txt")
            before = files.inventory(self.exports); self.create(); self.path.parent.chmod(0o755)
            with self.assertRaises(ValueError) as caught: self.read(before)
            self.assert_record(caught.exception, phase="open", ordinal=ordinal)
            self.assertTrue(self.path.exists()); self.path.parent.chmod(0o700)

    def test_root_named_initial_revalidation_is_instrumented(self):
        before = files.inventory(self.exports); self.create(); original = files.root_still_named
        def replace(path, expected, **kwargs):
            if kwargs.get("rejection_context", (None,))[0] == "open-revalidation": self.exports.chmod(0o755)
            return original(path, expected, **kwargs)
        with patch("history_export_files.root_still_named", side_effect=replace):
            with self.assertRaises(ValueError) as caught: self.read(before)
        self.assert_record(caught.exception, phase="open-revalidation", ordinal=0)
        self.assertTrue(self.path.exists())

    def test_after_read_root_named_failure_is_not_overwritten_by_cleanup_failure(self):
        before = files.inventory(self.exports); self.create(); original = os.read
        def mutate(fd, size):
            data = original(fd, size); self.exports.chmod(0o755); return data
        with patch("history_export_files.os.read", side_effect=mutate):
            with self.assertRaises(ValueError) as caught: self.read(before)
        self.assert_record(caught.exception, phase="after-read", ordinal=0)
        self.assertTrue(self.path.exists()); self.assertFalse(self.retained.exists())

    def test_before_unlink_root_named_failure_keeps_original_phase_and_file(self):
        before = files.inventory(self.exports); self.create(); original = files.validate_export_bytes
        def mutate(raw, spec):
            result = original(raw, spec); self.exports.chmod(0o755); return result
        with patch("history_export_files.validate_export_bytes", side_effect=mutate):
            with self.assertRaises(ValueError) as caught: self.read(before)
        self.assert_record(caught.exception, phase="before-unlink", ordinal=0)
        self.assertTrue(self.path.exists())

    def test_unrelated_primary_error_and_lexical_failure_do_not_get_cleanup_diagnostics(self):
        before = files.inventory(self.exports); self.create()
        original = ValueError("generated-format-failed")
        def reject(raw, spec): self.exports.chmod(0o755); raise original
        with patch("history_export_files.validate_export_bytes", side_effect=reject):
            with self.assertRaises(ValueError) as caught: self.read(before)
        self.assertIs(caught.exception, original); self.assertIsNone(files.directory_rejection_metadata(original))
        self.exports.chmod(0o700)
        with self.assertRaises(ValueError) as lexical:
            files.read_generated_export(b"/other/UnknownPrivateName", self.exports, before, self.spec, self.retained)
        for error in (original, lexical.exception, FileNotFoundError("unknown-private-path")):
            clock = Mock(side_effect=AssertionError("must not query clock"))
            with patch("history_export_worker.save") as save:
                self.assertFalse(retain_directory_rejection(error, self.root, nonce=history.NONCE, armed_ticks=1, now=clock))
                save.assert_not_called(); clock.assert_not_called()

    def test_worker_record_has_exact_fields_and_write_failure_preserves_primary_exception(self):
        original = rejected()
        self.assertTrue(retain_directory_rejection(original, self.root, nonce=history.NONCE, armed_ticks=10, now=lambda: 20))
        output = self.root / "directory-rejection.json"; value = json.loads(output.read_text())
        self.assertEqual(set(value), WORKER_FIELDS); self.assertEqual(value["pid"], os.getpid())
        self.assertEqual((value["armedTicks"], value["finishedTicks"]), (10, 20))
        self.assertLess(len(output.read_bytes()), 1024); self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        with patch("history_export_worker.save", side_effect=OSError("simulated evidence write failure")):
            with self.assertRaises(ValueError) as caught:
                try: raise original
                except ValueError as error:
                    self.assertFalse(retain_directory_rejection(error, self.root, nonce=history.NONCE, armed_ticks=10, now=lambda: 20))
                    raise
        self.assertIs(caught.exception, original); self.assertEqual(str(original), "owned-directory-is-not-private")

    def test_worker_rejects_invalid_nonce_and_tick_bounds(self):
        for nonce, arm, finished in (("unrecognized", 1, 2), (history.NONCE, 0, 2), (history.NONCE, True, 2),
                                    (history.NONCE, 2, 1), (history.NONCE, 1, True), (history.NONCE, 1, 1 << 63)):
            with patch("history_export_worker.save") as save:
                self.assertFalse(retain_directory_rejection(rejected(), self.root, nonce=nonce, armed_ticks=arm, now=lambda: finished))
                save.assert_not_called()


class DirectoryDiagnosticPTYTests(unittest.TestCase):
    def run_bad_ancestor(self, *, block_evidence_write=False):
        def exporter(spec, directory):
            folder = directory / "UnretainedParentName"; folder.mkdir(mode=0o755); folder.chmod(0o755)
            path = folder / "UnretainedLeafName.txt"
            path.write_bytes(history.physical_export(spec)); path.chmod(0o600)
            if block_evidence_write:
                fixed = directory.parent / "fixture/.directory-rejection.json.tmp"
                fixed.write_bytes(b"owned-test-write-blocker"); fixed.chmod(0o600)
            return path
        def verify(fixture, cleanup, ready, armed):
            path = fixture / "directory-rejection.json"
            if block_evidence_write:
                self.assertFalse(path.exists())
                self.assertEqual((fixture / ".directory-rejection.json.tmp").read_bytes(), b"owned-test-write-blocker")
            else:
                value = json.loads(path.read_text()); self.assertEqual(set(value), WORKER_FIELDS)
                self.assertEqual((value["phase"], value["ordinal"], value["observedType"], value["permissionBits"]),
                                 ("open", 1, "directory", 0o755))
                self.assertTrue(value["uidMatches"]); self.assertTrue(value["sameDevice"])
                self.assertEqual(value["pid"], ready["pid"]); self.assertEqual(value["nonce"], ready["nonce"])
                self.assertEqual(value["armedTicks"], armed["arm"]["armedTicks"])
                self.assertLessEqual(value["finishedTicks"], cleanup["finishedTicks"])
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                for secret in ("UnretainedParentName", "UnretainedLeafName", ready["temporaryDirectory"]):
                    self.assertNotIn(secret, path.read_text())
            self.assertEqual(cleanup["errorCode"], "owned-directory-is-not-private")
            self.assertEqual(cleanup["inputBytesRetained"], 0)
        history.OwnedPTYTests.run_worker(self, "primary-1000", drain=True, exporter=exporter,
            expected_error="owned-directory-is-not-private", failure_observer=verify)

    def test_actual_private_PTY_bad_ancestor_retains_bounded_metadata_and_reaps(self):
        self.run_bad_ancestor()

    def test_actual_private_PTY_write_failure_keeps_original_guard_error_and_reaps(self):
        self.run_bad_ancestor(block_evidence_write=True)


if __name__ == "__main__": unittest.main()
