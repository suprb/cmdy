#!/usr/bin/env python3
"""Exercise native delivery modes, real Metal pixels, ownership and callback counts."""
from pathlib import Path
import argparse, hashlib, json, shutil, subprocess, sys, time

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--legacy-native', type=Path)
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
        '-c',str(platform),'-o',str(instrument)])
    archives = {'candidate':archive}
    if args.legacy_native:
        legacy = args.legacy_native.resolve()
        receipt = json.loads((legacy.parent / 'receipt.json').read_text())
        assert digest(legacy) == receipt['archive_sha256']
        assert digest(platform) == receipt['sources']['Platform/platform_gpu.m']
        archives['baseline'] = legacy
    results = {}
    for label, native in archives.items():
        copied = output / (label + '.a'); shutil.copy2(native,copied)
        run(label + '-remove',['xcrun','ar','-d',str(copied),'platform_gpu.m.o'])
        run(label + '-insert',['xcrun','ar','-r',str(copied),str(instrument)])
        binary = output / label
        options = ['-DCMDY_DELIVERY_BASELINE=1'] if label == 'baseline' else []
        run(label + '-compile',flags + options + ['Tests/RendererPort/EssentialUpdatesSession.m',str(copied),'-lz'] + frameworks + ['-o',str(binary)])
        for mode in ([0] if label == 'baseline' else [0,1]):
            log = run(f'{label}-{mode}',[str(binary),str(mode)])
            counts = [json.loads(line.removeprefix('DELIVERY_COUNTS ')) for line in log.splitlines() if line.startswith('DELIVERY_COUNTS ')]
            assert len(counts) == 1 and counts[0]['frames'] == counts[0]['completions'] == 16
            results[f'{label}-{mode}'] = dict(counts=counts[0],passedGroups=sum(line.endswith('PASS') for line in log.splitlines()))
    full, essential = (results[key]['counts'] for key in ('candidate-0','candidate-1'))
    assert essential['stateOnly'] == 16 < full['stateOnly']
    assert essential['updates'] < full['updates'] and essential['actions'] < full['actions']
    if args.legacy_native: assert results['baseline-0']['counts'] == full
    # Exercise the existing timer/service/saturation/recovery contracts with
    # the same factory option the normal app uses, without weakening assertions.
    wrapper = output / 'essential-animation.m'
    wrapper.write_text('#include "cmdy_render_session.h"\n'
        '#define cmdy_render_session_create(d,f,s,u,n,b,c,x) '
        'cmdy_render_session_create_with_options(d,f,s,u,n,CMDY_SESSION_ESSENTIAL_UPDATES,b,c,x)\n'
        '#include "AnimationSession.m"\n')
    timed = output / 'essential-animation'
    run('essential-animation-compile',flags + ['-ITests/RendererPort',str(wrapper),str(output/'candidate.a'),'-lz'] + frameworks + ['-o',str(timed)])
    log = run('essential-animation',[str(timed)])
    results['essential-animation'] = dict(passedGroups=sum(line.endswith('PASS') for line in log.splitlines()))
    assert results['essential-animation']['passedGroups'] == 40
    result = dict(status='passed',results=results,nativeSourceKey=manifest['source_key'],nativeArchiveSHA256=digest(archive),
        performanceAdmission=False,countsAreAppLatencyOrMemoryProof=False,createdUnixNS=time.time_ns(),
        sources={str(p.relative_to(root)):digest(p) for p in [Path(__file__).resolve(),root/'Tests/RendererPort/EssentialUpdatesSession.m',
            root/'Tests/RendererPort/ModelPublishedSession.m',root/'Tests/RendererPort/AnimationSession.m',platform]},
        executionSHA256=digest(output/'execution.json'))
    (output/'result.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps(result))
    return 0

if __name__ == '__main__': raise SystemExit(main())
