#!/usr/bin/env python3
"""Headless actual glyph-cache identity, pixels, eviction and allocator contracts."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    records = []
    def run(label, command):
        path = output / (label + '.log')
        record = dict(label=label, command=command, startedUnixNS=time.time_ns())
        records.append(record)
        try:
            with path.open('xb') as stream:
                child = subprocess.Popen(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT)
                record['pid'] = child.pid
                try: child.wait(timeout=180)
                finally:
                    if child.poll() is None: child.kill(); child.wait()
                    record.update(exitCode=child.returncode, reaped=True, finishedUnixNS=time.time_ns())
            record['logSHA256'] = digest(path)
            if child.returncode: raise RuntimeError(f'{label}: {path.read_text()[-5000:]}')
            return path.read_text()
        finally:
            (output / 'execution.json').write_text(json.dumps(records, indent=2) + '\n')
    run('verify-native', [sys.executable, '-B', 'Core/Tools/ZigEngine/verify.py', '--core', 'Core'])
    native = json.loads((root / 'Core/.zig-build/manifest.json').read_text())
    archive = root / 'Core/.zig-build/artifacts' / native['source_key'] / 'libcmdy_engine.a'
    assert digest(archive) == native['archive_sha256']
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    includes = ['-ICore/Sources/CmdyNative/include', '-ICore/Platform']
    clang = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
             '-std=c11', '-O2', '-mmacosx-version-min=26.0', '-isysroot', sdk] + includes
    instrument = output / 'platform_gpu.instrumented.o'
    names = ['font_name', 'hash', 'equal', 'retain', 'release']
    run('compile-platform', clang + [f'-Dcmdy_gpu_apple_{name}=glyph_original_{name}' for name in names] +
        ['-c', 'Core/Platform/platform_gpu.m', '-o', str(instrument)])
    bridge = output / 'glyph-bridge.o'
    run('compile-bridge', clang + ['-c', 'Tests/RendererPort/GlyphCacheBridge.m', '-o', str(bridge)])
    linked = output / 'instrumented.a'; shutil.copy2(archive, linked)
    # The test directly compiles the cache, shader, rasterizer and atlas. Keep
    # only the production platform objects from the verified native archive.
    run('remove-engine-and-platform', ['xcrun', 'ar', '-d', str(linked),
                                      'libcmdy_engine-arm64_zcu.o', 'platform_gpu.m.o'])
    run('insert-platform', ['xcrun', 'ar', '-r', str(linked), str(instrument)])
    zig = os.environ.get('CMDY_ZIG', '/opt/homebrew/Cellar/zig/0.15.2/bin/zig')
    frameworks = [arg for name in ['AppKit', 'Foundation', 'CoreFoundation', 'CoreGraphics',
                                  'CoreText', 'ImageIO', 'Metal', 'MetalKit', 'QuartzCore']
                  for arg in ['-framework', name]]
    counts = {}
    for mode in ['Debug', 'ReleaseSafe']:
        command = [zig, 'test', 'Core/Zig/render_cache_glyph_tests.zig', str(linked), str(bridge),
                   '-lc', '-lz', '-target', 'aarch64-macos.26.0.0', '--sysroot', sdk,
                   '-F' + sdk + '/System/Library/Frameworks', '-L/usr/lib', '-isystem', sdk + '/usr/include']
        log = run(mode, command + includes + frameworks + ['-O' + mode, '--cache-dir', str(output / ('cache-' + mode))])
        assert 'All 6 tests passed.' in log
        rows = [line[line.index('GLYPH_INDEX_HITS '):] for line in log.splitlines() if 'GLYPH_INDEX_HITS ' in line]
        assert len(rows) == 1
        counts[mode] = {key: int(value) for key, value in (item.split('=') for item in rows[0].split()[1:])}
        assert counts[mode]['lookups'] == 18800
        assert counts[mode]['fontNameCopies'] == counts[mode]['metadataAllocations'] == 0
    sources = ['Core/Zig/render_cache_glyph.zig', 'Core/Zig/render_cache_glyph_tests.zig',
               'Core/Platform/platform_gpu.h', 'Core/Platform/platform_gpu.m',
               'Tests/RendererPort/GlyphCacheBridge.m', 'Tests/test-glyph-cache-index.py']
    result = dict(status='pass', nativeSourceKey=native['source_key'], nativeArchiveSHA256=digest(archive),
                  testsPerMode=6, counts=counts, executionSHA256=digest(output / 'execution.json'),
                  sources={name: digest(root / name) for name in sources}, performanceAdmission=False,
                  countsAreAppLatencyOrMemoryProof=False, createdUnixNS=time.time_ns())
    (output / 'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result))

if __name__ == '__main__': main()
