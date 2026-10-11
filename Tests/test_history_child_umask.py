"""Real Python children and generated files; no terminal app, helper or UI."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import competitive_bench as bench
from memory_public_history import PublicHistorySession
import compare_history as pilot
from history_export_build import PUBLIC_TOOLING
from history_export_protocol import expectation, memory_payload

CHILD = r'''
import json, os, pathlib, stat, subprocess, sys, time
ready, stop = map(pathlib.Path, sys.argv[1:])
root = pathlib.Path(os.environ['TMPDIR'])
def create(name):
    directory = root / (name + '-directory'); directory.mkdir(mode=0o755)
    path = directory / 'generated.txt'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    os.write(fd, b'generated-only'); os.close(fd)
    return dict(directoryMode=stat.S_IMODE(directory.stat().st_mode), fileMode=stat.S_IMODE(path.stat().st_mode))
child = create('child')
grandchild_code = """
import json, os, pathlib, stat
root = pathlib.Path(os.environ['TMPDIR'])
directory = root / 'grandchild-directory'; directory.mkdir(mode=0o755)
path = directory / 'generated.txt'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
os.write(fd, b'generated-only'); os.close(fd)
print(json.dumps(dict(pid=os.getpid(), parentPID=os.getppid(), directoryMode=stat.S_IMODE(directory.stat().st_mode), fileMode=stat.S_IMODE(path.stat().st_mode))))
"""
grandchild = subprocess.run([sys.executable, '-B', '-c', grandchild_code], check=True, capture_output=True, text=True)
value = dict(pid=os.getpid(), child=child, grandchild=json.loads(grandchild.stdout), grandchildReaped=True,
             grandchildExitCode=grandchild.returncode, readyMonotonicNS=time.perf_counter_ns())
ready.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
temporary = ready.with_suffix('.tmp'); temporary.write_text(json.dumps(value)); temporary.replace(ready)
deadline = time.monotonic() + 10
while not stop.exists() and time.monotonic() < deadline: time.sleep(.01)
if not stop.exists(): raise SystemExit(2)
'''


class ChildUmaskTests(unittest.TestCase):
    def test_only_explicit_0077_is_allowed_and_invalid_options_create_nothing(self):
        with tempfile.TemporaryDirectory(prefix='cmdy-history-umask-', dir='/private/tmp') as name:
            root = Path(name)
            for value in (0, 0o022, 0o700, -1, True, '0077', 63.0):
                path = root / str(value)
                with patch.object(bench.subprocess, 'Popen') as launch, self.assertRaisesRegex(ValueError, '0077'):
                    bench.TerminalSession(bench.BenchOptions(Path('/cmdy'), Path('/ghostty')), Path('/helper'),
                        'cmdy', path, fixture_command=['/fixture'], child_umask=value)
                launch.assert_not_called(); self.assertFalse(path.exists())

    def test_real_children_inherit_requested_mask_and_parent_mask_never_changes(self):
        real_popen = subprocess.Popen
        with tempfile.TemporaryDirectory(prefix='cmdy-history-umask-', dir='/private/tmp') as name:
            root = Path(name); payload = root / 'payload.bin'
            payload.write_bytes(memory_payload(expectation('primary-1000', '1' * 32)))
            driver = root / 'child.py'; driver.write_text(CHILD)
            def parent_modes(label):
                directory = root / label; directory.mkdir(mode=0o755)
                path = directory / 'generated.txt'
                fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o666); os.close(fd)
                return dict(directoryMode=stat.S_IMODE(directory.stat().st_mode), fileMode=stat.S_IMODE(path.stat().st_mode))
            before = parent_modes('parent-before'); cases = []
            options = bench.BenchOptions(Path('/owned/cmdy'), Path('/owned/ghostty'), payload=payload,
                tooling_dir=Path(__file__).resolve().parent, timeout=5)
            with patch.object(os, 'umask', side_effect=AssertionError('parent umask must never change')):
                for mask in (None, 0o077):
                    for terminal in ('cmdy', 'ghostty'):
                        public = PublicHistorySession(options, Path('/never-run-helper'), terminal,
                            root / f'{terminal}-{mask}', 'primary-1000', payload, '1' * 16,
                            Path(sys.executable), child_umask=mask)
                        session = public.session; stop = session.directory / 'stop'; calls = []
                        private = [Path(session.temporary.name), Path(public.export_directory.name), Path(public.control_directory.name)]
                        def launch(arguments, **kwargs):
                            self.assertEqual(arguments[0], '/owned/' + terminal)
                            self.assertEqual(kwargs.get('umask'), mask)
                            self.assertEqual('umask' in kwargs, mask is not None)
                            self.assertNotIn('preexec_fn', kwargs); self.assertNotIn('shell', kwargs)
                            calls.append(dict(arguments=arguments, childUmask=kwargs.get('umask')))
                            # Exercise the real Popen and OS inheritance from the
                            # production launch call, replacing only its executable.
                            return real_popen([sys.executable, '-B', str(driver), str(session.ready_path), str(stop)], **kwargs)
                        try:
                            with patch.object(bench.subprocess, 'Popen', side_effect=launch), \
                                    patch.object(bench, 'is_descendant', return_value=False):
                                ready = session.launch()
                            # This launch-only fixture has no terminal or native
                            # ancestry proof. Its descendant has already exited.
                            self.assertIsNone(session.worker_identity)
                            self.assertEqual(len(calls), 1)
                            expected = before if mask is None else dict(directoryMode=0o700, fileMode=0o600)
                            self.assertEqual(ready['child'], expected)
                            self.assertEqual({key: ready['grandchild'][key] for key in expected}, expected)
                            self.assertEqual(ready['grandchild']['parentPID'], session.app_pid)
                            self.assertTrue(ready['grandchildReaped']); self.assertEqual(ready['grandchildExitCode'], 0)
                            for filename in ('launch.json', 'public-history-binding.json'):
                                value = json.loads((session.directory / filename).read_text())
                                self.assertEqual(value.get('childUmask'), mask)
                                self.assertEqual('childUmask' in value, mask is not None)
                            stop.touch(mode=0o600); self.assertEqual(session.process.wait(timeout=5), 0)
                            for pid in (session.app_pid, ready['grandchild']['pid']):
                                with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
                            cases.append(dict(terminal=terminal, requestedChildUmask=mask, observed=ready,
                                launch=calls[0], childReaped=True, childExitCode=session.process.returncode))
                        finally:
                            stop.touch(mode=0o600)
                            # The fixture never created a defaults suite. Stub
                            # only those cleanup commands; no OS query executes.
                            with patch.object(bench, 'command_result', return_value={'returncode': 0}): public.close()
                        self.assertTrue(all(not path.exists() for path in private))
                after = parent_modes('parent-after')
            self.assertEqual(before, after)
            (root / 'umask-observation.json').write_text(json.dumps(dict(parentBefore=before, parentAfter=after,
                cases=cases, parentUmaskFunctionNeverCalled=True, nativeAppsRun=False, nativeHelpersRun=False), indent=2))

    def test_failed_child_launch_keeps_owned_cleanup_and_does_not_change_parent_mask(self):
        with tempfile.TemporaryDirectory(prefix='cmdy-history-umask-', dir='/private/tmp') as name:
            session = bench.TerminalSession(bench.BenchOptions(Path('/cmdy'), Path('/ghostty')), Path('/helper'),
                'cmdy', Path(name) / 'session', fixture_command=['/fixture'], child_umask=0o077)
            private = Path(session.temporary.name)
            with patch.object(os, 'umask', side_effect=AssertionError('parent change')), \
                    patch.object(bench.subprocess, 'Popen', side_effect=OSError('generated launch failure')) as launch:
                try:
                    with self.assertRaisesRegex(OSError, 'generated launch failure'): session.launch()
                    self.assertEqual(launch.call_args.kwargs['umask'], 0o077)
                finally: session.close()
            self.assertFalse(private.exists()); self.assertTrue(session.log.closed)

    def test_preparation_cannot_reuse_old_or_mismatched_launch_qualification(self):
        with tempfile.TemporaryDirectory(prefix='cmdy-history-umask-', dir='/private/tmp') as name:
            root = Path(name); tests = Path(__file__).resolve().parent
            base = dict(status='headlessly-qualified-public-history-tooling', childUmask=0o077,
                publicToolingSHA256={key: bench.sha256(tests / key) for key in PUBLIC_TOOLING},
                publicHistoryLaunchSHA256={key: bench.sha256(tests / key) for key in pilot.LAUNCH_TOOLING})
            for index, mutate in enumerate((lambda q: q.pop('childUmask'), lambda q: q.update(childUmask=0o022),
                    lambda q: q.pop('publicHistoryLaunchSHA256'),
                    lambda q: q['publicHistoryLaunchSHA256'].update({'competitive_bench.py': '0' * 64}))):
                value = json.loads(json.dumps(base)); mutate(value)
                qualification = root / f'q-{index}.json'; qualification.write_text(json.dumps(value))
                args = SimpleNamespace(candidate=root, output=root / f'prepared-{index}', history_qualification=qualification)
                with patch.object(pilot.coordinator.candidate_preparation, 'verify', return_value={}), \
                        patch.object(subprocess, 'Popen', side_effect=AssertionError('no process needed')):
                    with self.assertRaisesRegex(RuntimeError, 'child launch differs'): pilot.prepare(args)
                self.assertFalse((args.output / 'history-helper').exists()); self.assertFalse((args.output / 'plan.json').exists())


if __name__ == '__main__': unittest.main()
