#!/usr/bin/env python3
"""Verify real render-thread QoS, stale-input fences and main-thread isolation."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    executions = []

    def run(label, command):
        log = output / (label + '.log')
        record = dict(label=label, command=command, startedUnixNS=time.time_ns())
        executions.append(record)
        try:
            with log.open('xb') as stream:
                child = subprocess.Popen(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT)
                record['pid'] = child.pid
                try:
                    child.wait(timeout=120)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                    record.update(exitCode=child.returncode, reaped=True, finishedUnixNS=time.time_ns())
            record['logSHA256'] = digest(log)
            if child.returncode:
                raise RuntimeError(f'{label} failed; see {log}')
            return log.read_text()
        finally:
            (output / 'execution.json').write_text(json.dumps(executions, indent=2) + '\n')

    run('verify-native', [sys.executable, '-B', 'Core/Tools/ZigEngine/verify.py', '--core', 'Core'])
    manifest = json.loads((root / 'Core/.zig-build/manifest.json').read_text())
    archive = root / 'Core/.zig-build/artifacts' / manifest['source_key'] / 'libcmdy_engine.a'
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    flags = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror', '-std=c11', '-O2',
             '-mmacosx-version-min=26.0', '-isysroot', sdk, '-ICore/Sources/CmdyNative/include', '-ICore/Platform']
    frameworks = [arg for name in ('AppKit', 'Foundation', 'CoreFoundation', 'CoreGraphics', 'CoreText',
                                  'ImageIO', 'Metal', 'MetalKit', 'QuartzCore') for arg in ('-framework', name)]
    platform = root / 'Core/Platform/platform_gpu.m'
    instrument = output / 'platform_gpu.instrumented.o'
    run('platform-compile', flags + ['-Dcmdy_gpu_apple_set_thread_qos=fixture_set_thread_qos_impl',
                                    '-c', str(platform), '-o', str(instrument)])
    copied = output / 'candidate.a'
    shutil.copyfile(archive, copied)
    run('candidate-remove', ['xcrun', 'ar', '-d', str(copied), 'platform_gpu.m.o'])
    run('candidate-insert', ['xcrun', 'ar', '-r', str(copied), str(instrument)])
    binary = output / 'worker-qos'
    run('candidate-compile', flags + ['Tests/RendererPort/RenderWorkerPriority.m', str(copied), '-lz']
        + frameworks + ['-o', str(binary)])
    log = run('candidate-run', [str(binary)])
    assert 'WORKER_QOS_PASS groups=8' in log
    assert sum(line.endswith('PASS') for line in log.splitlines()) == 8
    sources = ['Core/Zig/render_priority.zig', 'Core/Zig/render_session.zig', 'Core/Platform/platform_gpu.h',
               'Core/Platform/platform_gpu.m', 'Tests/RendererPort/RendererSession.m',
               'Tests/RendererPort/RenderWorkerPriority.m', 'Tests/test-render-worker-qos.py']
    result = dict(status='pass', groups=8, nativeSourceKey=manifest['source_key'],
                  nativeArchiveSHA256=digest(archive), nativeMode=manifest['optimize'],
                  sources={name:digest(root / name) for name in sources},
                  executionSHA256=digest(output / 'execution.json'), performanceAdmission=False,
                  nativeWindows=0, systemInputPosted=False, actualPthreadQoSVerified=True)
    (output / 'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
