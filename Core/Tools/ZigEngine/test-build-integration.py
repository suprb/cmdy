#!/usr/bin/env python3
"""Small build-routing, archive-validation and Swift compiler guard fixtures.

No engine compilation or downloads: wrapper subprocesses use an isolated fake
checkout; compiler fixtures use tiny Swift/C declarations and static archives.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import verify
from source_inputs import native_inputs

REPOSITORY = Path(__file__).resolve().parents[3]


class BuildRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmdy-build-routing-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout with spaces"
        self.root.mkdir()
        shutil.copyfile(REPOSITORY / "build.sh", self.root / "build.sh")
        self.log = self.root / "calls.jsonl"
        stub = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ["CMDY_BUILD_PROBE_LOG"],"a") as out:
    out.write(json.dumps({"program":name,"arguments":sys.argv[1:],"zig":os.environ.get("CMDY_ZIG")})+"\\n")
if name=="bootstrap-zig.sh": print("/fixture with spaces/zig")
'''
        for relative in ("bin/swift", "scripts/bootstrap-zig.sh", "Core/Tools/ZigEngine/build.py"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(stub)
            path.chmod(0o755)
        uname = self.root / "bin/uname"
        uname.write_text("#!/bin/sh\necho arm64\n")
        uname.chmod(0o755)

    def run_wrapper(self, arguments=(), **overrides):
        self.log.write_text("")
        environment = os.environ.copy()
        environment.pop("CMDY_NATIVE_ARCH", None)
        environment["CMDY_ZIG"] = "/fixture/zig"
        environment["PATH"] = str(self.root / "bin") + os.pathsep + environment["PATH"]
        environment["CMDY_BUILD_PROBE_LOG"] = str(self.log)
        for key, value in overrides.items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
        process = subprocess.run(["/bin/bash", str(self.root / "build.sh"), *arguments],
                                 env=environment, text=True, capture_output=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return process, calls

    def test_target_and_mode_routing_preserves_swift_arguments(self):
        cases = [
            ([], "Debug", "arm64"),
            (["-c", "release"], "ReleaseFast", "arm64"),
            (["--configuration=release", "--arch=x86_64"], "ReleaseFast", "x86_64"),
            (["--arch", "x86_64"], "Debug", "x86_64"),
            (["--triple=x86_64-apple-macosx26.0"], "Debug", "x86_64"),
            (["--triple", "aarch64-apple-macosx26.0.0"], "Debug", "arm64"),
            (["--triple", "arm64-apple-macosx"], "Debug", "arm64"),
            (["--arch", "x86_64", "--triple=x86_64-apple-macosx27.1"], "Debug", "x86_64"),
            (["--arch=arm64", "--arch", "x86_64"], "Debug", "universal"),
            (["--arch=arm64", "--arch", "arm64"], "Debug", "arm64"),
            (["-Xswiftc", "--arch", "-c", "release"], "ReleaseFast", "arm64"),
        ]
        for arguments, mode, arch in cases:
            with self.subTest(arguments=arguments):
                process, calls = self.run_wrapper(arguments)
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertEqual([call["program"] for call in calls], ["build.py", "swift"])
                self.assertEqual(calls[0]["arguments"], ["--optimize", mode, "--arch", arch])
                self.assertEqual(calls[1]["arguments"], ["build", "--manifest-cache", "none",
                                                        "--disable-build-manifest-caching", *arguments])

    def test_conflicting_or_unsupported_targets_fail_before_building(self):
        cases = [
            ["--arch=x86_64", "--triple=arm64-apple-macosx26.0"],
            ["--arch=arm64", "--arch=x86_64", "--triple=arm64-apple-macosx26.0"],
            ["--triple=arm64-apple-macosx26.0", "--triple=x86_64-apple-macosx26.0"],
            ["--triple=arm64-apple-macosx25.0"], ["--triple=x86_64-unknown-linux-gnu"],
            ["--arch=arm64e"], ["--arch=universal"], ["-c", "release", "--configuration=debug"],
            ["--configuration=other"], ["--arch"], ["--arch="], ["--triple", "--arch=arm64"],
            ["--triple="], ["--configuration"], ["-Xswiftc"],
            ["--destination=fixture.json"], ["--swift-sdk", "fixture"],
            ["--manifest-cache=shared"], ["--manifest-cache", "local"],
            ["--enable-build-manifest-caching"],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                process, calls = self.run_wrapper(arguments, CMDY_ZIG=None)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertEqual(calls, [])

    def test_environment_architecture_must_cover_swift_target(self):
        for arguments, architecture, succeeds, selected in [
            ([], "x86_64", False, None),
            (["--arch=x86_64"], "arm64", False, None),
            ([], "universal", True, "universal"),
            (["--arch=x86_64"], "x86_64", True, "x86_64"),
            (["--arch=x86_64"], "universal", True, "universal"),
            ([], "unknown", False, None),
        ]:
            with self.subTest(arguments=arguments, architecture=architecture):
                process, calls = self.run_wrapper(arguments, CMDY_NATIVE_ARCH=architecture)
                self.assertEqual(process.returncode, 0 if succeeds else 2, process.stderr)
                if succeeds:
                    self.assertEqual(calls[0]["arguments"][-1], selected)
                else:
                    self.assertEqual(calls, [])

    def test_missing_zig_uses_bootstrap_before_native_and_swift(self):
        process, calls = self.run_wrapper(CMDY_ZIG=None)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual([call["program"] for call in calls], ["bootstrap-zig.sh", "build.py", "swift"])
        self.assertEqual(calls[1]["zig"], "/fixture with spaces/zig")


class ArchiveVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmdy-archive-verification-")
        self.addCleanup(self.temporary.cleanup)
        self.core = Path(self.temporary.name)
        self.toolchain = {"sdk_path": "/fixture/sdk", "clang_sha256": "c" * 64}
        self.toolchain_patch = patch("verify.apple_toolchain", return_value=self.toolchain)
        self.toolchain_patch.start()
        self.addCleanup(self.toolchain_patch.stop)
        for relative in ("Zig/abi.zig", "Zig/nested/source.zig", "Zig/testdata/nested/corpus.bin",
                         "Zig/render_shader_core.metal", "Platform/nested/api.m", "Platform/api.h",
                         "Sources/CmdyNative/include/cmdy_native.h", "Tools/ZigEngine/build.py",
                         "Tools/ZigEngine/source_inputs.py", "Tools/ZigEngine/apple_toolchain.py"):
            path = self.core / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
        (self.core / ".zig-build").mkdir()
        (self.core / ".zig-build/libcmdy_engine.a").write_bytes(b"isolated archive checksum fixture")
        self.receipt = dict(sources={str(path.relative_to(self.core)): verify.digest(path)
                                    for path in native_inputs(self.core)},
                            zig_version="0.15.2", zig_sha256="a" * 64, optimize="ReleaseSafe",
                            architectures=["arm64"], minimum_macos="26.0", status="pass",
                            platform_toolchain=self.toolchain,
                            archive_sha256=verify.digest(self.core / ".zig-build/libcmdy_engine.a"))
        self.write_receipt()

    def write_receipt(self, resign=True):
        if resign:
            identity = {key: self.receipt[key] for key in verify.IDENTITY_FIELDS}
            self.receipt["source_key"] = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        (self.core / ".zig-build/manifest.json").write_text(json.dumps(self.receipt))
        artifact = self.core / ".zig-build/artifacts" / self.receipt["source_key"]
        artifact.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.core / ".zig-build/libcmdy_engine.a", artifact / "libcmdy_engine.a")
        (artifact / "receipt.json").write_text(json.dumps(self.receipt))
        (self.core / "Sources/CmdyNative/include/cmdy_engine_build.h").write_text(
            f'#define CMDY_ZIG_SOURCE_KEY "{self.receipt["source_key"]}"\n'
            f'#define CMDY_ZIG_BUILD_MODE "{self.receipt["optimize"]}"\n')

    def test_supported_receipts_include_qualification_and_universal_builds(self):
        for optimize in ("Debug", "ReleaseSafe", "ReleaseFast"):
            for architectures in (["arm64"], ["x86_64"], ["arm64", "x86_64"]):
                with self.subTest(optimize=optimize, architectures=architectures):
                    self.receipt.update(optimize=optimize, architectures=architectures)
                    self.write_receipt()
                    self.assertEqual(verify.verify(self.core), self.receipt)

    def test_invalid_target_mode_and_toolchain_receipts_are_rejected(self):
        cases = [("architectures", []), ("architectures", ["arm64", "arm64"]),
                 ("architectures", ["i386"]), ("architectures", "arm64"),
                 ("architectures", [None]), ("optimize", "ReleaseSmall"),
                 ("minimum_macos", "25.0"), ("zig_version", "0.14.0"),
                 ("platform_toolchain", {"sdk_path": "/other/sdk"}),
                 ("zig_sha256", "not-a-checksum"), ("status", "failed")]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                original = self.receipt[key]
                self.receipt[key] = value
                self.write_receipt()
                with self.assertRaises(ValueError):
                    verify.verify(self.core)
                self.receipt[key] = original

    def test_identity_archive_and_exact_header_mismatches_are_rejected(self):
        self.receipt["zig_sha256"] = "b" * 64
        self.write_receipt(resign=False)
        with self.assertRaisesRegex(ValueError, "build identity"):
            verify.verify(self.core)
        self.write_receipt()
        header = self.core / "Sources/CmdyNative/include/cmdy_engine_build.h"
        header.write_text(header.read_text() + "int injected_declaration;\n")
        with self.assertRaisesRegex(ValueError, "build header"):
            verify.verify(self.core)
        self.write_receipt()
        (self.core / ".zig-build/libcmdy_engine.a").write_bytes(b"changed archive")
        with self.assertRaisesRegex(ValueError, "archive checksum"):
            verify.verify(self.core)

    def test_changed_nested_sources_and_embedded_data_are_rejected(self):
        for relative in ("Zig/nested/source.zig", "Zig/testdata/nested/corpus.bin",
                         "Zig/render_shader_core.metal", "Platform/nested/api.m", "Platform/api.h",
                         "Sources/CmdyNative/include/nested/new.h", "Zig/new/source.zig"):
            with self.subTest(relative=relative):
                path = self.core / relative
                original = path.read_bytes() if path.exists() else None
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"changed input")
                with self.assertRaisesRegex(ValueError, "source hashes"):
                    verify.verify(self.core)
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_immutable_artifact_is_verified_independently_of_mutable_alias(self):
        artifact = self.core / ".zig-build/artifacts" / self.receipt["source_key"]
        (artifact / "libcmdy_engine.a").write_bytes(b"damaged immutable archive")
        with self.assertRaisesRegex(ValueError, "immutable native archive checksum"):
            verify.verify(self.core)
        self.write_receipt()
        (artifact / "receipt.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "immutable native artifact receipt"):
            verify.verify(self.core)


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swiftc"), "requires macOS Swift")
class SwiftGuardTests(unittest.TestCase):
    def test_real_compiler_rejects_wrong_architecture_and_debug_native_release(self):
        cases = [
            (["arm64"], "Debug", "arm64", True, None),
            (["arm64"], "Debug", "arm64", False, "Debug archive cannot be used"),
            (["arm64"], "ReleaseSafe", "arm64", False, None),
            (["arm64"], "ReleaseFast", "arm64", False, None),
            (["arm64"], "ReleaseSafe", "x86_64", False, "does not contain this architecture"),
            (["x86_64"], "ReleaseSafe", "arm64", False, "does not contain this architecture"),
            (["arm64", "x86_64"], "ReleaseSafe", "arm64", False, None),
            (["arm64", "x86_64"], "ReleaseSafe", "x86_64", False, None),
        ]
        with tempfile.TemporaryDirectory(prefix="cmdy-swift-archive-guards-") as directory:
            source = Path(directory) / "NativeEngineVerified.swift"
            for architectures, mode, target, debug, expected_error in cases:
                with self.subTest(architectures=architectures, mode=mode, target=target, debug=debug):
                    source.write_text(verify.verification_source(dict(
                        architectures=architectures, optimize=mode, source_key="a" * 64)))
                    command = ["swiftc", "-typecheck", "-target", target + "-apple-macosx26.0",
                               "-module-cache-path", str(Path(directory) / "module-cache"),
                               "-D", "CMDY_ZIG_SELECTED_" + "a" * 64, str(source)]
                    if debug:
                        command.extend(["-D", "DEBUG"])
                    process = subprocess.run(command, text=True, capture_output=True)
                    if expected_error:
                        self.assertNotEqual(process.returncode, 0)
                        self.assertIn(expected_error, process.stderr)
                    else:
                        self.assertEqual(process.returncode, 0, process.stderr)


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("swift") and shutil.which("clang"),
                     "requires macOS Swift and Clang")
class NativePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmdy-native-publication-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.core = self.root / "Core"
        for relative in ("Package.swift", "Tools/ZigEngine/build.py", "Tools/ZigEngine/source_inputs.py",
                         "Tools/ZigEngine/apple_toolchain.py",
                         "Sources/CmdyNative/bridge.c"):
            destination = self.core / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / "Core" / relative, destination)
        include = self.core / "Sources/CmdyNative/include"
        include.mkdir()
        (include / "cmdy_native.h").write_text(
            '#include <stdint.h>\nuint32_t cmdy_zig_engine_abi_version(void);\n'
            'uint32_t cmdy_native_engine_abi_version(void);\n'
            'const char *cmdy_native_engine_source_key(void);\n'
            'const char *cmdy_native_engine_build_mode(void);\n')
        (self.core / "Zig").mkdir()
        (self.core / "Zig/abi.zig").write_text("// Publication fixture: compiler emits a mode marker.\n")
        compiler = self.root / "fixture-zig"
        compiler.write_text('''#!/usr/bin/env python3
import re,subprocess,sys
from pathlib import Path
if sys.argv[1:]==["version"]:
    print("0.15.2")
    raise SystemExit(0)
archive=Path(next(arg.split("=",1)[1] for arg in sys.argv if arg.startswith("-femit-bin=")))
mode=next(arg[2:] for arg in sys.argv if arg.startswith("-O"))
marker={"Debug":10,"ReleaseSafe":20,"ReleaseFast":30}[mode]
override=re.search(r"fixture-abi-marker:(\\d+)",Path(sys.argv[2]).read_text())
if override: marker=int(override[1])
source="#include <stdint.h>\\nuint32_t cmdy_zig_engine_abi_version(void) { return "+str(marker)+"; }\\n"
obj=archive.with_suffix(".o")
subprocess.run(["clang","-c","-x","c","-","-o",str(obj)],input=source,text=True,check=True)
subprocess.run(["ar","rcs",str(archive),str(obj)],check=True)
''')
        compiler.chmod(0o755)
        self.environment = dict(os.environ, CMDY_ZIG=str(compiler))

    def build(self, mode, output=None):
        command = [sys.executable, "-B", str(self.core / "Tools/ZigEngine/build.py"), "--optimize", mode]
        if output is not None:
            command.extend(["--output", str(output)])
        process = subprocess.run(command, env=self.environment, text=True, capture_output=True)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        return json.loads(((output or self.core / ".zig-build") / "manifest.json").read_text())

    def package_selection(self, fresh=True):
        command = ["swift", "package", "--package-path", str(self.core)]
        if fresh:
            command.extend(["--manifest-cache", "none"])
        process = subprocess.run([*command, "dump-package"], text=True, capture_output=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        targets = json.loads(process.stdout)["targets"]
        native = next(target for target in targets if target["name"] == "CmdyNative")
        swift = next(target for target in targets if target["name"] == "CmdyCore")
        archive = next(setting["kind"]["unsafeFlags"]["_0"][0] for setting in native["settings"]
                       if setting["tool"] == "linker" and "unsafeFlags" in setting["kind"])
        c_define = next(setting["kind"]["define"]["_0"] for setting in native["settings"]
                        if setting["tool"] == "c")
        swift_define = next(setting["kind"]["define"]["_0"] for setting in swift["settings"])
        return Path(archive), c_define, swift_define

    def test_alternate_output_preserves_existing_production_publication(self):
        production = self.build("ReleaseFast")
        paths = [self.core / ".zig-build/manifest.json", self.core / ".zig-build/libcmdy_engine.a",
                 self.core / "Sources/CmdyNative/include/cmdy_engine_build.h", self.core / "Package.swift"]
        original = {path: path.read_bytes() for path in paths}
        alternate = self.root / "alternate output"
        custom = self.build("Debug", alternate)
        self.assertNotEqual(production["source_key"], custom["source_key"])
        self.assertEqual(original, {path: path.read_bytes() for path in paths})
        self.assertIn(custom["source_key"], (alternate / "cmdy_engine_build.h").read_text())
        self.assertEqual(verify.verify(self.core), production)

    def test_alternate_output_on_clean_checkout_does_not_publish_production_header(self):
        self.build("Debug", self.root / "alternate")
        self.assertFalse((self.core / "Sources/CmdyNative/include/cmdy_engine_build.h").exists())
        self.assertFalse((self.core / ".zig-build/manifest.json").exists())
        self.assertIn("/artifacts/unprepared/", str(self.package_selection()[0]))

    def test_fresh_manifest_selects_new_immutable_archive_and_matching_compiler_keys(self):
        first = self.build("ReleaseFast")
        old_archive, _, _ = self.package_selection(fresh=False)
        second = self.build("Debug")
        archive, c_define, swift_define = self.package_selection()
        self.assertEqual(archive, self.core / ".zig-build/artifacts" / second["source_key"] / "libcmdy_engine.a")
        self.assertEqual(c_define, 'CMDY_ZIG_SELECTED_SOURCE_KEY="' + second["source_key"] + '"')
        self.assertEqual(swift_define, "CMDY_ZIG_SELECTED_" + second["source_key"])
        self.assertNotEqual(archive, old_archive)
        self.assertIn(first["source_key"], str(old_archive))

    def test_wrapper_replans_existing_build_after_native_source_key_changes(self):
        # Keep both package manifests and the Swift source unchanged across
        # actual incremental builds. The dependency's native receipt is a
        # dynamic manifest input, outside SwiftPM's ordinary build-plan inputs.
        shutil.copyfile(REPOSITORY / "build.sh", self.root / "build.sh")
        (self.root / "Package.swift").write_text('''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "NativeSelectionProbe", platforms: [.macOS("26.0")],
    dependencies: [.package(path: "Core")], targets: [
        .executableTarget(name: "NativeSelectionClient",
            dependencies: [.product(name: "CmdyNative", package: "Core")], path: "Client",
            plugins: [.plugin(name: "NativePublicationProbe")]),
        .plugin(name: "NativePublicationProbe", capability: .buildTool())
    ])
''')
        (self.core / "Package.swift").write_text('''// swift-tools-version:5.9
import PackageDescription
import Foundation
let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let data = try! Data(contentsOf: core.appendingPathComponent(".zig-build/manifest.json"))
let receipt = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
let key = receipt["source_key"] as! String
let archive = core.appendingPathComponent(".zig-build/artifacts/\\(key)/libcmdy_engine.a").path
let package = Package(name: "Core", platforms: [.macOS("26.0")],
    products: [.library(name: "CmdyNative", targets: ["CmdyNative"])], targets: [
    .target(name: "CmdyNative", path: "Sources/CmdyNative", publicHeadersPath: "include",
        cSettings: [.define("CMDY_ZIG_SELECTED_SOURCE_KEY", to: "\\\"\\(key)\\\"")],
        linkerSettings: [.unsafeFlags([archive])])
])
''')
        client = self.root / "Client"
        client.mkdir()
        (client / "main.swift").write_text('''import CmdyNative
print(cmdy_native_engine_abi_version())
print(String(cString: cmdy_native_engine_source_key()))
''')
        plugin = self.root / "Plugins/NativePublicationProbe"
        plugin.mkdir(parents=True)
        (plugin / "plugin.swift").write_text('''import PackagePlugin
@main struct NativePublicationProbe: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let output = context.pluginWorkDirectory.appending("PublicationProbe.swift")
        return [.buildCommand(displayName: "Observe native publication",
            executable: Path("/usr/bin/touch"), arguments: [output.string],
            inputFiles: [context.package.directory.appending("Core/.zig-build/manifest.json")],
            outputFiles: [output])]
    }
}
''')
        scratch = self.root / "reused build state"
        scratch.mkdir()
        preserved = scratch / "keep-unrelated-state"
        preserved.write_text("preserve existing build state")
        command = ["/bin/bash", str(self.root / "build.sh"), "-c", "release",
                   "--scratch-path", str(scratch), "--jobs", "2"]

        def build_and_run(build_command=command):
            built = subprocess.run(build_command, env=self.environment, text=True, capture_output=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            selected = json.loads((self.core / ".zig-build/manifest.json").read_text())["source_key"]
            result = subprocess.run([str(scratch / "release/NativeSelectionClient")],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(preserved.read_text(), "preserve existing build state")
            return selected, result.stdout.splitlines()

        # Model an existing developer build made with SwiftPM's default plan
        # cache, before the wrapper prepares the next native publication.
        self.build("ReleaseFast")
        first, first_output = build_and_run([
            "swift", "build", "--package-path", str(self.root), "-c", "release",
            "--scratch-path", str(scratch), "--jobs", "2"])
        self.assertEqual(first_output, ["30", first])
        with (self.core / "Zig/abi.zig").open("a") as source:
            source.write("// fixture-abi-marker:31\n")
        second, second_output = build_and_run()
        self.assertNotEqual(first, second)
        self.assertEqual(second_output, ["31", second])
        self.assertTrue((self.core / ".zig-build/artifacts" / first / "libcmdy_engine.a").is_file())
        # An unchanged third build still reuses the current archive and works
        # in the same scratch directory without a cleanup step.
        self.assertEqual(build_and_run(), (second, ["31", second]))

    def test_republication_rejects_mixed_compilation_and_preserves_already_selected_link(self):
        first = self.build("ReleaseFast")
        archive, c_define, swift_define = self.package_selection()
        include = self.core / "Sources/CmdyNative/include"
        bridge = self.core / "Sources/CmdyNative/bridge.c"
        bridge_object = self.root / "first-bridge.o"
        compile_bridge = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(include),
                          "-D" + c_define, "-c", str(bridge), "-o", str(bridge_object)]
        process = subprocess.run(compile_bridge, text=True, capture_output=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        archive_hash = verify.digest(archive)

        # Another build publishes a different mode after SwiftPM selected the
        # first key and the first C object was compiled.
        second = self.build("Debug")
        self.assertNotEqual(first["source_key"], second["source_key"])
        self.assertEqual(archive_hash, verify.digest(archive))
        self.assertNotEqual(archive_hash, verify.digest(self.core / ".zig-build/libcmdy_engine.a"))

        mixed_c = subprocess.run([*compile_bridge[:-1], str(self.root / "mixed-bridge.o")],
                                 text=True, capture_output=True)
        self.assertNotEqual(mixed_c.returncode, 0)
        self.assertIn("native archive selection changed", mixed_c.stderr)

        generated = self.root / "NativeEngineVerified.swift"
        generated.write_text(verify.verification_source(verify.verify(self.core)))
        mixed_swift = subprocess.run(["swiftc", "-typecheck", "-D", "DEBUG", "-D", swift_define,
                                      "-module-cache-path", str(self.root / "swift-cache"), str(generated)],
                                     text=True, capture_output=True)
        self.assertNotEqual(mixed_swift.returncode, 0)
        self.assertIn("native archive selection changed", mixed_swift.stderr)

        # Existing compilation is still a consistent first build: its real
        # linked native marker and bridge metadata must both describe A even
        # though the mutable alias now points to B.
        client = self.root / "client.c"
        client.write_text('#include "cmdy_native.h"\n#include <string.h>\nint main(void) {\n'
                          'return !(cmdy_native_engine_abi_version() == 30 &&\n'
                          'strcmp(cmdy_native_engine_source_key(), "' + first["source_key"] + '") == 0 &&\n'
                          'strcmp(cmdy_native_engine_build_mode(), "ReleaseFast") == 0);\n}\n')
        executable = self.root / "selected-native-client"
        linked = subprocess.run(["clang", "-I", str(include), str(client), str(bridge_object), str(archive),
                                 "-o", str(executable)], text=True, capture_output=True)
        self.assertEqual(linked.returncode, 0, linked.stderr)
        self.assertEqual(subprocess.run([str(executable)]).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
