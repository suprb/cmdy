"""CMDY-only resize pilot using the unchanged native pixel/clock oracles."""
from pathlib import Path
import sys
import tempfile
import time
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'NativePerformance'))
import compare_resize as shared

def wait_for_target(session, target, *, clock=time.monotonic, pause=time.sleep):
    """Observe the exact untimed setup target for 250 ms, without resizing."""
    start = clock(); stable_since = None; observations = []
    while True:
        now = clock()
        if now - start >= 3:
            raise RuntimeError('native setup target did not settle; no correction attempted')
        windows = session.window()['windows']
        if len(windows) != 1:
            raise RuntimeError('native setup requires exactly one owned window')
        bounds = windows[0]['bounds']
        observations.append(dict(elapsedSeconds=now - start, bounds=bounds))
        if bounds == target:
            if stable_since is None: stable_since = now
            if now - stable_since >= .25:
                return dict(status='pass', target=target, stableSeconds=now - stable_since,
                    observations=observations, resizeRequests=0)
        else:
            stable_since = None
        pause(.025)

def record(root, plan, conditions, native_conditions):
    c = shared.c
    directory = root / 'observations/cmdy'; fixture = directory / 'fixture'
    control = tempfile.TemporaryDirectory(prefix='cmdy-resize-control-', dir='/private/tmp')
    capability = uuid.uuid4().hex; session = None
    item = dict(status='failed', terminal='cmdy', qualifying=False, scope='development diagnostic, not paired parity')
    try:
        command = [plan['python'], '-B', str(root / 'tooling/Tests/resize_worker.py'), '--output', str(fixture),
            '--socket-directory', control.name, '--capability', capability, '--nonce', plan['nonce'], '--timeout', '90']
        binary = Path(plan['binaries']['cmdy']['path'])
        options = c.bench.BenchOptions(binary, binary, profile='cmdy-defaults', font_size=14, timeout=15, tooling_dir=root / 'tooling/Tests')
        session = c.bench.TerminalSession(options, Path(plan['helper']), 'cmdy', directory, shared.SMALL,
            fixture_command=command, ready_path=fixture / 'ready.json')
        conditions(); session.launch(); session.window(activate=True); session.place_window(120, 120)
        session.fit_grid(shared.SMALL, allow_resize=True)
        # Settle AppKit's initial native tab/titlebar layout before preparing
        # the fixture. No fitting or retry is permitted after preparation.
        time.sleep(1)
        session.fit_grid(shared.SMALL, allow_resize=True)
        time.sleep(.5)
        c.write_new(directory / 'pointer-setup.json', c.bench.window_command(session.helper, 'park-pointer', session.app_pid))
        window = session.window()['windows'][0]
        assert window['displayID'] == plan['displayID'] and session.worker_identity
        prepared = shared.worker_request(session.ready, capability, 'prepare')
        c.write_new(directory / 'worker-prepare.json', prepared)
        assert prepared['history']['payloadSHA256'] == plan['historySHA256']
        assert prepared['history']['offeredBytes'] == prepared['history']['completedBytes'] == 147000
        spec = dict(pid=session.app_pid, workerPID=session.worker_identity[0], ttyPath=session.ready['ttyPath'],
            executableSHA256=plan['binaries']['cmdy']['sha256'], windowID=window['windowID'], displayID=window['displayID'],
            nonce=plan['nonce'], lowPowerMode=native_conditions['lowPowerMode'], thermalState=native_conditions['thermalState'], timeoutSeconds=40)
        def settle_target(target):
            c.write_new(directory / 'calibration/target-settled.json', wait_for_target(session, target))
        small, large = shared.calibrate(Path(plan['observer']), directory / 'calibration', spec, session,
            capability, conditions, settle_target=settle_target)
        request = dict(schemaVersion=1, qualifying=False, nonce=plan['nonce'], nativeSpec=spec,
            workerReady=session.ready, workerCapability=capability, source=large['calibration'], target=small['calibration'],
            sourceDiscovery=large, targetDiscovery=small, sourceSequence=1, planned=shared.PLANNED)
        conditions()
        result = shared.recorder.record_diagnostic(Path(plan['observer']), Path(plan['observerBuild']), request, directory / 'event')
        grid = session.grid()
        assert result['diagnosticValid'] and (grid['columns'], grid['rows']) == shared.SMALL
        c.write_new(directory / 'worker-finish.json', shared.worker_request(session.ready, capability, 'finish'))
        deadline = time.monotonic() + 3
        while c.bench.process_identity(session.worker_identity[0]) == session.worker_identity[1] and time.monotonic() < deadline: time.sleep(.02)
        assert (fixture / 'cleanup.json').is_file()
        item.update(status='pass', eventSHA256=c.sha(directory / 'event/event.json'))
    except BaseException as error: item['error'] = repr(error); raise
    finally:
        if session is not None: shared.close_session(session, control, directory)
        else: control.cleanup()
        c.write_new(directory / 'pilot.json' if directory.exists() else root / 'failure.json', item)
