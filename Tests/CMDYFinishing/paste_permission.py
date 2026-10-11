"""Explicit Automation permission setup for a newly launched isolated terminal."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TESTS))
import competitive_bench as bench

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--permission-helper', type=Path, required=True)
    parser.add_argument('--terminal', choices=('cmdy', 'ghostty'), default='cmdy')
    parser.add_argument('--request', action='store_true', required=True)
    args = parser.parse_args()
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    binary = args.app.resolve() / 'Contents/MacOS' / args.terminal
    payload = root / 'payload.bin'; payload.write_bytes(b'Terminal permission setup\r\n')
    options = bench.BenchOptions(binary, binary, payload=payload, profile='cmdy-defaults', timeout=30, tooling_dir=TESTS)
    result = dict(status='running', authorization='explicit user request to open macOS prompt',
        terminal=args.terminal, executable=bench.binary_metadata(binary),
        clipboardAccessed=False, appleEventsSent=False, performanceAdmission=False)
    try:
        with bench.TerminalSession(options, args.helper.resolve(), args.terminal, root / 'session', (120, 36)) as session:
            session.launch(); session.window(activate=True)
            command = [str(args.permission_helper.resolve()), '--request', str(session.app_pid), str(binary)]
            print(json.dumps(dict(status='opening-permission-prompt', terminal=args.terminal,
                                  appPID=session.app_pid)), flush=True)
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            result.update(permissionHelperPID=process.pid, permissionCommand=command)
            try:
                stdout, stderr = process.communicate(timeout=180)
            finally:
                if process.poll() is None: process.terminate(); process.wait(timeout=10)
            (root / 'native.log').write_text(stderr)
            result.update(native=json.loads(stdout), exitCode=process.returncode, permissionHelperReaped=True)
            result['status'] = 'authorized' if process.returncode == 0 else 'not-authorized'
    except BaseException as error:
        result.update(status='failed', error=repr(error))
        raise
    finally:
        bench.atomic_json(root / 'result.json', result)
    print(json.dumps(result, indent=2))

if __name__ == '__main__': main()
