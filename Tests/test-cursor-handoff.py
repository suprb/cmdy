#!/usr/bin/env python3
"""Headless cursor/session handoff against a specified native archive.

Uses real Metal commands and the production session, with a private archive
that intercepts presentation receipts. No app, window, input, PTY, or clipboard
is created. Positive presentation receipts are injected, not on-screen proof.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--native', type=Path, default=Path('Core/.zig-build'))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    manifest_path = args.native.resolve() / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    native = manifest_path.parent / 'artifacts' / manifest['source_key'] / 'libcmdy_engine.a'
    assert manifest['status'] == 'pass' and digest(native) == manifest['archive_sha256']
    fixture = repo / 'Tests/RendererPort/CursorCacheSession.m'
    frozen = {str(repo / 'Core' / n): h for n, h in manifest['sources'].items()}
    for p in [fixture, Path(__file__), native, repo / 'Tests/RendererPort/GPUWorkerOwnership.m']:
        frozen[str(p)] = digest(p)
    for name in ['RendererSession', 'LayerSession', 'PublishedSession', 'ModelPublishedSession']:
        p = repo / 'Tests/RendererPort' / (name + '.m')
        frozen[str(p)] = digest(p)
    for n, h in frozen.items():
        assert digest(Path(n)) == h, n
    shutil.copy2(fixture, out / fixture.name)
    shutil.copy2(manifest_path, out / 'native-manifest.json')
    records = []
    result = dict(status='failed', controllerPID=os.getpid(), performanceAdmission=False,
                  onScreenPresentationProof=False, nativeArchiveSHA256=digest(native))

    def run(label, command):
        rec = dict(label=label, arguments=command, parentPID=os.getpid(), startedUnixNS=time.time_ns())
        records.append(rec)
        with (out / (label + '.stdout')).open('x') as stdout, (out / (label + '.stderr')).open('x') as stderr:
            child = subprocess.Popen(command, cwd=repo, stdout=stdout, stderr=stderr)
            rec['pid'] = child.pid
            (out / 'processes.json').write_text(json.dumps(records, indent=2) + '\n')
            rec.update(exitCode=child.wait(), reaped=True, finishedUnixNS=time.time_ns())
        (out / 'processes.json').write_text(json.dumps(records, indent=2) + '\n')
        print(label, rec['exitCode'], flush=True)
        if rec['exitCode']:
            raise RuntimeError((out / (label + '.stderr')).read_text()[-4000:])
        return (out / (label + '.stdout')).read_text()

    try:
        sdk = run('sdk', ['xcrun', '--show-sdk-path']).strip()
        flags = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                 '-std=c11', '-O2', '-mmacosx-version-min=26.0', '-isysroot', sdk,
                 '-ICore/Sources/CmdyNative/include', '-ICore/Platform', '-ITests/RendererPort']
        instrument = out / 'platform_gpu.instrumented.o'
        run('compile-platform', flags + [
            '-Dcmdy_gpu_apple_commit=fixture_commit_impl',
            '-Dcmdy_gpu_apple_presented=fixture_presented_impl',
            '-Dcmdy_gpu_apple_encoder_end=fixture_encoder_end_impl',
            '-c', str(repo / 'Core/Platform/platform_gpu.m'), '-o', str(instrument)])
        private = out / 'session.a'
        shutil.copy2(native, private)
        run('remove-platform', ['xcrun', 'ar', '-d', str(private), 'platform_gpu.m.o'])
        run('insert-platform', ['xcrun', 'ar', '-r', str(private), str(instrument)])
        frozen[str(private)] = digest(private)
        exe = out / 'fixture'
        frameworks = [arg for n in ['AppKit', 'Foundation', 'CoreFoundation', 'CoreGraphics',
                                   'CoreText', 'ImageIO', 'Metal', 'MetalKit', 'QuartzCore']
                      for arg in ['-framework', n]]
        run('compile', flags + [str(out / fixture.name), str(private), '-lz'] + frameworks + ['-o', str(exe)])
        frozen[str(exe)] = digest(exe)
        pixels = out / 'pixels'
        pixels.mkdir()
        scenes = [json.loads(line) for line in run('execute', [str(exe), str(pixels)]).splitlines()]
        assert len(scenes) == 6 and {s['scenario'] for s in scenes} == set(range(6))
        assert all(s['offers'] == 1 and s['sessionDestroyed'] and s['retainedBackingAfterJoin'] for s in scenes)
        for n, h in frozen.items():
            assert digest(Path(n)) == h, n
        for rec in records:
            try:
                os.kill(rec['pid'], 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(('owned PID remains', rec['pid']))
        result.update(status='pass-headless-cursor-handoff', executableSHA256=digest(exe),
                      frozenInputsVerified=len(frozen), allChildrenReapedAndAbsent=True, scenes=scenes)
    except BaseException as exc:
        result['error'] = repr(exc)
        raise
    finally:
        (out / 'frozen-inputs.json').write_text(json.dumps(frozen, indent=2) + '\n')
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'scenes'}, indent=2), flush=True)


if __name__ == '__main__':
    main()
