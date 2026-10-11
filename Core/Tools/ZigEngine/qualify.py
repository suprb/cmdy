#!/usr/bin/env python3
"""Freeze and qualify the complete Swift facade against the original Core suite."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
from apple_toolchain import apple_toolchain, zig_platform_flags, platform_link_flags

CORE = Path(__file__).resolve().parents[2]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--native-optimize", choices=["Debug", "ReleaseSafe", "ReleaseFast"], default="ReleaseSafe")
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--filter")
    parser.add_argument("--corpus-dir", type=Path,
                        help="copy the eight retained 3 MB correctness corpora into the frozen workspace")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    frozen = output / "workspace" / "Core"
    frozen.mkdir(parents=True)
    for directory in ["Zig", "Platform", "Tools/ZigEngine", "Sources/CmdyCoreZig", "Sources/CmdyNative",
                      "Sources/CmdyCZig", "Sources/CmdyPTY", "Sources/CmdyPTYShim", "Tests"]:
        shutil.copytree(CORE / directory, frozen / directory,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "cmdy_engine_build.h"))
    if (CORE / "Plugins").exists():
        shutil.copytree(CORE / "Plugins", frozen / "Plugins")
    fixtures = CORE.parent / "Tests/Fixtures"
    if fixtures.exists():
        shutil.copytree(fixtures, frozen.parent / "Tests/Fixtures")
    shutil.copytree(CORE.parent / "Tests/corpus", frozen.parent / "Tests/corpus")
    environment = os.environ.copy()
    if not environment.get("CMDY_ZIG"):
        environment["CMDY_ZIG"] = subprocess.check_output(
            [str(CORE.parent / "scripts/bootstrap-zig.sh")], text=True).strip()
    # This runner qualifies behavior. Timing requires a separate, isolated run.
    environment["CMDY_CORE_BENCHMARK"] = "0"
    corpus_keys = ("CMDY_INTERIOR_EMOJI_CORPUS_DIR", "CMDY_CSI_PREFIX_CORPUS_DIR",
                   "CMDY_OWNED_OUTPUT_CORPUS_DIR")
    for key in corpus_keys:
        environment.pop(key, None)
    if args.corpus_dir:
        corpora = frozen.parent / "retained-corpora"
        corpora.mkdir()
        for name in ("unicode", "styled", "source", "lines", "continuous", "sgr-fallback", "diversity", "collisions"):
            source = args.corpus_dir / (name + ".bin")
            if source.stat().st_size != 3_000_000:
                raise SystemExit(f"Expected complete 3 MB corpus: {source}")
            shutil.copy2(source, corpora / source.name)
        environment.update({key: str(corpora) for key in corpus_keys})
    # Before production selection changes, use the identical package graph
    # with just the native target and facade paths selected in this snapshot.
    manifest = (CORE / "Package.swift").read_text()
    if 'name: "CmdyNative"' not in manifest:
        manifest = manifest.replace("import PackageDescription", "import PackageDescription\nimport Foundation")
        manifest = manifest.replace('name: "CmdyCore",\n            path: "Sources/CmdyCore"',
            'name: "CmdyCore",\n            dependencies: ["CmdyNative"],\n            path: "Sources/CmdyCoreZig",\n            plugins: [.plugin(name: "VerifyNativeEngine")]')
        manifest = manifest.replace('dependencies: ["CmdyCore"],\n            path: "Sources/CmdyC"',
            'dependencies: ["CmdyNative"],\n            path: "Sources/CmdyCZig"')
        archive = str(frozen / ".zig-build/libcmdy_engine.a")
        manifest = manifest.replace('targets: [\n        .target(',
            'targets: [\n        .plugin(name: "VerifyNativeEngine", capability: .buildTool()),\n        .target(name: "CmdyNative", path: "Sources/CmdyNative", '
            'publicHeadersPath: "include", linkerSettings: [.unsafeFlags([' + json.dumps(archive) + '])]),\n        .target(', 1)
    (frozen / "Package.swift").write_text(manifest)
    inputs = {str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted((output / "workspace").rglob("*")) if path.is_file()}
    receipt = {"configuration": args.configuration, "native_optimize": args.native_optimize,
               "environment_overrides": {"CMDY_CORE_BENCHMARK": "0", **{key: environment.get(key) for key in corpus_keys}},
               "source_hashes": inputs, "processes": [], "status": "building", "compile_only": args.compile_only}

    def run(argv: list[str], label: str) -> None:
        with (output / (label + ".log")).open("wb") as log:
            process = subprocess.Popen(argv, cwd=frozen, env=environment, stdout=log, stderr=subprocess.STDOUT)
            code = process.wait()
        receipt["processes"].append({"argv": argv, "pid": process.pid, "exit_code": code, "reaped": True})
        receipt["status"] = "failed" if code else "running"
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if code:
            raise SystemExit(f"{label} failed; see {output / (label + '.log')}")

    run([sys.executable, str(frozen / "Tools/ZigEngine/build.py"), "--optimize", args.native_optimize], "native-build")
    if not args.compile_only and not args.filter:
        zig = shutil.which(environment.get("CMDY_ZIG", "zig"))
        if not zig:
            raise SystemExit("Pinned Zig executable disappeared after building")
        arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
        native_receipt = json.loads((frozen / ".zig-build/manifest.json").read_text())
        native_artifact = frozen / ".zig-build/artifacts" / native_receipt["source_key"]
        object_arch = "arm64" if arch == "aarch64" else arch
        objects = [str(native_artifact / path) for path in native_receipt["platform_objects"][object_arch]]
        for mode in ("Debug", "ReleaseSafe"):
            run([zig, "test", str(frozen / "Zig/tests.zig"), *objects, "-lc", "-O" + mode,
                 *zig_platform_flags(apple_toolchain(), frozen / "Sources/CmdyNative/include", frozen / "Platform"),
                 *platform_link_flags(),
                 "-target", arch + "-macos.26.0.0",
                 "--cache-dir", str(frozen / ".zig-build/test-cache"),
                 "--global-cache-dir", str(frozen / ".zig-build/global-cache")], "native-tests-" + mode)
        c_probe = output / "terminal-c-abi-test"
        run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=26.0",
             "-I", str(frozen / "Sources/CmdyNative/include"),
             str(frozen / "Tools/ZigEngine/terminal-c-abi-test.c"),
             str(frozen / ".zig-build/libcmdy_engine.a"), *platform_link_flags(), "-o", str(c_probe)], "c-abi-build")
        run([str(c_probe)], "c-abi-tests")
    command = ["swift", "build" if args.compile_only else "test", "--manifest-cache", "none", "--disable-build-manifest-caching", "-c", args.configuration,
               "--jobs", "4", "-Xswiftc", "-enable-testing"]
    if args.compile_only:
        command.append("--build-tests")
    if args.filter and not args.compile_only:
        command += ["--filter", args.filter]
    run(command, "swift-compile" if args.compile_only else "swift-tests")
    changed = [name for name, digest in inputs.items()
               if hashlib.sha256((output / name).read_bytes()).hexdigest() != digest]
    receipt.update(status="source_changed" if changed else "pass", changed_sources=changed)
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if changed:
        raise SystemExit("Frozen qualification sources changed; see receipt")
    print(f"Complete Core {'compile' if args.compile_only else 'tests'} passed: {output}")


if __name__ == "__main__":
    main()
