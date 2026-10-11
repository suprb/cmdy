#!/usr/bin/env python3
"""Headless cursor cache pixels, cancellation, capacity and injected failures.

Requires a built native directory (--native, default Core/.zig-build). This does
not launch CMDY or establish app performance, visual transitions, or qualification.
"""
from pathlib import Path
import argparse
import hashlib
import itertools
import json
import os
import shutil
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--native', type=Path, default=Path('Core/.zig-build'))
    parser.add_argument('--baseline-pixels', type=Path)
    parser.add_argument('--with-backing', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest_path = args.native.resolve() / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    archive = manifest_path.parent / 'artifacts' / manifest['source_key'] / 'libcmdy_engine.a'
    assert manifest['status'] == 'pass' and digest(archive) == manifest['archive_sha256']
    frozen = {str(repo / 'Core' / name): value for name, value in manifest['sources'].items()}
    fixtures = [repo / 'Tests/RendererPort' / ('CursorCache' + name + '.m')
                for name in ('Frames', 'Viewport', 'Ownership', 'Faults')]
    for path in [*fixtures, Path(__file__), archive, repo / 'Tests/RendererPort/GPUWorkerOwnership.m']:
        frozen[str(path)] = digest(path)
    for name, value in frozen.items():
        assert digest(Path(name)) == value, name
    shutil.copy2(manifest_path, output / 'native-manifest.json')
    records = []
    summary = dict(status='failed', controllerPID=os.getpid(), performanceAdmission=False,
                   productIntegration=False, nativeArchiveSHA256=digest(archive))

    def run(label, command):
        rec = dict(label=label, arguments=command, startedUnixNS=time.time_ns())
        records.append(rec)
        with (output / (label + '.stdout')).open('xb') as out, (output / (label + '.stderr')).open('xb') as err:
            process = subprocess.Popen(command, cwd=repo, stdout=out, stderr=err)
            rec['pid'] = process.pid
            (output / 'processes.json').write_text(json.dumps(records, indent=2) + '\n')
            rec.update(exitCode=process.wait(), reaped=True, finishedUnixNS=time.time_ns())
        (output / 'processes.json').write_text(json.dumps(records, indent=2) + '\n')
        if rec['exitCode']:
            raise RuntimeError(label + ': ' + (output / (label + '.stderr')).read_text()[-4000:])
        print(label + ': PASS', flush=True)
        return (output / (label + '.stdout')).read_text()

    try:
        sdk = run('sdk', ['xcrun', '--show-sdk-path']).strip()
        flags = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                 '-std=c11', '-O2', '-mmacosx-version-min=26.0', '-isysroot', sdk,
                 '-ICore/Sources/CmdyNative/include', '-ICore/Platform', '-ITests/RendererPort']
        if args.with_backing:
            flags += ['-Dcmdy_render_cursor_cache_begin=cmdy_render_cursor_cache_begin_with_backing']
        frameworks = [arg for name in ('AppKit', 'Foundation', 'CoreFoundation', 'CoreGraphics',
                                       'CoreText', 'ImageIO', 'Metal', 'MetalKit', 'QuartzCore')
                      for arg in ('-framework', name)]
        instrument = output / 'platform_gpu.instrumented.o'
        run('compile-instrument', flags + ['-Dcmdy_gpu_apple_commit_checked=original_commit_checked',
            '-Dcmdy_gpu_apple_texture_read_bgra=original_texture_read_bgra', '-c',
            str(repo / 'Core/Platform/platform_gpu.m'), '-o', str(instrument)])
        private = output / 'faults.a'
        shutil.copy2(archive, private)
        run('remove-platform', ['xcrun', 'ar', '-d', str(private), 'platform_gpu.m.o'])
        run('insert-platform', ['xcrun', 'ar', '-r', str(private), str(instrument)])
        frozen[str(private)] = digest(private)
        cases = {}
        exact = 0
        maximum_cache_bytes = 0
        for fixture in fixtures:
            label = fixture.stem.removeprefix('CursorCache').lower()
            executable = output / label
            run(label + '-compile', flags + [str(fixture), str(private if label == 'faults' else archive),
                '-lz'] + frameworks + ['-o', str(executable)])
            frozen[str(executable)] = digest(executable)
            pixels = output / (label + '-pixels')
            pixels.mkdir()
            cases[label] = [json.loads(line) for line in run(label, [str(executable), str(pixels)]).splitlines()]
            if label not in ('frames', 'viewport'):
                continue
            expected = set(itertools.product([1, 2], [0, 1], range(4), [0, 2, 4], [0, 2, 3]))
            actual = set()
            assert len(cases[label]) == 144
            for scene in cases[label]:
                actual.add(tuple(scene[key] for key in ('scale', 'pattern' if label == 'frames' else 'geometry',
                                                       'lineMode', 'cursorStyle', 'cursorColumn')))
                name = scene['scene']
                w, h, tw, th, x, y = [scene[key] for key in ('width', 'height', 'tileWidth', 'tileHeight', 'cropX', 'cropY')]
                assert scene['workerDestroyed'] and scene['maxChannelDifference'] == scene['differentPairs'] == 0
                full, crop, tile = [(pixels / (name + '-' + suffix + '.bgra')).read_bytes()
                                    for suffix in ('full', 'crop', 'tile')]
                frame_bytes, patch_bytes = w * h * 4, tw * th * 4
                assert len(full) == 60 * frame_bytes and len(crop) == len(tile) == 60 * patch_bytes
                assert crop == tile and all(value == 255 for value in full[3::4])
                backing = (pixels / (name + '-backing.bgra')).read_bytes()
                assert backing == (full[:frame_bytes] if args.with_backing else b'')
                base = full[:frame_bytes]
                phases = set()
                for phase in range(60):
                    frame = full[phase * frame_bytes:(phase + 1) * frame_bytes]
                    patch = tile[phase * patch_bytes:(phase + 1) * patch_bytes]
                    assert patch == b''.join(frame[((y + row) * w + x) * 4:((y + row) * w + x + tw) * 4] for row in range(th))
                    outside = bytearray(frame)
                    for row in range(th):
                        start = ((y + row) * w + x) * 4
                        outside[start:start + tw * 4] = base[start:start + tw * 4]
                    assert outside == base
                    phases.add(patch)
                assert len(phases) >= 20
                if label == 'frames' and args.baseline_pixels:
                    for suffix, data in [('full', full), ('crop', crop), ('tile', tile)]:
                        assert data == (args.baseline_pixels / (name + '-' + suffix + '.bgra')).read_bytes()
                maximum_cache_bytes = max(maximum_cache_bytes, len(tile))
                exact += 60
            assert actual == expected
        assert len(cases['ownership']) == 9 and len(cases['faults']) == 5
        assert {case['fault'] for case in cases['faults']} == set(range(5))
        for case in cases['faults']:
            assert case['workerDestroyed'] and case['callbacks'] == case['disposals'] == 1
            assert case['result'] == (2 if case['fault'] < 2 else 1)
            assert case['completedReadbacks'] == (9 if case['fault'] == 0 else 10)
        for name, value in frozen.items():
            assert digest(Path(name)) == value, name
        for rec in records:
            try:
                os.kill(rec['pid'], 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(('owned process still present', rec['pid']))
        summary.update(status='pass-headless-cursor-cache', exactPhasePairs=exact, maximumChannelDifference=0,
                       baselinePhasePairs=8640 if args.baseline_pixels else 0,
                       maximumRawCacheBytes=maximum_cache_bytes, exactBackingFrames=288 if args.with_backing else 0, cases=cases,
                       frozenInputsVerified=len(frozen), allChildrenReapedAndAbsent=True,
                       injectedArchiveSHA256=digest(private))
    except BaseException as error:
        summary['error'] = repr(error)
        raise
    finally:
        (output / 'frozen-inputs.json').write_text(json.dumps(frozen, indent=2) + '\n')
        (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'PASS: {exact} exact phases, 9 ownership/rejection cases, 5 injected failure/cancellation cases; no performance admission')


if __name__ == '__main__':
    main()
