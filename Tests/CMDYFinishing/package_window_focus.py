"""Give the isolated package diagnostic one explicit owned-window activation."""
import hashlib
import json
from pathlib import Path
import subprocess
import time


def activate_owned_window(process, helper, binary, output, *, timeout=5.0):
    helper, binary, output = map(Path, (helper, binary, output))
    record = dict(status='waiting-for-owned-window', appPID=process.pid,
                  executable=str(binary), helper=str(helper),
                  helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest(),
                  activationActions=0, inputEventsPosted=0, clipboardAccessed=False,
                  observations=[], startedMonotonicNS=time.monotonic_ns())
    try:
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            probe = subprocess.run([str(helper), 'inspect', str(process.pid)],
                                   capture_output=True, text=True, timeout=2)
            state = json.loads(probe.stdout) if probe.stdout else {}
            record['observations'].append(dict(finishedMonotonicNS=time.monotonic_ns(),
                exitCode=probe.returncode, state=state, stderr=probe.stderr))
            if probe.returncode == 0 and state.get('ok'):
                if state.get('pid') != process.pid or state.get('executable') != str(binary):
                    raise RuntimeError('Package window process identity differs')
                windows = state.get('windows', [])
                if any(window.get('onScreen') and window.get('ownerPID') == process.pid for window in windows):
                    if process.poll() is not None:
                        raise RuntimeError('Package process exited before activation')
                    record['activationActions'] = 1
                    started = time.monotonic_ns()
                    activation = subprocess.run([str(helper), 'activate', str(process.pid)],
                                                capture_output=True, text=True, timeout=3)
                    result = json.loads(activation.stdout) if activation.stdout else {}
                    record['activation'] = dict(startedMonotonicNS=started,
                        finishedMonotonicNS=time.monotonic_ns(), exitCode=activation.returncode,
                        state=result, stderr=activation.stderr)
                    if (activation.returncode != 0 or not result.get('ok')
                            or result.get('frontmostPID') != process.pid
                            or result.get('pid') != process.pid
                            or result.get('executable') != str(binary)):
                        raise RuntimeError('macOS did not activate the exact owned package window')
                    record['status'] = 'pass'
                    return record
            time.sleep(.1)
        raise RuntimeError('Package process exited or its owned window did not appear')
    except BaseException as error:
        record.update(status='fail', error=repr(error))
        raise
    finally:
        record['finishedMonotonicNS'] = time.monotonic_ns()
        with output.open('x') as stream:
            json.dump(record, stream, indent=2)
            stream.write('\n')
