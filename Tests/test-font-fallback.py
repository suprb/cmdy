#!/usr/bin/env python3
"""Compare eager and deferred font loading with exact headless native rasters.

Runs fresh processes for each primary font and loading mode. Does not create
windows, send input, measure app memory, or admit performance results.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    parser.add_argument("--legacy-native", type=Path, help="Optional frozen pre-change native archive")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    records: list[dict] = []

    def run(label: str, command: list[str]) -> Path:
        stdout, stderr = output / (label + ".stdout"), output / (label + ".stderr")
        record = dict(label=label, command=command, startedUnixNS=time.time_ns())
        records.append(record)
        try:
            with stdout.open("xb") as out, stderr.open("xb") as err:
                child = subprocess.Popen(command, cwd=root, stdout=out, stderr=err)
                record["pid"] = child.pid
                try:
                    record["exitCode"] = child.wait(timeout=90)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                    record.update(reaped=True, finishedUnixNS=time.time_ns())
            record.update(stdoutSha256=digest(stdout), stderrSha256=digest(stderr))
            if record["exitCode"]:
                raise RuntimeError(f"{label} failed: {stderr.read_text()[-4000:]}")
            return stdout
        finally:
            (output / "execution.json").write_text(json.dumps(records, indent=2) + "\n")

    run("verify-native", [sys.executable, "Core/Tools/ZigEngine/verify.py", "--core", "Core"])
    manifest = json.loads((root / "Core/.zig-build/manifest.json").read_text())
    native = root / "Core/.zig-build/artifacts" / manifest["source_key"] / "libcmdy_engine.a"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    fixture = root / "Tests/RendererPort/FontFallback.m"
    fonts = root / "Kit/Sources/CmdyKit/Fonts"
    frameworks = [arg for name in ("AppKit", "Foundation", "CoreFoundation", "CoreGraphics",
                                  "CoreText", "ImageIO", "Metal", "MetalKit", "QuartzCore")
                  for arg in ("-framework", name)]
    compile_args = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                    "-std=c11", "-O2", "-mmacosx-version-min=26.0", "-isysroot", sdk,
                    "-ICore/Sources/CmdyNative/include", str(fixture)]
    candidate = output / "candidate"
    run("compile-candidate", compile_args + [str(native), "-lz"] + frameworks + ["-o", str(candidate)])
    baseline = candidate
    if args.legacy_native:
        baseline = output / "baseline"
        run("compile-baseline", compile_args + ["-DCMDY_LEGACY_FONTS", str(args.legacy_native.resolve()), "-lz"]
            + frameworks + ["-o", str(baseline)])
    pairs = 0
    worker_renders = 0
    for index, name in enumerate(("Menlo-Regular", "FragmentMono-Regular", "GeistMono-Regular",
                                  "Iosevka-Term", "JetBrainsMono-Regular")):
        reference_path = run(f"{index}-baseline", [str(baseline), "eager", str(fonts), name])
        reference = json.loads(reference_path.read_text())["cases"]
        assert len(reference) == 17
        for mode in ("eager", "deferred", "concurrent", "retry"):
            result = json.loads(run(f"{index}-{mode}", [str(candidate), mode, str(fonts), name]).read_text())
            assert len(result["cases"]) == len(reference)
            for expected, actual in zip(reference, result["cases"], strict=True):
                if actual != expected:
                    raise AssertionError(f"Raster mismatch: {name} {mode} {expected['text']!r}")
                pairs += 1
            worker_renders += result["workerRenders"]
    summary = dict(status="pass", exactRasterPairs=pairs, concurrentRenders=worker_renders,
                   processes=len(records), reaped=all(r["reaped"] for r in records),
                   fixtureSha256=digest(fixture), runnerSha256=digest(Path(__file__)),
                   nativeSourceKey=manifest["source_key"], nativeArchiveSha256=digest(native),
                   candidateSha256=digest(candidate), baselineSha256=digest(baseline),
                   legacyArchiveSha256=digest(args.legacy_native) if args.legacy_native else None,
                   fontResources={p.name: digest(p) for p in sorted(fonts.iterdir()) if p.is_file()},
                   performanceEvidence=False)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS: {pairs} exact raster pairs, {worker_renders} concurrent renders, all processes reaped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
