#!/usr/bin/env python3
"""Exercise host-work delivery, real GPU completion, pixels, observation and recovery."""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, sys, time

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    executions = []
    def run(label, command):
        log = output / (label + '.log')
        record = dict(label=label, command=command, startedUnixNS=time.time_ns())
        executions.append(record)
        try:
            with log.open('xb') as stream:
                child = subprocess.Popen(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT)
                record['pid'] = child.pid
                try: child.wait(timeout=120)
                finally:
                    if child.poll() is None: child.kill(); child.wait()
                    record.update(exitCode=child.returncode, reaped=True, finishedUnixNS=time.time_ns())
            record['logSHA256'] = digest(log)
            if child.returncode: raise RuntimeError(f'{label}: {log.read_text()[-4000:]}')
            return log.read_text()
        finally:
            (output / 'execution.json').write_text(json.dumps(executions, indent=2) + '\n')
    run('verify-native', [sys.executable, '-B', 'Core/Tools/ZigEngine/verify.py', '--core', 'Core'])
    manifest = json.loads((root / 'Core/.zig-build/manifest.json').read_text())
    archive = root / 'Core/.zig-build/artifacts' / manifest['source_key'] / 'libcmdy_engine.a'
    sdk = subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
    flags = ['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-std=c11','-O2',
             '-mmacosx-version-min=26.0','-isysroot',sdk,'-ICore/Sources/CmdyNative/include','-ICore/Platform']
    frameworks = [arg for name in ('AppKit','Foundation','CoreFoundation','CoreGraphics','CoreText','ImageIO','Metal','MetalKit','QuartzCore') for arg in ('-framework',name)]
    platform = root / 'Core/Platform/platform_gpu.m'
    instrument = output / 'platform_gpu.instrumented.o'
    run('platform-compile',flags + ['-Dcmdy_gpu_apple_commit=fixture_commit_impl',
        '-Dcmdy_gpu_apple_presented=fixture_presented_impl','-Dcmdy_gpu_apple_encoder_end=fixture_encoder_end_impl',
        '-Dcmdy_gpu_apple_encoder=fixture_encoder_impl',
        '-c',str(platform),'-o',str(instrument)])
    copied = output / 'candidate.a'; shutil.copy2(archive,copied)
    run('candidate-remove',['xcrun','ar','-d',str(copied),'platform_gpu.m.o'])
    run('candidate-insert',['xcrun','ar','-r',str(copied),str(instrument)])
    binary = output / 'host-work'
    run('candidate-compile',flags + ['Tests/RendererPort/HostWorkUpdatesSession.m',str(copied),'-lz'] + frameworks + ['-o',str(binary)])
    results = {}
    for mode in [1,2,3]:
        log = run(f'candidate-{mode}',[str(binary),str(mode)])
        counts = [json.loads(line.removeprefix('HOST_WORK_COUNTS ')) for line in log.splitlines() if line.startswith('HOST_WORK_COUNTS ')]
        assert len(counts) == 1 and counts[0]['gpuFrames'] == counts[0]['exactPixels'] == 16
        assert counts[0]['frames'] == counts[0]['stateOnly'] == (16 if mode == 1 else 0)
        assert counts[0]['stopOnlyActions'] == (80 if mode == 1 else 0)
        assert counts[0]['actions'] == (96 if mode == 1 else 0)
        results[f'candidate-{mode}'] = dict(counts=counts[0],passedGroups=sum(line.endswith('PASS') for line in log.splitlines()))
    assert results['candidate-2']['counts']['actions'] < results['candidate-1']['counts']['actions']
    # The existing timer/service/saturation/recovery fixture needs per-frame
    # observation; explicitly request it in the same new delivery mode.
    wrapper = output / 'host-work-animation.m'
    wrapper.write_text('#include "ObservedSessionFactory.h"\n'
        'void *fixture_encoder_impl(const void *,const void *);\n'
        'void *cmdy_gpu_apple_encoder(const void *b,const void *p){return fixture_encoder_impl(b,p); }\n'
        '#define cmdy_render_session_create(d,f,s,u,n,b,c,x) create_observed_session(d,f,s,u,n,CMDY_SESSION_HOST_WORK_UPDATES,b,c,x)\n'
        '#include "AnimationSession.m"\n')
    timed = output / 'host-work-animation'
    run('host-work-animation-compile',flags + ['-ITests/RendererPort',str(wrapper),str(copied),'-lz'] + frameworks + ['-o',str(timed)])
    log = run('host-work-animation',[str(timed)])
    results['host-work-animation'] = dict(passedGroups=sum(line.endswith('PASS') for line in log.splitlines()))
    assert results['host-work-animation']['passedGroups'] == 40
    result = dict(status='passed',results=results,nativeSourceKey=manifest['source_key'],nativeArchiveSHA256=digest(archive),
        performanceAdmission=False,countsAreAppLatencyOrMemoryProof=False,createdUnixNS=time.time_ns(),
        sources={str(p.relative_to(root)):digest(p) for p in [Path(__file__).resolve(),root/'Tests/RendererPort/HostWorkUpdatesSession.m',root/'Tests/RendererPort/ObservedSessionFactory.h',
            root/'Tests/RendererPort/ModelPublishedSession.m',root/'Tests/RendererPort/AnimationSession.m',platform]},
        executionSHA256=digest(output/'execution.json'))
    (output/'result.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps(result))
    return 0

if __name__ == '__main__': raise SystemExit(main())
