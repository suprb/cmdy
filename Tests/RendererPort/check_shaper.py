#!/usr/bin/env python3
"""Qualify native App shaping against the frozen Swift source without app UI.

All fixture files and native build receipts are copied into a unique temporary
package before compilation. The executable uses the current Core and Renderer
products, but never imports the app entry point or its clipboard selftest.
"""
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
APP_FILES = (
    "CmdySnapshotShaper.swift", "CmdyPerformanceTrace.swift",
    "CmdyShaperPendingRunHarness.swift", "CmdyShaperProceduralColorHarness.swift",
    "CmdySnapshotRevisionHarness.swift", "CmdyCellImageHarness.swift",
)
NAMES = ("CmdyShapingStyle", "CmdySnapshotRowContext", "CmdySnapshotShaper", "CmdyCellImage")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_function(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    index = opening + 1
    while depth:
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    return source[start:index]


def prepare(output: Path, frozen: Path) -> dict:
    sources = output / "Sources/ShaperDifferential"
    sources.mkdir(parents=True)
    copied = {}
    for name in APP_FILES:
        source = REPO / "App" / name
        destination = sources / name
        shutil.copy2(source, destination)
        copied[str(source.relative_to(REPO))] = digest(source)
    fixture = REPO / "Tests/RendererPort/ShaperDifferential.swift"
    shutil.copy2(fixture, sources / fixture.name)
    copied[str(fixture.relative_to(REPO))] = digest(fixture)
    source = frozen / "App/CmdySnapshotShaper.swift"
    original = source.read_text()
    for name in NAMES:
        original = re.sub(r"\b" + name + r"\b", "Original" + name, original)
    (sources / "OriginalCmdySnapshotShaper.swift").write_text(original)
    # Keep the fixture's established ANSI palette without importing the view.
    surface = frozen / "App/CmdyTerminalSurface.swift"
    surface_text = surface.read_text()
    palette = extract_function(surface_text, "static func defaultPalette()")
    color = extract_function(surface_text, "private static func color(")
    (sources / "PaletteFixture.swift").write_text(
        "import AppKit\n@MainActor enum CmdyTerminalSurface {\n" + palette + "\n" + color + "\n}\n")
    package = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "NativeShaperQualification", platforms: [.macOS(.v26)],
    dependencies: [.package(path: REPO_CORE), .package(path: REPO_RENDERER)],
    targets: [.executableTarget(name: "ShaperDifferential", dependencies: [
        .product(name: "CmdyCore", package: "Core"),
        .product(name: "CmdyNative", package: "Core"),
        .product(name: "CmdyGPU", package: "Renderer")])], swiftLanguageModes: [.v5])
'''.replace("REPO_CORE", json.dumps(str(REPO / "Core"))).replace("REPO_RENDERER", json.dumps(str(REPO / "Renderer")))
    (output / "Package.swift").write_text(package)
    return {
        "input_sources": copied,
        "frozen_sources": {str(path.relative_to(frozen)): digest(path) for path in (source, surface)},
        "fixture_sources": {str(path.relative_to(output)): digest(path) for path in sources.iterdir()},
        "package_sha256": digest(output / "Package.swift"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frozen-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="Parent evidence folder; each attempt gets a fresh child")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="shaper-qa-", dir=args.output.resolve()))
    record = {
        "status": "preparing", "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "repository": str(REPO), "frozen_source": str(args.frozen_source.resolve()),
        "processes": [], "constraints": ["no app activation", "no windows", "no OS clipboard", "no performance benchmark"],
    }
    receipt = output / "qualification.json"

    def save() -> None:
        receipt.write_text(json.dumps(record, indent=2) + "\n")

    def run(argv: list[str], label: str) -> int:
        log = output / (label + ".log")
        env = os.environ.copy()
        env.pop("CMDY_FRAME_TRACE", None)
        with log.open("wb") as stream:
            process = subprocess.Popen(argv, cwd=REPO, env=env, stdout=stream, stderr=subprocess.STDOUT)
            code = process.wait()
        record["processes"].append({"argv": argv, "pid": process.pid, "exit_code": code,
                                    "reaped": True, "log": log.name, "log_sha256": digest(log)})
        save()
        return code

    try:
        record.update(prepare(output, args.frozen_source.resolve()))
        save()
        if run([sys.executable, str(REPO / "Core/Tools/ZigEngine/verify.py")], "native-before"):
            raise RuntimeError("Native source receipt verification failed")
        native = REPO / "Core/.zig-build/manifest.json"
        shutil.copy2(native, output / "native-receipt.json")
        record["native_manifest_sha256"] = digest(native)
        record["native_receipt"] = json.loads(native.read_text())
        record["status"] = "building"
        save()
        if run(["swift", "build", "--package-path", str(output), "--configuration", "release",
                "--manifest-cache", "none", "--disable-build-manifest-caching",
                "--product", "ShaperDifferential"], "build"):
            raise RuntimeError("Shaper fixture compilation failed")
        executable = output / ".build/release/ShaperDifferential"
        record["executable_sha256"] = digest(executable)
        record["status"] = "running"
        save()
        code = run([str(executable)], "run")
        if run([sys.executable, str(REPO / "Core/Tools/ZigEngine/verify.py")], "native-after"):
            raise RuntimeError("Native source receipt changed during qualification")
        if digest(native) != record["native_manifest_sha256"]:
            raise RuntimeError("Native archive selection changed during qualification")
        current = {name: digest(REPO / name) for name in record["input_sources"]}
        if current != record["input_sources"]:
            raise RuntimeError("App or fixture sources changed during qualification")
        record["status"] = "pass" if code == 0 else "failed"
        record["summary"] = (output / "run.log").read_text(errors="replace").splitlines()[-1:]
        save()
        print(receipt)
        print("\n".join(record["summary"]))
        raise SystemExit(code)
    except Exception as error:
        record["status"] = "failed"
        record["error"] = str(error)
        save()
        print(f"{error}; evidence: {receipt}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
