#!/usr/bin/env python3
"""Build a source-bound probe of the qualified native engine, without a GUI."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WORKLOADS = ("unicode", "styled", "source", "lines", "continuous",
             "sgr-fallback", "diversity", "collisions")
IGNORED = {".build", ".zig-build", ".swiftpm", ".zig-cache", "zig-out", "__pycache__", ".DS_Store"}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def source_files(core: Path) -> dict[str, str]:
    return {str(path.relative_to(core)): sha(path)
            for path in sorted(core.rglob("*"))
            if path.is_file() and not any(part in IGNORED for part in path.relative_to(core).parts)}


def checked(command: list[str], log: Path, cwd: Path) -> None:
    with log.open("xb") as output:
        subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, check=True)


def prepare(args: argparse.Namespace) -> None:
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    receipt = {"schemaVersion": 1, "status": "running", "diagnosticOnly": True,
               "qualifying": False, "metric": "headless-native-engine-profile",
               "limitations": ["No GUI, font shaping, Metal drawing, or Ghostty comparison",
                               "Profiler overhead and background load prohibit latency admission",
                               "Probe snapshot cadence is not the normal app SnapshotPublicationScheduler"]}
    try:
        core = args.core.resolve()
        qualification = args.qualification.resolve()
        q = json.loads(qualification.read_text())
        if q.get("status") != "library_and_normal_macos_app_integration_pass":
            raise ValueError("require the completed library qualification")
        manifest_path = qualification.parent / "schedule-active-source-manifest-final-01.json"
        expected_manifest = q["evidence"][manifest_path.name]["sha256"]
        if sha(manifest_path) != expected_manifest:
            raise ValueError("qualified source manifest changed")
        qualified = json.loads(manifest_path.read_text())
        before = source_files(core)
        bound_sources = [item for item in qualified["sources"] + qualified["trustFiles"]
                         if item["path"].startswith("Core/")]
        if not bound_sources:
            raise ValueError("qualification has no Core inputs")
        for item in bound_sources:
            if before.get(item["path"][5:]) != item["sha256"]:
                raise ValueError("Core differs from completed qualification: " + item["path"])
        checked([sys.executable, str(core / "Tools/ZigEngine/verify.py"), "--core", str(core)],
                output / "native-source-verification.log", REPO)
        native = json.loads((core / ".zig-build/manifest.json").read_text())
        key = native["source_key"]
        if (key != q["native_source_key"] or native["archive_sha256"] != q["native_archive_sha256"]
                or native["optimize"] != "ReleaseFast"):
            raise ValueError("selected native build is not the qualified release archive")
        frozen = output / "Core"
        shutil.copytree(core, frozen, ignore=shutil.ignore_patterns(*IGNORED))
        artifact = frozen / ".zig-build/artifacts" / key
        artifact.mkdir(parents=True)
        for name in ("libcmdy_engine.a", "receipt.json"):
            shutil.copy2(core / ".zig-build/artifacts" / key / name, artifact / name)
        shutil.copy2(core / ".zig-build/manifest.json", frozen / ".zig-build/manifest.json")
        (frozen / ".zig-build/libcmdy_engine.a").symlink_to(Path("artifacts") / key / "libcmdy_engine.a")
        for name in ("PTYEngineProbe.swift", "engine_worker.py", "profile_engine.py", "prepare_engine_probe.py"):
            shutil.copy2(HERE / name, output / name)
        payloads = {}
        for workload in WORKLOADS:
            name = workload + ".bin"
            source = args.corpus.resolve() / name
            if source.stat().st_size != 3_000_000:
                raise ValueError("require the complete 3 MB corpus: " + name)
            shutil.copy2(source, output / name)
            payloads[name] = sha(output / name)
            if payloads[name] != sha(source):
                raise ValueError("corpus changed during copy: " + name)
        probe = output / "probe"
        (probe / "Sources/PTYEngineProbe").mkdir(parents=True)
        shutil.copy2(output / "PTYEngineProbe.swift", probe / "Sources/PTYEngineProbe/main.swift")
        (probe / "Package.swift").write_text('''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "PTYEngineProbe", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../Core")],
    targets: [.executableTarget(name: "PTYEngineProbe", dependencies: [
        .product(name: "CmdyCore", package: "Core"),
        .product(name: "CmdyPTY", package: "Core")])])
''')
        command = ["/usr/bin/xcrun", "swift", "build", "--manifest-cache", "none",
                   "--disable-build-manifest-caching", "-c", "release", "--jobs", str(args.jobs)]
        receipt.update(qualificationSHA256=sha(qualification), qualifiedCoreInputs=len(bound_sources),
                       qualifiedSourceManifestSHA256=sha(manifest_path), nativeSourceKey=key,
                       nativeArchiveSHA256=native["archive_sha256"], buildCommand=command)
        write(output / "probe-build.json", receipt)
        checked(command, output / "swift-build.log", probe)
        binary = probe / ".build/release/PTYEngineProbe"
        checked(["/usr/bin/nm", "-g", str(binary)], output / "native-symbols.txt", probe)
        symbols = (output / "native-symbols.txt").read_text()
        if "_cmdy_zig_terminal_feed" not in symbols:
            raise ValueError("probe does not link the native terminal")
        if source_files(core) != before or source_files(frozen) != before:
            raise ValueError("Core changed during probe preparation")
        checked([sys.executable, str(frozen / "Tools/ZigEngine/verify.py"), "--core", str(frozen)],
                output / "frozen-native-verification.log", output)
        inputs = {str(Path("Core") / name): digest for name, digest in before.items()}
        inputs.update(payloads)
        for name in ("PTYEngineProbe.swift", "engine_worker.py", "profile_engine.py", "prepare_engine_probe.py",
                     "probe/Package.swift", "probe/Sources/PTYEngineProbe/main.swift", "Core/.zig-build/manifest.json",
                     f"Core/.zig-build/artifacts/{key}/receipt.json", f"Core/.zig-build/artifacts/{key}/libcmdy_engine.a"):
            inputs[name] = sha(output / name)
        receipt.update(status="complete", binaryPath=str(binary), binarySHA256=sha(binary),
                       inputs=inputs, workloads=list(WORKLOADS), snapshotCadenceMilliseconds=1,
                       snapshotModes=["on", "off"], snapshotDefault="on", modelsNativeAppSnapshotScheduler=False,
                       grid={"columns": 120, "rows": 36, "scrollback": 10000})
    except BaseException as error:
        receipt.update(status="failed_with_evidence_preserved", error=repr(error))
        raise
    finally:
        write(output / "probe-build.json", receipt)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--core", type=Path, default=REPO / "Core")
    parser.add_argument("--qualification", type=Path,
                        default=REPO / "docs/performance/results/2026-09-11-zig-renderer-port/qualification.json")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("jobs must be 1 through 8")
    prepare(args)


if __name__ == "__main__":
    main()
