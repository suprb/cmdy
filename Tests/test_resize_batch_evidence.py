"""Mutation checks for decoded cells, lifetime and export clock boundaries."""
import base64
from copy import deepcopy
import json
import unittest

from resize_batch_evidence import validate_frozen_view
from resize_protocol import cell_classes_bytes, digest
from test_resize_calibration import discovery
from test_resize_evidence import fixture, NONCE


class FrozenViewportTests(unittest.TestCase):
    def setUp(self):
        self.display = fixture()[2]
        self.discovery = discovery()
        proof = json.loads(self.discovery["evidenceUTF8"])["window"]
        cells = cell_classes_bytes(NONCE, 126, 120, 36)
        self.value = dict(ok=True, op="verify", observationScope="complete-generated-cell-viewport-v2",
            fixtureVersion=2, nonce=NONCE, sequence=126, displayTicks=122, callbackTicks=120,
            checkedTicks=125, afterTicks=119, matchedCells=len(cells),
            observedCellClasses=base64.b64encode(cells).decode(), cellClassesSHA256=digest(cells),
            beforeProof=dict(proof, queriedTicks=123), afterProof=dict(proof, queriedTicks=124))

    def validate(self, value):
        return validate_frozen_view(value, NONCE, 126, self.display, self.discovery, after_ticks=119, before_ticks=130)

    def test_complete_decoded_viewport_and_future_display_clock_are_retained(self):
        self.assertEqual(self.validate(self.value)["matchedCells"], 4320)
        self.value["displayTicks"] = 128
        self.assertEqual(self.validate(self.value)["status"], "valid-untimed-frozen-viewport")
        self.assertFalse(self.validate(self.value)["qualifying"])

    def test_stale_future_unenclosed_and_reversed_clocks_fail(self):
        for key, value in [("displayTicks",118),("displayTicks",131),("checkedTicks",131),
                           ("checkedTicks",123),("callbackTicks",124),("afterTicks",0)]:
            row=deepcopy(self.value); row[key]=value
            with self.subTest(key=key,value=value), self.assertRaises(ValueError): self.validate(row)

    def test_one_changed_cell_fails_even_with_recomputed_hash(self):
        row=deepcopy(self.value); cells=bytearray(base64.b64decode(row["observedCellClasses"]))
        cells[121]^=1;row["observedCellClasses"]=base64.b64encode(cells).decode();row["cellClassesSHA256"]=digest(cells)
        with self.assertRaises(ValueError): self.validate(row)

    def test_invented_count_hash_sequence_or_nonce_cannot_replace_cells(self):
        for key,value in [("matchedCells",4319),("cellClassesSHA256","0"*64),("sequence",True),
                          ("sequence",127),("nonce","f"*32),("observedCellClasses","bad base64"),
                          ("fixtureVersion",True),("observedCellClasses","a"*7041)]:
            row=deepcopy(self.value);row[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(row)

    def test_foreign_window_lifetime_occlusion_or_geometry_fails(self):
        for key,value in [("windowID",457),("foregroundPID",125),("occluded",True)]:
            row=deepcopy(self.value);row["afterProof"][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(row)
        row=deepcopy(self.value);row["beforeProof"]["identity"]["startMicroseconds"]+=1
        with self.assertRaises(ValueError):self.validate(row)
        row=deepcopy(self.value);row["afterProof"]["bounds"]["width"]+=1
        with self.assertRaises(ValueError):self.validate(row)


if __name__ == "__main__": unittest.main()
