"""Comparison summaries must not admit interrupted runs or unmatched blocks."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('summarize.py')

def observation(block, variant):
    return dict(name=f'output-{block}-{variant}', family='output', block=block,
        variant=variant, status='pass', workloads=[dict(warmup=False, workload='continuous',
            payloadBytes=3_000_000, responseHex='1b5b3152', expectedResponseHex='1b5b3152', elapsedNS=1_000_000)])

class SummaryTests(unittest.TestCase):
    def summarize(self, status='partial', paired=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); output = root / 'summary.json'
            (root / 'result.json').write_text(json.dumps(dict(status=status, binaries={}, power={}, native={},
                records=[observation(0, 'baseline'), observation(0, 'candidate'), observation(1, 'candidate')])))
            subprocess.run([sys.executable, str(SCRIPT), '--input', str(root), '--output', str(output),
                *(['--paired-only'] if paired else [])], check=True, capture_output=True)
            return json.loads(output.read_text())

    def test_incomplete_pair_excludes_only_its_passed_counterpart(self):
        result = self.summarize()
        self.assertEqual([x['samples'] for x in result['metrics']], [1, 1])
        self.assertEqual(len(result['rejected']), 1)
        self.assertIn('no passed counterpart', result['rejected'][0]['exclusion'])

    def test_invalid_integrity_and_interrupted_runs_admit_no_samples(self):
        for status in ('invalid', 'running'):
            with self.subTest(status=status):
                self.assertEqual(self.summarize(status)['metrics'], [])

    def test_unpaired_mode_retains_standalone_diagnostic(self):
        result = self.summarize(paired=False)
        self.assertEqual([x['samples'] for x in result['metrics']], [1, 2])

    def test_same_block_numbers_from_distinct_runs_stay_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            roots = [Path(tmp) / name for name in ('first', 'second')]
            output = Path(tmp) / 'summary.json'
            for index, root in enumerate(roots):
                root.mkdir()
                records = [observation(0, variant) for variant in ('baseline', 'candidate')]
                for record in records:
                    record['workloads'][0]['elapsedNS'] *= index + 1
                (root / 'result.json').write_text(json.dumps(dict(status='pass',
                    binaries={}, power={}, native={}, records=records)))
            subprocess.run([sys.executable, str(SCRIPT), '--input', *map(str, roots),
                '--output', str(output), '--paired-only'], check=True, capture_output=True)
            for metric in json.loads(output.read_text())['metrics']:
                self.assertEqual(metric['samples'], 2)
                self.assertEqual(sorted(metric['blockMedians'].values()), [1, 2])

if __name__ == '__main__': unittest.main()
