"""Scroll worker command uses the same canonical runtime as its launch proof."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from competitive_bench import BenchOptions, binary_metadata
from scroll_bench import run_owned


class ScrollRuntimePathTests(unittest.TestCase):
    def test_alias_uses_pinned_canonical_runtime_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / 'python3.13'; runtime.write_text('synthetic non-executable')
            alias = root / 'python3'; alias.symlink_to(runtime)
            tooling = root / 'tooling'; tooling.mkdir()
            options = BenchOptions(Path('/synthetic/cmdy'), Path('/synthetic/unused'), tooling_dir=tooling)
            metadata = {'runtime': {'python': binary_metadata(alias)}}
            captured = {}
            def intercept(*args, **kwargs):
                captured.update(kwargs)
                raise RuntimeError('stop before native setup')
            with patch('scroll_bench.sys.executable', str(alias)), \
                 patch('scroll_bench.TerminalSession', side_effect=intercept), \
                 patch('scroll_bench.window_command') as window, \
                 self.assertRaisesRegex(RuntimeError, 'stop before native setup'):
                run_owned(options, None, None, 'cmdy', root / 'run', '0' * 32, metadata)
            window.assert_not_called()
            self.assertEqual(captured['fixture_command'][:3],
                [str(runtime.resolve()), '-S', str(tooling / 'scroll_worker.py')])


if __name__ == '__main__': unittest.main()
