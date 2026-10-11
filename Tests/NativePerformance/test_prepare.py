#!/usr/bin/env python3
"""Failure-boundary tests; never launch an application or timed benchmark."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("native_prepare", Path(__file__).with_name("prepare.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def file(self, name, data=b"data"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def qualification(self):
        q = {"status": "library_and_normal_macos_app_integration_pass", "performance_benchmarks_run": False,
             "not_performance_admission": True, "native_source_key": "b" * 64,
             "native_archive_sha256": "c" * 64, "app_binary_sha256": "d" * 64, "evidence": {}}
        def bind(name, data):
            path = self.file(name, data)
            q["evidence"][name] = {"sha256": p.sha(path), "size": len(data)}
        m = {"kind": "cmdy-active-terminal-source-manifest", "reviewState": "unreviewed",
             "sourceCount": 1, "trustFileCount": 0, "trustFiles": [],
             "sources": [{"path": "App/main.swift", "mode": "100644", "size": 4, "sha256": p.digest(b"data")}]}
        bind("schedule-active-source-manifest-final-01.json", json.dumps(m).encode())
        bind("source-snapshots.tar.gz", b"archive hash is checked before extraction")
        c = {"status": "pass", "suites": 5, "failures": 0, "skips": 0,
             "binary": "/completed/cmdy", "binary_sha256": q["app_binary_sha256"],
             "native_source_key": q["native_source_key"], "native_archive_sha256": q["native_archive_sha256"],
             "foreground_activated": False, "os_clipboard_accessed": False,
             "required_native_symbols": list(p.SYMBOLS), "processes": []}
        for suite in p.SUITES:
            text = (suite + " pass").encode()
            bind(f"app-integration-final-01/{suite}.log", text)
            c["processes"].append({"argv": [c["binary"], f"--{suite}-test"], "exit_code": 0,
                                   "reaped": True, "skipped": False, "log_sha256": p.digest(text)})
        symbols = "\n".join(p.SYMBOLS).encode()
        c["native_symbol_inventory_sha256"] = p.digest(symbols)
        bind("app-integration-final-01/native-symbols-corrected.txt", symbols)
        bind("app-integration-final-01/completion.json", json.dumps(c).encode())
        path = self.file("qualification.json", json.dumps(q).encode())
        return path, q, c

    def rewrite_completion(self, path, q, c):
        name = "app-integration-final-01/completion.json"
        data = json.dumps(c).encode()
        self.file(name, data)
        q["evidence"][name] = {"sha256": p.digest(data), "size": len(data)}
        path.write_text(json.dumps(q))

    def test_qualified_evidence_requires_exact_five_reaped_successes(self):
        path, q, c = self.qualification()
        p.qualified_inputs(path)
        for alteration in ("missing", "duplicate", "not-reaped", "skip", "failed"):
            broken = copy.deepcopy(c)
            if alteration == "missing": broken["processes"].pop()
            elif alteration == "duplicate": broken["processes"][1] = broken["processes"][0]
            elif alteration == "not-reaped": broken["processes"][0]["reaped"] = False
            elif alteration == "skip": broken["processes"][0]["skipped"] = True
            else: broken["processes"][0]["exit_code"] = 1
            self.rewrite_completion(path, q, broken)
            with self.subTest(alteration=alteration), self.assertRaises(p.PreparationError):
                p.qualified_inputs(path)

    def test_qualification_rejects_a_different_app_or_archive(self):
        path, q, c = self.qualification()
        for field in ("binary_sha256", "native_source_key", "native_archive_sha256"):
            broken = copy.deepcopy(c)
            broken[field] = "0" * 64
            self.rewrite_completion(path, q, broken)
            with self.subTest(field=field), self.assertRaises(p.PreparationError):
                p.qualified_inputs(path)

    def test_reused_evidence_logs_cannot_be_replaced(self):
        path, _, _ = self.qualification()
        self.file("app-integration-final-01/scroll.log", b"another log")
        with self.assertRaisesRegex(p.PreparationError, "evidence differs"):
            p.qualified_inputs(path)

    def test_reused_evidence_must_exclude_foreground_and_clipboard(self):
        path, q, c = self.qualification()
        for field in ("foreground_activated", "os_clipboard_accessed"):
            broken = copy.deepcopy(c)
            broken.pop(field)
            self.rewrite_completion(path, q, broken)
            with self.assertRaises(p.PreparationError): p.qualified_inputs(path)

    def test_paths_and_symlinks_are_rejected(self):
        for value in ("/tmp/file", "../file", "a/../file", "", ".", "a//b", "./a"):
            with self.subTest(path=value), self.assertRaises(p.PreparationError): p.relative(value)
        self.file("inputs/file")
        (self.root / "inputs/link").symlink_to("file")
        with self.assertRaises(p.PreparationError): p.inventory(self.root / "inputs")

    def test_input_mutation_during_copy_is_rejected(self):
        source = self.file("source")
        copy2 = p.shutil.copy2
        def mutate(src, dst):
            copy2(src, dst)
            src.write_bytes(b"changed")
        with mock.patch.object(p.shutil, "copy2", side_effect=mutate):
            with self.assertRaisesRegex(p.PreparationError, "changed while copying"):
                p.copy_file(source, self.root / "copy")

    def source_archive(self, entries):
        path = self.root / "sources.tar.gz"
        with tarfile.open(path, "w:gz") as t:
            for name, data in entries:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
        return path

    def source_manifest(self):
        return {"sources": [{"path": "App/main.swift", "sha256": p.digest(b"code"),
                              "size": 4, "mode": "100644"}], "trustFiles": []}

    def test_source_archive_requires_exact_final_members_and_bytes(self):
        m = self.source_manifest()
        archive = self.source_archive([("final/App/main.swift", b"code")])
        p.freeze_source(archive, m, self.root / "valid-source")
        self.assertEqual((self.root / "valid-source/App/main.swift").read_bytes(), b"code")
        for entries in ([('final/App/main.swift', b'evil')], [('final/App/other.swift', b'code')],
                        [('final/App/main.swift', b'code'), ('final/App/extra.swift', b'code')],
                        [('final/App/main.swift', b'code'), ('final/App/main.swift', b'code')],
                        [('final/App/main.swift', b'code'), ('../escape', b'code')]):
            archive = self.source_archive(entries)
            with self.subTest(entries=entries), self.assertRaises(p.PreparationError):
                p.freeze_source(archive, m, self.root / "invalid-source")

    def native_fixture(self):
        source = self.root / "source"
        self.file("source/Core/Zig/root.zig", b"zig")
        self.file("source/Core/Sources/CmdyNative/include/engine.h", b"header")
        artifact = self.root / "artifact"
        self.file("artifact/include/engine.h", b"header")
        self.file("artifact/libcmdy_engine.a", b"native archive")
        receipt = {"sources": {"Zig/root.zig": p.digest(b"zig"),
                               "Sources/CmdyNative/include/engine.h": p.digest(b"header")},
                   "zig_version": "0.15.2", "zig_sha256": "a" * 64, "optimize": "ReleaseFast",
                   "architectures": ["arm64"], "minimum_macos": "26.0", "platform_toolchain": {}}
        receipt["source_key"] = p.digest(json.dumps(receipt, sort_keys=True).encode())
        receipt.update(status="pass", archive_sha256=p.sha(artifact / "libcmdy_engine.a"))
        self.file("artifact/receipt.json", json.dumps(receipt).encode())
        q = {"native_source_key": receipt["source_key"], "native_archive_sha256": receipt["archive_sha256"]}
        return artifact, q, source

    def test_native_archive_and_source_and_headers_are_bound(self):
        artifact, q, source = self.native_fixture()
        p.native_receipt(artifact, q, source)
        for file in (artifact / "include/engine.h", artifact / "libcmdy_engine.a", source / "Core/Zig/root.zig"):
            before = file.read_bytes()
            file.write_bytes(b"changed")
            with self.subTest(file=file), self.assertRaises(p.PreparationError): p.native_receipt(artifact, q, source)
            file.write_bytes(before)
        self.file("artifact/include/unreviewed.h", b"extra")
        with self.assertRaisesRegex(p.PreparationError, "header inventory"):
            p.native_receipt(artifact, q, source)

    def test_native_receipt_cannot_select_another_mode_with_the_same_key(self):
        artifact, q, source = self.native_fixture()
        receipt = p.read_json(artifact / "receipt.json")
        receipt["optimize"] = "Debug"
        (artifact / "receipt.json").write_text(json.dumps(receipt))
        with self.assertRaisesRegex(p.PreparationError, "identity differs"):
            p.native_receipt(artifact, q, source)

    def build_fixture(self, external=False):
        original_repo = self.root / "original"
        original = (self.root / "fresh-scratch" if external else original_repo / ".build") / "arm64/release"
        products, source = self.root / "products", self.root / "source"
        key, commands, link = "b" * 64, {}, []
        for name, path in (("CmdyApp", "App/main.swift"), ("CmdyCore", "Core/Sources/CmdyCoreZig/Core.swift"),
                           ("CmdyC", "Core/Sources/CmdyCZig/C.swift"), ("CmdyGPU", "Renderer/Sources/CmdyGPUZig/GPU.swift")):
            self.file("source/" + path)
            obj = name + ".build/code.swift.o"
            self.file("products/" + obj)
            commands[name] = {"moduleName": name, "sources": [str(original_repo / path)],
                              "moduleOutputPath": str(original / "Modules" / (name + ".swiftmodule")),
                              "objects": [str(original / obj)],
                              "otherArguments": ["-DCMDY_ZIG_SELECTED_" + key] if name != "CmdyApp" else []}
            if name != "CmdyApp":
                package = "renderer" if name == "CmdyGPU" else "core"
                verifier = (original.parent.parent / "plugins/outputs" / package / name
                            / "destination/VerifyNativeEngine" / f"NativeEngineVerified-{name}.swift")
                verifier.parent.mkdir(parents=True, exist_ok=True)
                verifier.write_bytes(p.native_verification_source(key))
                commands[name]["sources"].append(str(verifier))
            if name != "CmdyC": link.append(str(original / obj))
        link.append(str(original / "CmdyNative.build/bridge.c.o"))
        self.file("products/CmdyNative.build/bridge.c.o")
        module_map = 'module CmdyNative { umbrella ' + json.dumps(str(original_repo / 'Core/Sources/CmdyNative/include')) + ' export * }'
        self.file("products/CmdyNative.build/module.modulemap", module_map.encode())
        self.file("products/cmdy")
        self.file("products/cmdy.product/Objects.LinkFileList", "\n".join(link).encode())
        self.file("products/description.json", json.dumps({"swiftCommands": commands}).encode())
        return products, source, key, commands

    def test_external_scratch_verifiers_are_validated_and_returned_for_freezing(self):
        products, source, key, commands = self.build_fixture(external=True)
        original, _, generated = p.build_inputs(products, source, key)
        self.assertEqual(original, self.root / "fresh-scratch/arm64/release")
        self.assertEqual(set(generated), {"CmdyCore", "CmdyC", "CmdyGPU"})
        for name, path in generated.items():
            self.assertEqual(str(path), commands[name]["sources"][-1])
            self.assertEqual(path.read_bytes(), p.native_verification_source(key))

    def test_generated_source_exception_rejects_extra_code_wrong_path_or_missing_verifier(self):
        products, source, key, commands = self.build_fixture(external=True)
        path = Path(commands["CmdyCore"]["sources"][-1]); saved = path.read_bytes()
        for data in (saved + b"print(123)\n", saved.replace(key.encode(), b"c" * 64)):
            path.write_bytes(data)
            with self.assertRaisesRegex(p.PreparationError, "generated source"):
                p.build_inputs(products, source, key)
        path.write_bytes(saved)
        for alteration in ("outside", "old-build-exception", "duplicate", "missing"):
            edited = copy.deepcopy(commands)
            if alteration == "outside":
                edited["CmdyCore"]["sources"][-1] = str(self.root / "foreign/NativeEngineVerified-CmdyCore.swift")
            elif alteration == "old-build-exception":
                edited["CmdyCore"]["sources"][-1] = str(self.root / "original/.build/extra.swift")
            elif alteration == "duplicate":
                edited["CmdyCore"]["sources"].append(edited["CmdyCore"]["sources"][-1])
            else:
                edited["CmdyCore"]["sources"].pop()
            (products / "description.json").write_text(json.dumps({"swiftCommands": edited}))
            with self.subTest(alteration=alteration), self.assertRaises(p.PreparationError):
                p.build_inputs(products, source, key)

    def test_only_unlinked_compatibility_product_may_have_unbuilt_verifier(self):
        products, source, key, commands = self.build_fixture(external=True)
        Path(commands["CmdyC"]["sources"][-1]).unlink()
        _, _, generated = p.build_inputs(products, source, key)
        self.assertEqual(set(generated), {"CmdyCore", "CmdyGPU"})
        link = products / "cmdy.product/Objects.LinkFileList"
        saved_link = link.read_bytes()
        link.write_bytes(saved_link + b"\n" + commands["CmdyC"]["objects"][0].encode())
        with self.assertRaisesRegex(p.PreparationError, "compatibility product"):
            p.build_inputs(products, source, key)
        link.write_bytes(saved_link)
        Path(commands["CmdyCore"]["sources"][-1]).unlink()
        with self.assertRaisesRegex(p.PreparationError, "generated source"):
            p.build_inputs(products, source, key)

    def test_build_description_and_linked_objects_must_agree(self):
        products, source, key, commands = self.build_fixture()
        p.build_inputs(products, source, key)
        path = products / "cmdy.product/Objects.LinkFileList"
        saved = path.read_text()
        for text in (saved.replace("CmdyNative.build/bridge.c.o", "Another.build/bridge.c.o"),
                     saved + "\n/tmp/outside.o", saved + "\n" + saved.splitlines()[0]):
            path.write_text(text)
            with self.assertRaises(p.PreparationError): p.build_inputs(products, source, key)

    def test_build_cannot_substitute_old_swift_graph_or_native_key(self):
        products, source, key, commands = self.build_fixture()
        for alteration in ("source", "key"):
            edited = copy.deepcopy(commands)
            if alteration == "source":
                edited["CmdyCore"]["sources"][0] = edited["CmdyCore"]["sources"][0].replace("CmdyCoreZig", "CmdyCore")
            else: edited["CmdyCore"]["otherArguments"] = ["-DCMDY_ZIG_SELECTED_" + "c" * 64]
            (products / "description.json").write_text(json.dumps({"swiftCommands": edited}))
            with self.assertRaises(p.PreparationError): p.build_inputs(products, source, key)

    def test_scripting_requires_all_three_qualified_files(self):
        source, resources = self.root / "source", self.root / "resources"
        self.assertIsNone(p.qualified_scripting(source, {}, resources))
        enabled = {"NSAppleScriptEnabled": True, "OSAScriptingDefinition": "Cmdy.sdef"}
        with self.assertRaises(p.PreparationError): p.qualified_scripting(source, enabled, resources)
        self.file("source/App/Resources/Cmdy.sdef", b"dictionary")
        with self.assertRaises(p.PreparationError): p.qualified_scripting(source, {}, resources)
        self.file("source/App/CmdyPasteAutomation.swift")
        with self.assertRaises(p.PreparationError): p.qualified_scripting(source, {}, resources)
        self.file("source/App/CmdyPasteAutomationBridge.swift")
        self.assertEqual(p.qualified_scripting(source, {}, resources), source / "App/Resources/Cmdy.sdef")
        self.assertEqual(p.qualified_scripting(source, enabled, resources), source / "App/Resources/Cmdy.sdef")

    def test_template_cannot_supply_another_scripting_dictionary(self):
        for name in ("CmdyPasteAutomation.swift", "CmdyPasteAutomationBridge.swift"):
            self.file("source/App/" + name)
        self.file("source/App/Resources/Cmdy.sdef", b"qualified")
        self.file("resources/Cmdy.sdef", b"unqualified")
        with self.assertRaises(p.PreparationError): p.qualified_scripting(self.root / "source", {}, self.root / "resources")
        self.file("resources/Cmdy.sdef", b"qualified")
        with self.assertRaises(p.PreparationError):
            p.qualified_scripting(self.root / "source", {"OSAScriptingDefinition": "Other.sdef"}, self.root / "resources")

    def macho(self, code=b"\x01\x02\x03\x04", signature=False):
        size = 72 + 80
        signature_command = struct.pack("<IIII", 0x1D, 16, 512, 4) if signature else b""
        header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 1 + int(signature),
                             size + len(signature_command), 0, 0)
        segment = struct.pack("<II16sQQQQiiII", 0x19, size, b"__TEXT", 0x1000, 0x1000, 0, 512, 7, 5, 1, 0)
        section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x1200, len(code),
                              256, 2, 0, 0, 0x80000400, 0, 0, 0)
        data = header + segment + section + signature_command
        return data.ljust(256, b"\0") + code + (b"signature" if signature else b"")

    def test_signing_identity_ignores_signature_but_checks_code(self):
        raw = self.file("raw", self.macho())
        signed = self.file("signed", self.macho(signature=True))
        self.assertEqual(p.macho_sections(raw), p.macho_sections(signed))
        signed.write_bytes(self.macho(code=b"evil", signature=True))
        self.assertNotEqual(p.macho_sections(raw), p.macho_sections(signed))

    def test_truncated_or_non_native_executables_fail(self):
        for data in (b"", b"\0" * 32, self.macho()[:50], self.macho()[:-1]):
            with self.subTest(length=len(data)), self.assertRaises(p.PreparationError):
                p.macho_sections(self.file("bad", data))


if __name__ == "__main__":
    unittest.main()
