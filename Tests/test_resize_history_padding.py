"""Generated reflow padding must never conceal lost or changed history rows."""
from copy import deepcopy
import unittest

from history_export_evidence import validate_transfer
from history_export_protocol import (expected_bytes, expectation, resize_batch_expectation,
                                     row_split_metadata, validate_export_bytes)
from test_history_export import NONCE, TransferEvidenceTests


class ResizeHistoryPaddingTests(unittest.TestCase):
    def test_bounds_follow_fixed_number_of_round_trips(self):
        for phase, rounds, maximum in (("before", 1, 117), ("after", 22, 1041)):
            spec = resize_batch_expectation(NONCE, phase)
            self.assertEqual(spec["resizeBatchPadding"]["completedRoundTrips"], rounds)
            self.assertEqual(spec["resizeBatchPadding"]["maximumTrailingEmptyRows"], maximum)
            self.assertEqual(expected_bytes(spec), expected_bytes(expectation("resize", NONCE)))
            raw = expected_bytes(spec).replace(b"\r\n", b"\n") + b"\n" * (maximum - 1)
            self.assertEqual(validate_export_bytes(raw, spec)["trailingEmptyRows"], maximum)
            with self.assertRaisesRegex(ValueError, "outer-padding"):
                validate_export_bytes(raw + b"\n", spec)

    def test_standalone_limit_is_unchanged_and_leading_limit_does_not_grow(self):
        raw = expected_bytes(expectation("resize", NONCE))
        with self.assertRaisesRegex(ValueError, "outer-padding"):
            validate_export_bytes(raw + b"\n" * 73, expectation("resize", NONCE))
        for phase in ("before", "after"):
            with self.assertRaisesRegex(ValueError, "outer-padding"):
                validate_export_bytes(b"\n" * 74 + raw, resize_batch_expectation(NONCE, phase))

    def test_replayed_model_padding_fits_only_correct_phase(self):
        spec = resize_batch_expectation(NONCE, "after")
        raw = expected_bytes(spec) + b"\n" * 1005
        self.assertEqual(validate_export_bytes(raw, spec)["logicalRows"], 1000)
        with self.assertRaises(ValueError):
            validate_export_bytes(raw, resize_batch_expectation(NONCE, "before"))

    def test_padding_cannot_hide_missing_duplicate_interior_blank_or_reordered_rows(self):
        spec = resize_batch_expectation(NONCE, "after")
        rows = expected_bytes(spec).split(b"\r\n")[:-1]
        for changed in (rows[1:], rows[:-1], rows[:400] + [b""] + rows[400:],
                        rows[:400] + [rows[399]] + rows[400:], [rows[1], rows[0]] + rows[2:],
                        rows[:400] + [b"foreign text"] + rows[401:]):
            with self.subTest(length=len(changed)), self.assertRaises(ValueError):
                validate_export_bytes(b"\n".join(changed) + b"\n" * 1006, spec)

    def test_counts_and_phase_cannot_be_caller_selected(self):
        original = resize_batch_expectation(NONCE, "after")
        for key, value in (("maximumTrailingEmptyRows", 2000), ("completedRoundTrips", 23),
                           ("batchTransitions", 40), ("schemaVersion", True), ("phase", "arbitrary")):
            spec = deepcopy(original); spec["resizeBatchPadding"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): expected_bytes(spec)

    def test_padding_cannot_be_attached_to_memory_case(self):
        spec = resize_batch_expectation(NONCE, "after"); spec["case"] = "primary-1000"
        with self.assertRaises(ValueError): expected_bytes(spec)

    def test_guarded_padding_accounts_for_exactly_four_added_rows_per_round_trip(self):
        for phase, maximum in (("before", 121), ("after", 1129)):
            spec = resize_batch_expectation(NONCE, phase, history_growth_guard=True)
            self.assertEqual(spec["resizeBatchPadding"]["growthGuardRows"], 4)
            self.assertEqual(spec["resizeBatchPadding"]["maximumTrailingEmptyRows"], maximum)
            raw = expected_bytes(spec) + b"\n" * (maximum - 1)
            self.assertEqual(validate_export_bytes(raw, spec)["logicalRows"], 1000)
            with self.assertRaises(ValueError): validate_export_bytes(raw + b"\n", spec)
            spec["resizeBatchPadding"]["growthGuardRows"] = 5
            with self.assertRaises(ValueError): expected_bytes(spec)

    def test_rejected_wrap_diagnostic_has_only_counts_and_never_admits_export(self):
        spec = resize_batch_expectation(NONCE, "before")
        rows = expected_bytes(spec).split(b"\r\n")[:-1]
        raw = b"\n".join([rows[0][:132], rows[0][132:]] + rows[1:]) + b"\n"
        with self.assertRaisesRegex(ValueError, "content-order-or-wrap") as caught:
            validate_export_bytes(raw, spec)
        counts = row_split_metadata(caught.exception)
        self.assertEqual(counts["expectedRowIndex"], 0)
        self.assertEqual(counts["exactExpectedRowSplitLengths"], [132, 13])
        self.assertFalse(counts["qualifying"])
        self.assertNotIn(NONCE, str(counts))
        caught.exception._cmdy_row_split_counts["text"] = "must-not-survive"
        self.assertIsNone(row_split_metadata(caught.exception))

    def transfer_fixture(self, guarded=False):
        fixture = TransferEvidenceTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.spec = resize_batch_expectation(NONCE, "after", history_growth_guard=guarded)
        fixture.raw = expected_bytes(fixture.spec) + b"\n" * (1093 if guarded else 1005)
        document = fixture.document(); document["schemaVersion"] = 5
        document["workerReady"].update(pairedBlock=3, historyTransferScope="resize-same-lifetime-history-v1")
        if guarded: document["workerReady"]["historyGrowthGuardRows"] = 4
        document["workerArm"].update(phase="after", sequence=168)
        return document, fixture.raw

    def test_guarded_export_cannot_borrow_legacy_worker_identity(self):
        document, raw = self.transfer_fixture(guarded=True)
        self.assertEqual(validate_transfer(document, raw)["generatedHistory"]["logicalRows"], 1000)
        del document["workerReady"]["historyGrowthGuardRows"]
        with self.assertRaises(ValueError): validate_transfer(document, raw)

    def test_transfer_requires_explicit_batch_schema_and_bound_phase(self):
        document, raw = self.transfer_fixture()
        self.assertEqual(validate_transfer(document, raw)["generatedHistory"]["logicalRows"], 1000)
        for edit in (lambda x: x.update(schemaVersion=1),
                     lambda x: x["workerReady"].update(pairedBlock=True),
                     lambda x: x["workerReady"].update(historyTransferScope="standalone"),
                     lambda x: x["workerArm"].update(sequence=167),
                     lambda x: x["workerArm"].update(phase="before")):
            changed = deepcopy(document); edit(changed)
            with self.assertRaises(ValueError): validate_transfer(changed, raw)


if __name__ == "__main__": unittest.main()
