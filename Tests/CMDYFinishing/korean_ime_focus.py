"""Compare generated Korean composition in an owned NSTextView and exact CMDY app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'Tests'))
from competitive_bench import launch_environment, power_snapshot

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--focus-bridge', type=Path, required=True)
    parser.add_argument('--reference-executable', type=Path, required=True)
    parser.add_argument('--window', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--regression-input', type=Path,
                        help='Also check installed Japanese IME and native dead-key/control input after Korean passes.')
    parser.add_argument('--trace-callbacks', action='store_true', help='Diagnostic-only package: trace only run-tagged generated input callbacks.')
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    helper = args.helper.resolve()
    reference_binary = args.reference_executable.resolve()
    binary = args.app.resolve() / 'Contents/MacOS/cmdy'
    tag = os.environ['CMDY_NATIVE_EVENT_TAG']
    root = Path(tempfile.mkdtemp(prefix='cmdy-korean-owned-', dir='/private/tmp'))
    os.chmod(root, 0o700)
    for name in ['cwd', 'cmdy-config', 'zsh', 'xdg-config', 'xdg-cache', 'xdg-data', 'xdg-state', 'reference']:
        (root / name).mkdir(mode=0o700)
    domain = 'com.cmdy.finishing.' + uuid.uuid4().hex
    result = dict(status='running', power=power_snapshot(), cases=[], runtime=str(root),
                  clipboardAccessed=False, executableSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest(),
                  keySequence={'commit': [15, 40, 36], 'cancel': [15, 40, 51, 51]},
                  reference='owned native NSTextView; actual macOS Korean 2-set input service')
    def save():
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    def call(*parts):
        r = subprocess.run([str(helper), *map(str, parts)], capture_output=True, text=True, timeout=10)
        value = json.loads(r.stdout)
        if r.returncode:
            raise RuntimeError(f'IME helper {parts[0]} failed: {value}')
        return value
    def until(test, description, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = test()
            if value:
                return value
            time.sleep(.05)
        raise TimeoutError(description)
    def worker_command(path, command='state'):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3); client.connect(str(path))
            client.sendall(json.dumps({'command': command}).encode() + b'\n')
            data = b''
            while not data.endswith(b'\n'):
                part = client.recv(65536)
                if not part:
                    raise RuntimeError('owned worker closed before response')
                data += part
            return json.loads(data)
    def activate(pid):
        subprocess.run([str(args.window), 'activate', str(pid)], check=True, capture_output=True)
        check = subprocess.run([str(args.window), 'inspect', str(pid)], capture_output=True, text=True)
        # The key helper independently validates exact executable and foreground for every event.
        if check.returncode == 0:
            return json.loads(check.stdout)
        return {'activationExitCode': 0}
    def focus_round_trip(pid, executable, expected_source, label):
        path = out / (label + '-focus.json')
        child = subprocess.Popen([str(args.focus_bridge.resolve()), str(pid), str(executable), str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = child.communicate(timeout=12)
        finally:
            if child.poll() is None: child.terminate(); child.wait(timeout=5)
        receipt = json.loads(path.read_text()) if path.exists() else {}
        entry = {'label':label, 'pid':child.pid, 'exitCode':child.returncode, 'reaped':child.poll() is not None, 'receipt':receipt}
        result.setdefault('focusBoundaries', []).append(entry); save()
        assert child.returncode == 0 and receipt.get('status') == 'pass', (receipt, stderr)
        assert receipt['targetPID'] == pid and receipt['targetExecutable'] == str(executable)
        assert receipt['awayForegroundPID'] == child.pid and receipt['returnedForegroundPID'] == pid
        assert receipt['initialSource'] == receipt['finalSource'] == expected_source
        assert receipt['inputEventsPosted'] == 0 and not receipt['inputSourceSelected'] and not receipt['clipboardAccessed']
        assert receipt['returnedUptime'] > receipt['awayUptime']
    def keys(pid, executable, codes):
        for code in codes:
            receipt = call('key-hid', pid, executable, code, tag)
            assert receipt['foregroundAndExecutableCheckedPerEvent'] and receipt['events'] == 2
            result.setdefault('ownedKeyReceipts', []).append(receipt)
            save()
    def refstate():
        path = root / 'reference/state.json'
        return json.loads(path.read_text()) if path.exists() else None
    def refcommand(command):
        identifier = uuid.uuid4().hex
        path = root / 'reference/command.json'
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps({'id': identifier, 'command': command}))
        temporary.replace(path)
        return until(lambda: (s if (s := refstate()) and s['lastCommand'] == identifier else None), 'reference command acknowledgement')
    def stop(*_):
        raise KeyboardInterrupt('owned Korean IME diagnostic interrupted')
    signal.signal(signal.SIGTERM, stop)
    app = ref = None
    worker_socket = None
    snapshot = root / 'input-sources-before.json'
    streams = []
    try:
        call('snapshot', snapshot)
        result['enable'] = call('enable'); save()
        log = (out / 'reference.log').open('w'); streams.append(log)
        ref = subprocess.Popen([str(reference_binary), 'reference', str(root / 'reference')], stdout=log, stderr=subprocess.STDOUT)
        result['referencePID'] = ref.pid; save()
        until(lambda: (s if (s := refstate()) and s['firstResponderIsView'] and s['active'] else None), 'reference app readiness')
        activate(ref.pid)
        result['referenceSelection'] = call('select'); save()
        result['referenceContextActivation'] = refcommand('activate-korean'); save()
        state = until(lambda: (s if (s := refstate()) and s['selectedSource'] == 'com.apple.inputmethod.Korean.2SetKorean' else None), 'reference text context did not activate Korean source')
        result['referenceReady'] = state; save()
        # Keep this fixed settling interval visible; selected-source metadata alone
        # did not prove that the first event reached the service in attempt 04.
        result['referenceServiceSettleSeconds'] = 2; save()
        focus_round_trip(ref.pid, reference_binary, 'com.apple.inputmethod.Korean.2SetKorean', 'reference-korean')
        time.sleep(2)
        keys(ref.pid, reference_binary, [15, 40])  # ANSI r,k => Korean 2-set 가
        time.sleep(.5)
        preedit = refstate(); result['referencePreedit'] = preedit; save()
        # NSTextView may compose Korean through insertText replacement ranges.
        # Qualify generated text semantics; CMDY's no-early-PTY-byte check remains strict.
        assert preedit['string'] == '가', 'reference did not compose expected Korean text'
        result['referenceCompositionPath'] = 'marked-text' if preedit['hasMarkedText'] else 'text-replacement'
        keys(ref.pid, reference_binary, [36]); time.sleep(.4)
        committed = refstate(); result['referenceCommitted'] = committed; save()
        assert not committed['hasMarkedText'] and committed['string'] == '가', 'reference Korean commit differs'
        refcommand('clear')
        keys(ref.pid, reference_binary, [15, 40, 51, 51]); time.sleep(.4)
        cancelled = refstate(); result['referenceCancelled'] = cancelled; save()
        assert not cancelled['hasMarkedText'] and cancelled['string'] == '', 'reference Korean cancellation differs'
        result['referenceStatus'] = 'pass'; save()
        if args.regression_input:
            refcommand('clear')
            result['japaneseReferenceSelection'] = call('select-japanese'); save()
            refcommand('activate-japanese')
            focus_round_trip(ref.pid, reference_binary, 'com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese', 'reference-japanese')
            time.sleep(2)
            keys(ref.pid, reference_binary, [45, 34, 4, 31, 45, 36]); time.sleep(.4)
            result['japaneseReferenceCommitted'] = refstate(); save()
            assert result['japaneseReferenceCommitted']['string'] == 'にほん'
            assert not result['japaneseReferenceCommitted']['hasMarkedText']
            refcommand('clear')
            keys(ref.pid, reference_binary, [40, 0]); time.sleep(.3)
            result['japaneseReferencePreedit'] = refstate(); save()
            assert result['japaneseReferencePreedit']['string'] == 'か'
            result['japaneseReferenceCancellation'] = []
            for _ in range(2):
                keys(ref.pid, reference_binary, [53]); time.sleep(.3)
                state = refstate()
                result['japaneseReferenceCancellation'].append(state); save()
                if not state['hasMarkedText'] and state['string'] == '':
                    break
            assert not state['hasMarkedText'] and state['string'] == '', 'reference Japanese cancellation differs'
            result['japaneseCancelKeys'] = [53] * len(result['japaneseReferenceCancellation'])
            result['japaneseReferenceStatus'] = 'pass'; save()
        ref.terminate(); ref.wait(timeout=10); result['referenceReaped'] = True; save()

        (root / 'cmdy-config/config').write_text(
            'restore-session = false\nmarketplace-update-checks = false\nautomatic-error-help = false\n'
            'shell-integration = false\nclean-prompt = false\nsounds = false\nghost-text = false\n'
            'shader = None\nfont-family = Menlo-Regular\nfont-size = 14\nworkspace-inspector = false\n'
            'workspace-navigator = false\nwindow-grid = false\n')
        (root / 'zsh/.zshenv').write_text('exec ' + shlex.join([
            str(Path(sys.executable).resolve()), '-B', str(REPO / 'Tests/CMDYFinishing/worker.py'), str(root)]) + '\n')
        env = launch_environment(os.environ, root, root / 'cwd', domain)
        if args.trace_callbacks:
            env['CMDY_IME_DIAGNOSTIC_PATH'] = str(root / 'ime-callbacks.jsonl')
            env['CMDY_IME_DIAGNOSTIC_TAG'] = tag
            result['callbackTrace'] = env['CMDY_IME_DIAGNOSTIC_PATH']; save()
        log = (out / 'cmdy.log').open('w'); streams.append(log)
        app = subprocess.Popen([str(binary)], cwd=root / 'cwd', env=env, stdout=log, stderr=subprocess.STDOUT)
        result['appPID'] = app.pid; save()
        discovery = root / 'cmdy-config/extension-api.json'
        until(lambda: discovery.exists() and discovery.stat().st_size, 'owned app API discovery')
        credentials = json.loads(discovery.read_text())
        def api(path):
            request = urllib.request.Request(f"http://127.0.0.1:{credentials['port']}" + path,
                headers={'Authorization': 'Bearer ' + credentials['token']})
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.load(response)
        pane = until(lambda: next((p for p in api('/v1/panes')['panes'] if p['pid'] > 0), None), 'owned PTY readiness')
        worker = pane['pid']; result['workerPID'] = worker
        worker_socket = root / f'w-{worker}.sock'
        until(worker_socket.exists, 'owned worker socket')
        until(lambda: api('/v1/debug/framestats').get('frames', 0) > 0, 'owned app GPU frame')
        assert worker_command(worker_socket)['parentPID'] == app.pid
        activate(app.pid)
        result['cmdySelection'] = call('select'); save()
        until(lambda: call('inspect')['selectedSource'] == 'com.apple.inputmethod.Korean.2SetKorean', 'CMDY Korean selection')
        result['cmdyServiceSettleSeconds'] = 2; save()
        focus_round_trip(app.pid, binary, 'com.apple.inputmethod.Korean.2SetKorean', 'cmdy-korean')
        time.sleep(2)
        for index in range(3):
            worker_command(worker_socket, 'clear-input')
            keys(app.pid, binary, [15, 40]); time.sleep(.5)
            case = {'index': index, 'preeditInputHex': worker_command(worker_socket)['inputHex']}
            result['cases'].append(case); save()
            case['errors'] = []
            if case['preeditInputHex'] != '':
                case['errors'].append('Korean preedit leaked PTY bytes')
            keys(app.pid, binary, [36]); time.sleep(.4)
            case['committedInputHex'] = worker_command(worker_socket)['inputHex']; save()
            if case['committedInputHex'] != '가'.encode().hex():
                case['errors'].append('Korean commit differs from reference')
            worker_command(worker_socket, 'clear-input')
            keys(app.pid, binary, [15, 40, 51, 51]); time.sleep(.4)
            case['cancelledInputHex'] = worker_command(worker_socket)['inputHex']; save()
            if case['cancelledInputHex'] != '':
                case['errors'].append('cancelled Korean composition emitted bytes')
            case['status'] = 'failed' if case['errors'] else 'pass'; save()
        result['status'] = 'pass' if all(c['status'] == 'pass' for c in result['cases']) else 'failed'
        if result['status'] == 'failed':
            result['error'] = 'Korean exact-byte contract failed; all three generated cases retained'
        if result['status'] == 'pass' and args.regression_input:
            result['regressions'] = []
            japanese = 'com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese'
            result['japaneseSelection'] = call('select-japanese'); save()
            assert result['japaneseSelection']['selectedSource'] == japanese
            focus_round_trip(app.pid, binary, japanese, 'cmdy-japanese')
            time.sleep(2)
            for index in range(3):
                worker_command(worker_socket, 'clear-input')
                keys(app.pid, binary, [45, 34, 4, 31, 45])  # nihon
                time.sleep(.4)
                check = {'name': 'Japanese system IME', 'index': index,
                         'preeditInputHex': worker_command(worker_socket)['inputHex']}
                result['regressions'].append(check); save()
                assert check['preeditInputHex'] == '', 'Japanese preedit leaked bytes'
                keys(app.pid, binary, [36]); time.sleep(.4)
                check['committedInputHex'] = worker_command(worker_socket)['inputHex']; save()
                assert check['committedInputHex'] == 'にほん'.encode().hex(), 'Japanese commit differs'
                worker_command(worker_socket, 'clear-input')
                keys(app.pid, binary, [40, 0]); time.sleep(.3)  # ka
                keys(app.pid, binary, result['japaneseCancelKeys']); time.sleep(.3)
                check['cancelledInputHex'] = worker_command(worker_socket)['inputHex']; save()
                assert check['cancelledInputHex'] == '', 'Japanese cancellation emitted bytes'
                # A no-byte Escape alone is insufficient: prove no preedit was
                # retained by committing a new independent composition.
                keys(app.pid, binary, [45, 34, 4, 31, 45, 36]); time.sleep(.3)
                check['postCancelCommitHex'] = worker_command(worker_socket)['inputHex']; save()
                assert check['postCancelCommitHex'] == 'にほん'.encode().hex(), 'Japanese cancellation retained preedit'
                check['status'] = 'pass'; save()
            original = json.loads(snapshot.read_text())['originalSource']
            result['keyboardSelection'] = call('select-enabled', original); save()
            focus_round_trip(app.pid, binary, original, 'cmdy-keyboard')
            time.sleep(2)
            window_state = activate(app.pid)
            window_id = window_state['windows'][0]['windowID']
            worker_command(worker_socket, 'clear-input')
            check = {'name': 'native dead key and control input', 'events': []}
            result['regressions'].append(check); save()
            for phase, expected in [('dead-key', b''), ('plain-e', 'é'.encode()),
                                    ('ascii-control', 'éa'.encode() + b'\x03')]:
                completed = subprocess.run([str(args.regression_input), str(app.pid), str(window_id), phase],
                    capture_output=True, text=True, timeout=15, check=True)
                receipt = json.loads(completed.stdout)
                assert receipt['ok']
                time.sleep(.3)
                received = worker_command(worker_socket)['inputHex']
                check['events'].append({'phase': phase, 'receivedHex': received, 'expectedHex': expected.hex()})
                save(); assert received == expected.hex(), 'dead-key/control regression: ' + phase
            worker_command(worker_socket, 'clear-input')
            keys(app.pid, binary, [36, 123, 51, 53]); time.sleep(.3)
            check['ordinaryControlHex'] = worker_command(worker_socket)['inputHex']; save()
            assert check['ordinaryControlHex'] == b'\r\x1b[D\x7f\x1b'.hex(), 'ordinary control-key bytes differ'
            check['status'] = 'pass'; save()
    except BaseException as error:
        result.update(status='failed', error=repr(error))
    finally:
        # Every process here was launched and retained by this controller.
        if worker_socket is not None and worker_socket.exists():
            try:
                worker_command(worker_socket, 'stop')
            except Exception as error:
                result['workerStopError'] = repr(error)
        for name, process in [('app', app), ('reference', ref)]:
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                try:
                    result[name + 'ExitCode'] = process.wait(timeout=15)
                    result[name + 'Reaped'] = True
                except subprocess.TimeoutExpired:
                    result[name + 'Reaped'] = False
                    result['status'] = 'failed'
        if snapshot.exists():
            try:
                restore = subprocess.run([str(helper), 'restore', str(snapshot), str(out / 'restoration.json')],
                    capture_output=True, text=True, timeout=10)
                result['immediateRestoration'] = dict(exitCode=restore.returncode, receipt=json.loads(restore.stdout))
                after = out / 'restoration-snapshot.json'
                call('snapshot', after)
                before_state, after_state = json.loads(snapshot.read_text()), json.loads(after.read_text())
                restored = before_state == after_state
                result['restoration'] = {'status': 'pass' if restored else 'failed',
                    'verification': 'independent fresh-process snapshot',
                    'sourceRestored': before_state['originalSource'] == after_state['originalSource'],
                    'enabledSourcesRestored': before_state['enabledIDs'] == after_state['enabledIDs'],
                    'enabledPreferencesRestored': before_state['enabledPreferences'] == after_state['enabledPreferences']}
                (out / 'restoration-final.json').write_text(json.dumps(result['restoration'], indent=2) + '\n')
                if not restored:
                    result['status'] = 'failed'
            except Exception as error:
                result.update(status='failed', restorationError=repr(error))
        subprocess.run(['/usr/bin/defaults', 'delete', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for stream in streams:
            stream.close()
        save()
    print(json.dumps({'status': result['status'], 'referencePassed': result.get('referenceStatus') == 'pass',
                      'completedCases': sum(c.get('status') == 'pass' for c in result['cases']),
                      'restoration': result.get('restoration', {}).get('status'), 'error': result.get('error')}), flush=True)
    return 0 if result['status'] == 'pass' else 1

if __name__ == '__main__':
    raise SystemExit(main())
