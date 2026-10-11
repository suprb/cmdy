#!/usr/bin/env python3
"""Build isolated, signed IME fixtures without launching apps or changing input settings."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New output directory')
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve().parent
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    record = {'status': 'building', 'steps': [], 'appsLaunched': False,
              'inputSettingsChanged': False, 'sources': {}, 'outputs': {}}

    def save():
        (root / 'build.json').write_text(json.dumps(record, indent=2) + '\n')

    def run(arguments):
        with (root / 'build.log').open('a') as stream:
            process = subprocess.Popen(arguments, stdout=stream, stderr=subprocess.STDOUT)
            code = process.wait()
        record['steps'].append({'arguments': arguments, 'pid': process.pid,
                                'exitCode': code, 'reaped': True})
        save()
        if code:
            raise RuntimeError(f'{arguments[0]} exited with {code}; see build.log')

    def bundle(name, executable, identifier):
        app = root / (name + '.app')
        directory = app / 'Contents' / 'MacOS'
        directory.mkdir(parents=True)
        shutil.copy2(executable, directory / executable.name)
        info = {'CFBundleExecutable': executable.name, 'CFBundleIdentifier': identifier,
                'CFBundleName': name, 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1', 'NSHighResolutionCapable': True}
        (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
        run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        return directory / executable.name

    try:
        for name in ('KoreanIMEFocusProbe.swift', 'IMEFocusBridge.swift', 'korean_ime_focus.py'):
            copied = root / name
            shutil.copy2(source / name, copied)
            record['sources'][name] = sha(copied)
        for name, binary in [('KoreanIMEFocusProbe.swift', 'ime-probe'),
                             ('IMEFocusBridge.swift', 'focus-bridge')]:
            run(['xcrun', 'swiftc', '-O', str(root / name), '-framework', 'AppKit',
                 '-framework', 'Carbon', '-o', str(root / binary)])
        reference = bundle('IME Reference', root / 'ime-probe', 'com.cmdy.bench.ime-focus.reference')
        bridge = bundle('IME Focus Bridge', root / 'focus-bridge', 'com.cmdy.bench.ime-focus.bridge')
        record['arguments'] = {'helper': str(root / 'ime-probe'),
                               'reference-executable': str(reference), 'focus-bridge': str(bridge)}
        record['outputs'] = {str(p.relative_to(root)): sha(p) for p in root.rglob('*')
                             if p.is_file() and p.name not in ('build.json', 'build.log')}
        record['status'] = 'pass'
    except BaseException as error:
        record.update(status='failed', error=repr(error))
        raise
    finally:
        save()
    print(json.dumps({'status': record['status'], 'arguments': record['arguments']}, indent=2))


if __name__ == '__main__':
    main()
