#!/usr/bin/env python3
"""Check bounded GPU batches, exact pixels and vertex allocation failure recovery.

Runs only headless Metal fixtures. Optional --legacy-native compares a frozen
pre-change archive. Operation counts are diagnostic, not app performance results.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    parser.add_argument("--legacy-native", type=Path, help="Frozen native archive beside its receipt.json")
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
    frameworks = [arg for name in ("AppKit", "Foundation", "CoreFoundation", "CoreGraphics",
                                  "CoreText", "ImageIO", "Metal", "MetalKit", "QuartzCore")
                  for arg in ("-framework", name)]
    flags = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
             "-std=c11", "-O2", "-mmacosx-version-min=26.0", "-isysroot", sdk,
             "-ICore/Sources/CmdyNative/include", "-ICore/Platform"]
    fixture = root / "Tests/RendererPort/CoverageBatchFrames.m"
    viewport = root / "Tests/RendererPort/ViewportFrames.m"
    platform = root / "Core/Platform/platform_gpu.m"
    instrument = output / "platform_gpu.instrumented.o"
    renames = ("encoder_draw", "encoder_vertex_buffer", "buffer_write", "buffer")
    run("compile-platform", flags + ["-Dcmdy_gpu_apple_" + n + "=original_" + n.removeprefix("encoder_")
                                    for n in renames] + ["-c", str(platform), "-o", str(instrument)])
    archives = {"candidate": native}
    if args.legacy_native:
        legacy = args.legacy_native.resolve()
        receipt = json.loads((legacy.parent / "receipt.json").read_text())
        assert digest(legacy) == receipt["archive_sha256"]
        # Instrumentation must not replace different platform behavior in the baseline.
        assert digest(platform) == receipt["sources"]["Platform/platform_gpu.m"]
        archives["baseline"] = legacy

    images: dict[tuple[str, int], Path] = {}
    scene_results: dict[str, list[dict]] = {}
    executables: dict[str, Path] = {}
    for label, archive in archives.items():
        instrumented = output / (label + ".a")
        shutil.copy2(archive, instrumented)
        run(label + "-remove-platform", ["xcrun", "ar", "-d", str(instrumented), "platform_gpu.m.o"])
        run(label + "-insert-platform", ["xcrun", "ar", "-r", str(instrumented), str(instrument)])
        exe = output / label
        executables[label] = exe
        run(label + "-compile", flags + [str(fixture), str(instrumented), "-lz"] + frameworks + ["-o", str(exe)])
        for mode in (0, 1, 68):
            pixels = output / f"{label}-{mode}.bgra"
            log = run(f"{label}-{mode}", [str(exe), str(pixels), str(mode), "normal"])
            scenes = [json.loads(line) for line in log.read_text().splitlines()]
            assert len(scenes) == 48
            assert {(s["cols"], s["line_mode"], s["pattern"]) for s in scenes} == {
                (c, m, p) for c in (1, 63, 64, 65, 120, 257) for m in range(4) for p in range(2)}
            images[label, mode] = pixels
            scene_results[f"{label}-{mode}"] = scenes
        view_exe, view_pixels = output / (label + "-viewport"), output / (label + "-viewport.bgra")
        run(label + "-viewport-compile", flags + [str(viewport), str(archive), "-lz"] + frameworks + ["-o", str(view_exe)])
        run(label + "-viewport", [str(view_exe), str(view_pixels)])
        assert view_pixels.stat().st_size == 32 * 48 * 80 * 4
        images[label, -1] = view_pixels

    for scene in scene_results["candidate-0"]:
        if scene["line_mode"] == 0 and scene["cols"] == 120:
            assert scene["draws_total"] == scene["uploads_total"] == scene["vertex_binds_total"] == 8 * 4
    failure = output / "candidate-failure.bgra"
    run("candidate-failure", [str(executables["candidate"]), str(failure), "0", "fail-first-buffer"])
    assert failure.read_bytes() == images["candidate", 0].read_bytes()
    comparisons = 0
    if "baseline" in archives:
        for mode, count in ((0, 48), (1, 48), (68, 48), (-1, 32)):
            assert images["baseline", mode].read_bytes() == images["candidate", mode].read_bytes(), mode
            comparisons += count
        for a, b in zip(scene_results["baseline-0"], scene_results["candidate-0"], strict=True):
            assert b["draws_total"] <= a["draws_total"]
            assert b["buffer_requested_bytes"] <= a["buffer_requested_bytes"]

    summary = dict(status="pass", exactBeforeAfterScenes=comparisons, normalAndEffectScenes=144,
                   viewportScenes=32, allocationFailureScenes=48, preservedAllocationFailurePixels=True,
                   fixtureSHA256=digest(fixture), runnerSHA256=digest(Path(__file__)),
                   viewportFixtureSHA256=digest(viewport), platformSHA256=digest(platform),
                   nativeSourceKey=manifest["source_key"], nativeArchiveSHA256=digest(native),
                   baselineArchiveSHA256=digest(archives["baseline"]) if "baseline" in archives else None,
                   pixelFiles={p.name: digest(p) for p in [*images.values(), failure]},
                   operationCounts=scene_results, processes=len(records),
                   reaped=all(r["reaped"] for r in records), performanceEvidence=False)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PASS: {comparisons} exact before/after scenes, 48 allocation-failure scenes; all processes reaped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
