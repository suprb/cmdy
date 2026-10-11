"""Version2 chrome evidence contracts; generated records only, no native APIs."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scroll_parity_evidence import checked_chrome_geometry, load_scroll_evidence
from test_scroll_complete_evidence import build_records, digest, write


def fixture():
    spec = {'appPID': 42, 'windowID': 10, 'displayID': 1}
    main = {'appPID': 42, 'windowID': 10, 'displayID': 1, 'frontmostPID': 42,
            'processStartSeconds': 1, 'processStartMicroseconds': 2,
            'x': 120, 'y': 120, 'width': 1040, 'height': 655}
    raster = {'width': 2080, 'height': 1310,
              'columnSamples': [[10 + col * 12 + x for x in (1, 2, 4)] for col in range(42)],
              'rowBands': [{'lower': 80 + row * 30, 'upper': 80 + (row + 1) * 30} for row in range(36)]}
    raster['calibrationSHA256'] = hashlib.sha256(json.dumps(raster, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    chrome = {'windowID': 11, 'ownerPID': 42, 'layer': 0, 'alpha': 1,
              'onScreen': True, 'bounds': [[129, 130], [66, 20]]}
    report = {'schemaVersion': 2, 'ownedChromeGeometrySchema': 1, 'ownedChromeGeometryLimit': 4096,
              'clockBefore': {'absoluteTicks': 100}, 'clockAfter': {'absoluteTicks': 2000},
              'captureStartTicks': 500, 'initial': {'stability': {'first': {'windowQueryFinishedTicks': 1000}}},
              'windowBefore': main, 'geometry': raster, 'capture': {'height': 1310},
              'ownedChromeGeometry': [
                  {'checkedTicks': 300, 'rasterDerivedViewportTop': None, 'windows': []},
                  {'checkedTicks': 900, 'rasterDerivedViewportTop': 160.0, 'windows': [chrome]}]}
    return report, spec


class ChromeEvidenceTests(unittest.TestCase):
    def test_exact_generated_boundary_accepts_owned_chrome_and_later_removal(self):
        report, spec = fixture()
        checked_chrome_geometry(report, spec)
        report['ownedChromeGeometry'][1]['windows'][0]['bounds'][0][1] = 140
        checked_chrome_geometry(report, spec)  # Exactly ends at160; no viewport overlap.
        report['ownedChromeGeometry'].append({'checkedTicks': 1100, 'rasterDerivedViewportTop': 160, 'windows': []})
        checked_chrome_geometry(report, spec)

    def test_absent_and_unbounded_chronology_reject(self):
        for value in (None, [], [{}], [None] * 4097):
            report, spec = fixture(); report['ownedChromeGeometry'] = value
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)
        report, spec = fixture(); del report['ownedChromeGeometry']
        with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_version_and_explicit_contract_are_required(self):
        for key, value in (('schemaVersion', 1), ('schemaVersion', True),
                           ('ownedChromeGeometrySchema', None), ('ownedChromeGeometrySchema', True),
                           ('ownedChromeGeometryLimit', 4097)):
            report, spec = fixture(); report[key] = value
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_first_entry_is_empty_uncalibrated_and_before_capture(self):
        for mutation in ('top', 'chrome', 'late'):
            report, spec = fixture(); first, second = report['ownedChromeGeometry']
            if mutation == 'top': first['rasterDerivedViewportTop'] = 160
            elif mutation == 'chrome': first['windows'] = second['windows']
            else: first['checkedTicks'] = report['captureStartTicks']
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_fixed_top_rejects_tampering_null_and_boolean(self):
        for top in (160.001, 159.999, None, True, float('nan'), float('inf')):
            report, spec = fixture(); report['ownedChromeGeometry'][1]['rasterDerivedViewportTop'] = top
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_top_requires_all_36_bound_rows_and_capture_dimensions(self):
        report, spec = fixture(); report['geometry']['rowBands'].pop()
        with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)
        report, spec = fixture(); report['capture']['height'] += 1
        with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_viewport_overlap_and_outside_main_rectangle_reject(self):
        for bounds in ([[129, 140.001], [66, 20]], [[119, 130], [66, 20]],
                       [[129, 119], [66, 20]], [[129, 130], [1040, 20]]):
            report, spec = fixture(); report['ownedChromeGeometry'][1]['windows'][0]['bounds'] = bounds
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_nonfinite_and_degenerate_geometry_reject(self):
        for bounds in ([[float('nan'), 130], [66, 20]], [[129, 130], [0, 20]],
                       [[129, 130], [66, -1]], [[129, 130], [float('inf'), 20]],
                       [[True, 130], [66, 20]]):
            report, spec = fixture(); report['ownedChromeGeometry'][1]['windows'][0]['bounds'] = bounds
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_foreign_owner_main_id_and_invalid_native_ids_reject(self):
        for key, value in (('ownerPID', 9), ('ownerPID', True), ('windowID', 10),
                           ('windowID', 0), ('windowID', True), ('windowID', 0x100000000)):
            report, spec = fixture(); report['ownedChromeGeometry'][1]['windows'][0][key] = value
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_duplicate_chrome_id_in_a_single_observation_rejects(self):
        report, spec = fixture(); record = report['ownedChromeGeometry'][1]
        record['windows'].append(deepcopy(record['windows'][0]))
        with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_order_repetition_and_outside_audit_reject(self):
        for ticks in ((900, 300), (300, 300), (99, 900), (300, 2001), (300, 499), (300, 1001)):
            report, spec = fixture()
            for record, tick in zip(report['ownedChromeGeometry'], ticks): record['checkedTicks'] = tick
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_missing_or_null_window_fields_are_not_empty_chrome(self):
        for mutation in ('null-windows', 'null-item', 'missing-bounds', 'bad-rectangle', 'missing-top'):
            report, spec = fixture(); record = report['ownedChromeGeometry'][1]
            if mutation == 'null-windows': record['windows'] = None
            elif mutation == 'null-item': record['windows'] = [None]
            elif mutation == 'missing-bounds': del record['windows'][0]['bounds']
            elif mutation == 'bad-rectangle': record['windows'][0]['bounds'] = [129, 130, 66, 20]
            else: del record['rasterDerivedViewportTop']
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)

    def test_visibility_layer_and_alpha_types_are_checked(self):
        for key, value in (('onScreen', False), ('onScreen', 1), ('alpha', float('nan')),
                           ('alpha', 1.001), ('alpha', True), ('layer', None)):
            report, spec = fixture(); report['ownedChromeGeometry'][1]['windows'][0][key] = value
            with self.assertRaises(ValueError): checked_chrome_geometry(report, spec)
        report, spec = fixture()
        report['ownedChromeGeometry'][1]['windows'][0].update(alpha=0, layer=105)
        checked_chrome_geometry(report, spec)  # Native predicate allows same-owner chrome at any layer/alpha.

    def test_resealed_full_pair_cannot_drop_or_contradict_chrome_contract(self):
        with tempfile.TemporaryDirectory(prefix='scroll-synthetic-chrome-') as name:
            root = Path(name); metadata = build_records(root)
            self.assertEqual(load_scroll_evidence(root)['case'], 'scroll')
            folder = root / 'runs/00-cmdy'
            original = json.loads((folder / 'observation.json').read_text())
            raw_original = json.loads((folder / 'run.json').read_text())
            for mutation in ('missing', 'top', 'overlap', 'order', 'foreign-owner', 'duplicate', 'limit', 'legacy'):
                with self.subTest(mutation=mutation):
                    report = deepcopy(original)
                    records = report['ownedChromeGeometry']
                    record = records[1]
                    chrome = {'windowID': 777, 'ownerPID': report['appIdentity']['pid'], 'layer': 0,
                              'alpha': 1, 'onScreen': True, 'bounds': [[129, 130], [66, 20]]}
                    if mutation == 'missing': del report['ownedChromeGeometry']
                    elif mutation == 'top': record['rasterDerivedViewportTop'] += .001
                    elif mutation == 'overlap': chrome['bounds'][0][1] = 150; record['windows'] = [chrome]
                    elif mutation == 'order': records.reverse()
                    elif mutation == 'foreign-owner': chrome['ownerPID'] = 9; record['windows'] = [chrome]
                    elif mutation == 'duplicate': record['windows'] = [chrome, deepcopy(chrome)]
                    elif mutation == 'limit': report['ownedChromeGeometry'] = [records[0]] * 4097
                    else: report['schemaVersion'] = 1
                    write(folder / 'observation.json', report)
                    raw = deepcopy(raw_original); raw['observationSHA256'] = digest(folder / 'observation.json')
                    write(folder / 'run.json', raw)
                    changed = deepcopy(metadata)
                    item = next(item for item in changed['runs'] if item['path'] == 'runs/00-cmdy')
                    item.update(observationSHA256=digest(folder / 'observation.json'), runSHA256=digest(folder / 'run.json'))
                    write(root / 'manifest.json', changed)
                    with self.assertRaises((ValueError, KeyError)):
                        load_scroll_evidence(root)


if __name__ == '__main__':
    unittest.main()
