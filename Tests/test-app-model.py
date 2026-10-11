#!/usr/bin/env python3
"""Run the App model and initial-shell regressions without launching CMDY.

Production sources are staged afresh. The same-file test seams live only in
this temporary SwiftPM target; neither App sources nor the root package change.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release"),
                        default=os.environ.get("CMDY_TEST_CONFIGURATION", "debug"))
    parser.add_argument("--keep", action="store_true",
                        help="retain successful staged sources and logs (failures are always kept)")
    parser.add_argument("--filter", help="run only matching App model XCTest cases, without the initial-shell suite")
    parser.add_argument("--use-existing-native", action="store_true",
                        help="verify the selected native archive and require the requested configuration without rebuilding")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    tests = repository / "Tests/AppModelTests"
    stage = Path(tempfile.mkdtemp(prefix="cmdy-app-model-tests-"))
    print(f"App model test workspace: {stage}", flush=True)
    succeeded = False
    try:
        package = stage / "ModelProbe"
        sources = package / "Sources/ModelProbe"
        test_target = package / "Tests/ModelProbeTests"
        sources.mkdir(parents=True)
        test_target.mkdir(parents=True)
        for name in ("TerminalModel.swift", "SnapshotPublicationMailbox.swift",
                     "SnapshotPublicationScheduler.swift", "HistoryMaintenanceScheduler.swift", "CmdyPerformanceTrace.swift", "TerminalTextFile.swift", "TerminalScrollbackExport.swift", "TerminalScreenExport.swift"):
            shutil.copyfile(repository / "App" / name, sources / name)
        with (sources / "TerminalModel.swift").open("ab") as model:
            model.write((tests / "TerminalModelTestSeams.swift").read_bytes())
        for name in ("SnapshotPublicationMailboxTests.swift", "SnapshotPublicationSchedulerTests.swift", "HistoryMaintenanceSchedulerTests.swift", "TerminalModelHistoryMaintenanceTests.swift",
                     "TerminalModelPublicationTests.swift", "TerminalModelSchedulerTests.swift", "TerminalScrollbackExportTests.swift", "TerminalScreenExportTests.swift"):
            shutil.copyfile(tests / name, test_target / name)
        # JSON quoting is also valid for these Swift path strings; no shell is used.
        core = json.dumps(str(repository / "Core"), ensure_ascii=False)
        kit = json.dumps(str(repository / "Kit"), ensure_ascii=False)
        (package / "Package.swift").write_text(f"""// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ModelProbe", platforms: [.macOS("26.0")],
    products: [.library(name: "ModelProbe", targets: ["ModelProbe"])],
    dependencies: [.package(path: {core}), .package(path: {kit})],
    targets: [
        .target(name: "ModelProbe", dependencies: [
            .product(name: "CmdyCore", package: "Core"),
            .product(name: "CmdyNative", package: "Core"),
            .product(name: "CmdyPTY", package: "Core"),
            .product(name: "CmdyKit", package: "Kit")]),
        .testTarget(name: "ModelProbeTests", dependencies: ["ModelProbe"])])
""")
        shutil.copyfile(repository / "App/InitialShellLaunches.swift", stage / "InitialShellLaunches.swift")
        shutil.copyfile(tests / "InitialShellLaunchesTests.swift", stage / "InitialShellLaunchesTests.swift")
        environment = os.environ.copy()
        environment["CMDY_FRAME_TRACE"] = "0"
        if not args.use_existing_native and not environment.get("CMDY_ZIG"):
            environment["CMDY_ZIG"] = subprocess.check_output(
                [str(repository / "scripts/bootstrap-zig.sh")], text=True).strip()
        shell_optimization = "-O" if args.configuration == "release" else "-Onone"
        native_optimization = "ReleaseFast" if args.configuration == "release" else "Debug"
        if args.use_existing_native:
            native = json.loads((repository / "Core/.zig-build/manifest.json").read_text())
            if native.get("optimize") != native_optimization:
                raise RuntimeError(f"selected native optimization {native.get('optimize')!r} does not match {native_optimization!r}")
            native_command = ["python3", str(repository / "Core/Tools/ZigEngine/verify.py"),
                              "--core", str(repository / "Core")]
        else:
            native_command = ["python3", str(repository / "Core/Tools/ZigEngine/build.py"),
                              "--optimize", native_optimization]
        commands = [
            ("native-engine", native_command),
            ("publication", ["swift", "test", "--jobs", "2", "--manifest-cache", "none", "--disable-build-manifest-caching", "--package-path", str(package),
                             "-c", args.configuration, "--scratch-path",
                             str(repository / ".build/app-model-tests")] + (["--filter", args.filter] if args.filter else [])),
            ("initial-shell-build", ["xcrun", "swiftc", shell_optimization, "-parse-as-library",
                                     str(stage / "InitialShellLaunches.swift"),
                                     str(stage / "InitialShellLaunchesTests.swift"),
                                     "-o", str(stage / "initial-shell-tests")]),
            ("initial-shell", [str(stage / "initial-shell-tests")]),
        ]
        if args.filter:
            commands = commands[:2]
        (stage / "commands.json").write_text(json.dumps({
            "commands": commands, "configuration": args.configuration, "filter": args.filter,
            "useExistingNative": args.use_existing_native,
            "environmentOverrides": {"CMDY_FRAME_TRACE": "0"},
            "repository": str(repository),
        }, indent=2) + "\n")
        processes = []
        for name, command in commands:
            print("Running " + json.dumps(command), flush=True)
            log = stage / (name + ".log")
            with log.open("w") as output:
                process = subprocess.Popen(command, cwd=repository, env=environment,
                                           stdout=output, stderr=subprocess.STDOUT)
                try:
                    code = process.wait()
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
                finally:
                    processes.append({"name": name, "pid": process.pid, "exitCode": process.returncode,
                                      "reaped": process.returncode is not None})
                    (stage / "processes.json").write_text(json.dumps(processes, indent=2) + "\n")
            print(log.read_text(), end="", flush=True)
            if code:
                return code
            if args.filter and name == "publication":
                counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", log.read_text())
                if not counts or max(int(count) for count, _ in counts) == 0:
                    print("FAIL no focused App model tests executed", flush=True)
                    return 1
        succeeded = True
        if args.filter:
            print(f"PASS focused App model tests matching {args.filter!r}", flush=True)
        else:
            print("PASS App snapshot publication and initial-shell regression suites", flush=True)
        return 0
    finally:
        if succeeded and not args.keep:
            shutil.rmtree(stage)
        else:
            print(f"Retained App model test workspace: {stage}", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
