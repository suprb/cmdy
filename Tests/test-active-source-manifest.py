#!/usr/bin/env python3
"""Focused fail-closed tests for check-active-source-manifest.py."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).resolve().parent.parent
SCRIPT = REPOSITORY / "scripts/check-active-source-manifest.py"
HISTORICAL_SCRIPT = REPOSITORY / "scripts/check-working-tree-provenance.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


manifest_gate = load_module("active_source_manifest", SCRIPT)
historical_gate = load_module("working_tree_provenance_for_manifest_test", HISTORICAL_SCRIPT)


class ActiveSourceManifestTests(unittest.TestCase):
    def fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)

        implementation = root / manifest_gate.POLICY_IMPLEMENTATION
        implementation.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, implementation)

        for relative_root, suffixes in manifest_gate.ACTIVE_ROOTS:
            directory = root / relative_root
            directory.mkdir(parents=True)
            (directory / ("Active" + suffixes[0])).write_text(
                "public struct ActiveValue {}\n", encoding="utf-8",
            )

        for relative_root in manifest_gate.IMPORT_SCAN_ROOTS:
            (root / relative_root).mkdir(parents=True, exist_ok=True)

        app = root / "App"
        app.mkdir(exist_ok=True)
        for index, relative in enumerate(manifest_gate.REQUIRED_APP_SOURCES):
            (root / relative).write_text(
                f"final class RequiredSeam{index} {{}}\n", encoding="utf-8",
            )
        (app / "Extra.swift").write_text(
            "struct ExtraSource {}\n", encoding="utf-8",
        )

        for relative in manifest_gate.PACKAGE_MANIFESTS:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "// SwiftTerm and TermiteCore in comments are historical prose only.\n"
                "let packageMarker = \"independent\"\n",
                encoding="utf-8",
            )
        for relative in (
            set(manifest_gate.PACKAGE_GRAPH_INPUTS)
            - set(manifest_gate.PACKAGE_MANIFESTS)
        ):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{"name":"cmdy"}\n', encoding="utf-8")
        return temporary, root

    def write_manifest(self, root: Path) -> tuple[dict[str, object], Path]:
        manifest = manifest_gate.build_manifest(root)
        path = root / "provisional.json"
        path.write_bytes(manifest_gate.canonical_bytes(manifest))
        return manifest, path

    def test_policy_contains_historical_gate_source_boundary(self) -> None:
        self.assertTrue(
            set(manifest_gate.ACTIVE_ROOTS).issuperset(historical_gate.ACTIVE_ROOTS)
        )
        self.assertEqual(
            manifest_gate.REQUIRED_APP_SOURCES,
            historical_gate.REQUIRED_APP_SEAM,
        )
        self.assertTrue(
            set(manifest_gate.RETIRED_ROOTS).issuperset(historical_gate.RETIRED_ROOTS)
        )
        self.assertIn("Termite*.swift", manifest_gate.RETIRED_APP_GLOBS)
        self.assertIn("SwiftTerm*.swift", manifest_gate.RETIRED_APP_GLOBS)

    def test_round_trip_is_canonical_and_deterministic(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        first, path = self.write_manifest(root)
        second = manifest_gate.build_manifest(root)
        loaded, raw = manifest_gate.load_manifest(path, root)
        self.assertEqual(first, second)
        self.assertEqual(first, loaded)
        self.assertEqual(raw, manifest_gate.canonical_bytes(first))
        self.assertEqual(first["reviewState"], "unreviewed")
        self.assertEqual(first["sourceCount"], 15)
        self.assertEqual(first["trustFileCount"], len(manifest_gate.PACKAGE_GRAPH_INPUTS))
        self.assertEqual(
            [entry["path"] for entry in first["trustFiles"]],
            sorted(manifest_gate.PACKAGE_GRAPH_INPUTS),
        )

    def test_hash_size_and_mode_changes_fail(self) -> None:
        for mutation, expected_issue in (
            (lambda path: path.write_text("struct Changed {}\n"), "sha256 changed"),
            (lambda path: path.write_text("struct ExtraSource { let x = 1 }\n"), "size changed"),
            (lambda path: path.chmod(0o755), "mode changed"),
        ):
            with self.subTest(expected_issue=expected_issue):
                temporary, root = self.fixture()
                self.addCleanup(temporary.cleanup)
                expected, _ = self.write_manifest(root)
                mutation(root / "App/Extra.swift")
                actual = manifest_gate.build_manifest(root)
                issues = manifest_gate.comparison_issues(expected, actual)
                self.assertTrue(any(expected_issue in issue for issue in issues), issues)

    def test_path_addition_and_missing_file_fail(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        expected, _ = self.write_manifest(root)
        (root / "App/NewSeam.swift").write_text("struct NewSeam {}\n")
        issues = manifest_gate.comparison_issues(
            expected, manifest_gate.build_manifest(root),
        )
        self.assertIn("unexpected active source: App/NewSeam.swift", issues)

        (root / "App/NewSeam.swift").unlink()
        (root / "App/Extra.swift").unlink()
        issues = manifest_gate.comparison_issues(
            expected, manifest_gate.build_manifest(root),
        )
        self.assertIn("missing active source: App/Extra.swift", issues)

    def test_package_manifest_bytes_are_bound_as_trust_files(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        expected, _ = self.write_manifest(root)
        package = root / "Kit/Package.swift"
        package.write_bytes(package.read_bytes() + b"// dependency graph drift\n")
        identity = root / "Identity/Sources/ProductIdentity/Resources/product-identity.json"
        identity.write_text('{"name":"different"}\n', encoding="utf-8")
        issues = manifest_gate.comparison_issues(
            expected, manifest_gate.build_manifest(root),
        )
        self.assertIn("trust file size changed: Kit/Package.swift", issues)
        self.assertIn("trust file sha256 changed: Kit/Package.swift", issues)
        self.assertIn(
            "trust file sha256 changed: "
            "Identity/Sources/ProductIdentity/Resources/product-identity.json",
            issues,
        )

    def test_package_graph_input_missing_or_symlink_fails(self) -> None:
        identity_relative = (
            "Identity/Sources/ProductIdentity/Resources/product-identity.json"
        )
        for scenario in ("missing", "symlink"):
            with self.subTest(scenario=scenario):
                temporary, root = self.fixture()
                self.addCleanup(temporary.cleanup)
                identity = root / identity_relative
                identity.unlink()
                if scenario == "missing":
                    expected = f"missing package-graph input: {identity_relative}"
                else:
                    identity.symlink_to(root / "App/Extra.swift")
                    expected = (
                        "package-graph input contains symlink component: "
                        f"{identity_relative}"
                    )
                with self.assertRaisesRegex(
                    manifest_gate.ManifestError, re.escape(expected),
                ):
                    manifest_gate.build_manifest(root)

    def test_platform_terminal_sources_are_bound(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        expected, _ = self.write_manifest(root)
        seam = root / "Kit/Sources/CmdyKit/Active.swift"
        seam.write_text("public struct ChangedValue {}\n", encoding="utf-8")
        issues = manifest_gate.comparison_issues(
            expected, manifest_gate.build_manifest(root),
        )
        self.assertIn(
            "active source sha256 changed: Kit/Sources/CmdyKit/Active.swift",
            issues,
        )

    def test_unapproved_source_suffix_in_governed_root_fails(self) -> None:
        for suffix in (".mm", ".cpp", ".S", ".h++", ".modulemap"):
            with self.subTest(suffix=suffix):
                temporary, root = self.fixture()
                self.addCleanup(temporary.cleanup)
                injected = root / f"Renderer/Sources/CmdyGPU/Injected{suffix}"
                injected.write_text("injected\n", encoding="utf-8")
                with self.assertRaisesRegex(
                    manifest_gate.ManifestError,
                    "unapproved source suffix in governed source tree: .*Injected",
                ):
                    manifest_gate.build_manifest(root)

    def test_symlink_and_uncovered_source_root_fail(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        (root / "App/Linked.swift").symlink_to(root / "App/Extra.swift")
        with self.assertRaisesRegex(manifest_gate.ManifestError, "symlink"):
            manifest_gate.build_manifest(root)

        (root / "App/Linked.swift").unlink()
        uncovered = root / "Core/Sources/CmdyHidden/Hidden.swift"
        uncovered.parent.mkdir()
        uncovered.write_text("struct Hidden {}\n")
        with self.assertRaisesRegex(manifest_gate.ManifestError, "uncovered active source root"):
            manifest_gate.build_manifest(root)

    def test_import_scan_roots_and_children_fail_closed(self) -> None:
        scenarios = (
            "missing-root", "linked-root", "linked-ancestor", "linked-child",
        )
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                temporary, root = self.fixture()
                self.addCleanup(temporary.cleanup)
                scan_root = root / "Identity/Sources"
                if scenario == "missing-root":
                    shutil.rmtree(scan_root)
                    expected = "missing import-scan root: Identity/Sources"
                elif scenario == "linked-root":
                    shutil.rmtree(scan_root)
                    scan_root.symlink_to(root / "App", target_is_directory=True)
                    expected = (
                        "import-scan root contains symlink component: Identity/Sources"
                    )
                elif scenario == "linked-ancestor":
                    original = root / "Kit"
                    moved = root / "RealKit"
                    original.rename(moved)
                    original.symlink_to(moved, target_is_directory=True)
                    expected = "import-scan root contains symlink component: Kit"
                else:
                    (scan_root / "Linked.swift").symlink_to(root / "App/Extra.swift")
                    expected = "symlink in import-scan tree: Identity/Sources/Linked.swift"
                with self.assertRaisesRegex(
                    manifest_gate.ManifestError, re.escape(expected),
                ):
                    manifest_gate.build_manifest(root)

    def test_retired_roots_imports_and_package_references_fail(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        retired = root / manifest_gate.RETIRED_ROOTS[0]
        retired.mkdir(parents=True)
        with self.assertRaisesRegex(manifest_gate.ManifestError, "retired source root remains"):
            manifest_gate.build_manifest(root)

        retired.rmdir()
        platform_source = root / "Kit/Sources/CmdyKit/Bad.swift"
        platform_source.parent.mkdir(parents=True, exist_ok=True)
        platform_source.write_text("@_implementationOnly import class SwiftTerm.Terminal\n")
        with self.assertRaisesRegex(manifest_gate.ManifestError, "retired module import"):
            manifest_gate.build_manifest(root)

        platform_source.unlink()
        root.joinpath("Package.swift").write_text(
            'let dependency = "https://example.invalid/SwiftTerm.git"\n'
        )
        with self.assertRaisesRegex(
            manifest_gate.ManifestError, "retired module reference in package manifest",
        ):
            manifest_gate.build_manifest(root)

    def test_expanded_retired_names_fail(self) -> None:
        for kind in ("root", "app", "import", "package"):
            with self.subTest(kind=kind):
                temporary, root = self.fixture()
                self.addCleanup(temporary.cleanup)
                if kind == "root":
                    (root / "Kit/Sources/TermiteKit").mkdir()
                    expected = "retired source root remains: Kit/Sources/TermiteKit"
                elif kind == "app":
                    (root / "App/TermiteEditor.swift").write_text(
                        "final class TermiteEditor {}\n", encoding="utf-8",
                    )
                    expected = "retired App source remains: App/TermiteEditor.swift"
                elif kind == "import":
                    source = root / "Kit/Sources/CmdyKit/Bad.swift"
                    source.parent.mkdir(exist_ok=True)
                    source.write_text("import TermiteKit\n", encoding="utf-8")
                    expected = "retired module import in Kit/Sources/CmdyKit/Bad.swift"
                else:
                    root.joinpath("Package.swift").write_text(
                        'let dependency = "TermiteSDK"\n', encoding="utf-8",
                    )
                    expected = "retired module reference in package manifest: Package.swift"
                with self.assertRaisesRegex(
                    manifest_gate.ManifestError, re.escape(expected),
                ):
                    manifest_gate.build_manifest(root)

    def test_policy_descriptor_and_implementation_drift_fail(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        expected, _ = self.write_manifest(root)

        with mock.patch.object(manifest_gate, "POLICY_ID", "drifted-policy"):
            actual = manifest_gate.build_manifest(root)
        self.assertIn(
            "discovery policy or policy implementation drifted",
            manifest_gate.comparison_issues(expected, actual),
        )

        implementation = root / manifest_gate.POLICY_IMPLEMENTATION
        implementation.write_bytes(implementation.read_bytes() + b"\n")
        actual = manifest_gate.build_manifest(root)
        self.assertIn(
            "discovery policy or policy implementation drifted",
            manifest_gate.comparison_issues(expected, actual),
        )

    def test_duplicate_noncanonical_and_extra_manifest_data_fail(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        manifest, path = self.write_manifest(root)

        duplicate = json.loads(json.dumps(manifest))
        duplicate["sources"].append(duplicate["sources"][0])
        duplicate["sourceCount"] += 1
        path.write_bytes(manifest_gate.canonical_bytes(duplicate))
        with self.assertRaisesRegex(manifest_gate.ManifestError, "duplicate source path"):
            manifest_gate.load_manifest(path, root)

        path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(manifest_gate.ManifestError, "canonical generated form"):
            manifest_gate.load_manifest(path, root)

        extra = json.loads(json.dumps(manifest))
        extra["approval"] = "approved"
        path.write_bytes(manifest_gate.canonical_bytes(extra))
        with self.assertRaisesRegex(manifest_gate.ManifestError, "unexpected or missing fields"):
            manifest_gate.load_manifest(path, root)

    def test_boolean_values_do_not_pass_integer_validation(self) -> None:
        mutations = (
            (lambda value: value.update(sourceCount=True), "sourceCount"),
            (lambda value: value["sources"][0].update(size=True), "source size"),
            (lambda value: value.update(trustFileCount=True), "trustFileCount"),
            (lambda value: value["trustFiles"][0].update(size=True), "source size"),
        )
        for mutation, expected in mutations:
            with self.subTest(expected=expected):
                temporary, root = self.fixture()
                self.addCleanup(temporary.cleanup)
                manifest, path = self.write_manifest(root)
                malformed = json.loads(json.dumps(manifest))
                mutation(malformed)
                path.write_bytes(manifest_gate.canonical_bytes(malformed))
                with self.assertRaisesRegex(
                    manifest_gate.ManifestError, re.escape(expected),
                ):
                    manifest_gate.load_manifest(path, root)

    def test_cli_rejects_manifest_symlink_components(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        _, manifest = self.write_manifest(root)
        reviewed = root / "reviewed"
        reviewed.mkdir()
        reviewed_manifest = reviewed / "manifest.json"
        reviewed_manifest.write_bytes(manifest.read_bytes())
        linked_parent = root / "linked-parent"
        linked_parent.symlink_to(reviewed, target_is_directory=True)
        linked_leaf = root / "linked-manifest.json"
        linked_leaf.symlink_to(manifest)
        for path, component in (
            (linked_leaf, "linked-manifest.json"),
            (linked_parent / "manifest.json", "linked-parent"),
        ):
            with self.subTest(component=component):
                verify = subprocess.run(
                    [
                        sys.executable, str(SCRIPT), "--root", str(root),
                        "verify", "--manifest", str(path),
                    ],
                    check=False, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
                self.assertEqual(verify.returncode, 2)
                self.assertIn("manifest path contains symlink component", verify.stderr)
                self.assertIn(component, verify.stderr)

    def test_cli_works_without_git_repository_or_historical_refs(self) -> None:
        temporary, root = self.fixture()
        self.addCleanup(temporary.cleanup)
        output = root / "provisional.json"
        generate = subprocess.run(
            [
                sys.executable, str(SCRIPT), "--root", str(root),
                "generate", "--output", str(output),
            ],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(generate.returncode, 0, generate.stderr)
        self.assertIn("reviewState=unreviewed", generate.stdout)
        self.assertFalse((root / ".git").exists())

        verify = subprocess.run(
            [
                sys.executable, str(SCRIPT), "--root", str(root),
                "verify", "--manifest", str(output),
            ],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertIn("ACTIVE_SOURCE_MANIFEST verified", verify.stdout)

        overwrite = subprocess.run(
            [
                sys.executable, str(SCRIPT), "--root", str(root),
                "generate", "--output", str(output),
            ],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(overwrite.returncode, 2)
        self.assertIn("refusing to overwrite", overwrite.stderr)


if __name__ == "__main__":
    unittest.main()
