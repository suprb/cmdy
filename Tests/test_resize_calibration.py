"""Pure v2 discovery and whole diagnostic envelope failures. No native UI."""
from copy import deepcopy
import base64
import hashlib
import json
import unittest

from resize_calibration_evidence import validate_discovery
from resize_controller import METRIC
from resize_evidence import validate_document
from resize_protocol import PALETTE, START_RGB, END_RGB
from test_resize_evidence import fixture, NONCE, display_mode


def discovery(columns=120, rows=36, bounds=None):
    bounds = bounds or dict(x=10, y=10, width=1000, height=600)
    display = dict(x=0, y=0, width=1800, height=1200)
    colors = [dict(zip(("red", "green", "blue"), value)) for value in PALETTE + (START_RGB, END_RGB)]
    evidence = dict(fixtureVersion=2, nonce=NONCE, sequence=5, columns=columns, rows=rows,
        displayTicks=100, window=dict(bounds=bounds, queriedTicks=110,
            identity=dict(pid=123, parentPID=100, uid=501, startSeconds=1, startMicroseconds=2,
                          executable="/generated/owned"), windowID=456, displayID=1,
            foregroundPID=123, occluded=False),
        displayBounds=display, displayMode=display_mode(), captureWidth=1800, captureHeight=1200,
        markerLeft=bounds["x"]+10, markerRight=bounds["x"]+10+columns*4,
        rowBands=[dict(first=bounds["y"]+10+row*8, last=bounds["y"]+17+row*8) for row in range(rows)],
        sampledColors=colors, maximumColorDeviation=0, discoveryNominalTolerance=12, frozenMatchTolerance=3)
    geometry = dict(fixtureVersion=2, columns=columns, rows=rows, outerBounds=bounds,
        displayBounds=display, displayMode=display_mode(), captureWidth=1800, captureHeight=1200,
        xWithinWindowPixels=10, yWithinWindowPixels=10, cellWidthPixels=4, rowPitchPixels=8,
        rowSampleOffsets=[2,4,6], colors=colors, tolerance=3)
    result = dict(calibration=geometry)
    rehash(result, evidence)
    return result


def rehash(result, evidence):
    result["evidenceUTF8"] = json.dumps(evidence, separators=(",", ":"), sort_keys=True)
    result["evidenceSHA256"] = hashlib.sha256(result["evidenceUTF8"].encode()).hexdigest()
    result["calibration"]["discoveryEvidenceSHA256"] = result["evidenceSHA256"]


def document_fixture():
    entry, planned, display, source, target = fixture()
    a = discovery(source["columns"], source["rows"], source["outerBounds"])
    b = discovery(target["columns"], target["rows"], target["outerBounds"])
    # Serialize to match independent JSON records rather than aliased test dicts.
    return json.loads(json.dumps(dict(schemaVersion=1, case="resize", qualifying=False, metric=METRIC,
        entry=entry, planned=planned, display=display, nonce=NONCE, source=a["calibration"],
        target=b["calibration"], sourceDiscovery=a, targetDiscovery=b)))


class ResizeCalibrationTests(unittest.TestCase):
    def test_every_cell_geometry_reconstructed_for_both_grids(self):
        for columns, rows in ((120,36),(132,40)):
            value = discovery(columns, rows)
            self.assertEqual(validate_discovery(value), value["calibration"])

    def test_manual_crop_or_tolerance_does_not_replace_discovery(self):
        for field, value in (("cellWidthPixels", 3.9), ("rowPitchPixels", 9),
                             ("xWithinWindowPixels", 11), ("yWithinWindowPixels", 11),
                             ("rowSampleOffsets", [1,4,6]), ("tolerance", 12), ("fixtureVersion", 1)):
            result = discovery(); result["calibration"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): validate_discovery(result)

    def test_short_wrong_bounds_palette_and_rehashed_invalid_preimages_fail(self):
        for kind in ("short-bands", "row-order", "clipped-width", "old-right-edge", "palette", "spread", "version"):
            result = discovery(132,40)
            evidence = json.loads(result["evidenceUTF8"])
            if kind == "short-bands": evidence["rowBands"].pop()
            if kind == "row-order": evidence["rowBands"][1] = evidence["rowBands"][0]
            if kind == "clipped-width":
                evidence["window"]["bounds"]["width"] = 400
                result["calibration"]["outerBounds"]["width"] = 400
            if kind == "old-right-edge": evidence["markerRight"] = evidence["markerLeft"] + 62*4
            if kind == "palette":
                evidence["sampledColors"][0]["red"] += 13
                result["calibration"]["colors"] = evidence["sampledColors"]
            if kind == "spread": evidence["maximumColorDeviation"] = 4
            if kind == "version": evidence["fixtureVersion"] = 1
            rehash(result, evidence)
            with self.subTest(kind=kind), self.assertRaises(ValueError): validate_discovery(result)
        result = discovery(); result["evidenceUTF8"] += " "
        with self.assertRaisesRegex(ValueError, "preimage"): validate_discovery(result)

    def test_full_diagnostic_envelope_binds_observed_pixels_and_discoveries(self):
        document = document_fixture()
        result = validate_document(document)
        self.assertTrue(result["diagnosticValid"])
        self.assertFalse(result["qualifying"])
        broken = deepcopy(document); broken["target"]["cellWidthPixels"] = 5
        with self.assertRaises(ValueError): validate_document(broken)
        broken = deepcopy(document)
        observed = bytearray(base64.b64decode(broken["entry"]["observer"]["firstCompleteFrame"]["observedCellClasses"]))
        observed[-1] = 0
        broken["entry"]["observer"]["firstCompleteFrame"]["observedCellClasses"] = base64.b64encode(observed).decode()
        with self.assertRaises(ValueError): validate_document(broken)

    def test_discoveries_bind_exact_observer_capture_and_display_mode(self):
        for field, value in (("captureWidth", 900), ("captureHeight", 600), ("requestedFPS", 60),
                             ("displayRefreshRate", 120), ("displayBounds", dict(x=0,y=0,width=900,height=1200))):
            document = document_fixture(); document["display"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): validate_document(document)
        for field, value in (("modeID", 8), ("flags", 1), ("width", 1600), ("height", 900),
                             ("pixelWidth", 900), ("pixelHeight", 600), ("refreshRate", 120), ("rotation", 180)):
            document = document_fixture(); document["display"]["displayMode"][field] = value
            if field == "refreshRate": document["display"]["displayRefreshRate"] = value
            with self.subTest(modeField=field), self.assertRaises(ValueError): validate_document(document)

    def test_discoveries_bind_same_live_app_window_and_display(self):
        for side in ("source", "target"):
            for field, value in (("pid", 999), ("parentPID", 998), ("uid", 999),
                                 ("startSeconds", 99), ("startMicroseconds", 99),
                                 ("executable", "/different/app"), ("windowID", 777), ("displayID", 99)):
                document = document_fixture(); item = document[side + "Discovery"]
                evidence = json.loads(item["evidenceUTF8"])
                if field in ("windowID", "displayID"): evidence["window"][field] = value
                else:
                    evidence["window"]["identity"][field] = value
                    if field == "pid": evidence["window"]["foregroundPID"] = value
                rehash(item, evidence); document[side] = item["calibration"]
                with self.subTest(side=side,field=field), self.assertRaisesRegex(ValueError,"identity differ"):
                    validate_document(document)

    def test_calibration_clocks_precede_action_but_nonce_remains_independent(self):
        for side in ("source", "target"):
            for clock in ("displayTicks", "queriedTicks"):
                document = document_fixture(); item = document[side + "Discovery"]
                evidence = json.loads(item["evidenceUTF8"])
                container = evidence if clock == "displayTicks" else evidence["window"]
                container[clock] = document["entry"]["observer"]["action"]["beforeTicks"]
                rehash(item,evidence); document[side] = item["calibration"]
                with self.subTest(side=side,clock=clock), self.assertRaisesRegex(ValueError,"strictly before"):
                    validate_document(document)
        document = document_fixture()
        for side in ("source", "target"):
            item = document[side + "Discovery"]; evidence = json.loads(item["evidenceUTF8"])
            evidence["nonce"] = "f" * 32
            rehash(item,evidence); document[side] = item["calibration"]
        self.assertTrue(validate_document(document)["diagnosticValid"])

    def test_missing_mode_pins_and_malformed_mode_values_fail(self):
        for value in (None, True, float("nan"), -1):
            document = document_fixture(); document["display"]["displayMode"]["refreshRate"] = value
            with self.subTest(value=value), self.assertRaises(ValueError): validate_document(document)
        document = document_fixture(); del document["display"]["displayMode"]
        with self.assertRaises(KeyError): validate_document(document)


if __name__ == "__main__": unittest.main()
