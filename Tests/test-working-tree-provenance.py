#!/usr/bin/env python3
"""Focused tests for scripts/check-working-tree-provenance.py."""

from __future__ import annotations

import contextlib
import dataclasses
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).resolve().parent.parent
SCRIPT = REPOSITORY / "scripts/check-working-tree-provenance.py"
SPEC = importlib.util.spec_from_file_location("working_tree_provenance", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
gate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = gate
SPEC.loader.exec_module(gate)

ACTIVE_SCRIPT = REPOSITORY / "scripts/check-active-source-manifest.py"
ACTIVE_SPEC = importlib.util.spec_from_file_location(
    "active_source_manifest_for_provenance_test", ACTIVE_SCRIPT,
)
assert ACTIVE_SPEC is not None and ACTIVE_SPEC.loader is not None
active_gate = importlib.util.module_from_spec(ACTIVE_SPEC)
sys.modules[ACTIVE_SPEC.name] = active_gate
ACTIVE_SPEC.loader.exec_module(active_gate)


def document(path: str, text: str):
    raw = text.encode()
    return gate.Document(path, text, gate.sha256_bytes(raw))


class WorkingTreeProvenanceTests(unittest.TestCase):
    def test_active_source_policy_matches_release_manifest_gate(self) -> None:
        self.assertEqual(gate.SOURCE_SUFFIXES, active_gate.SOURCE_SUFFIXES)
        self.assertEqual(gate.ACTIVE_ROOTS, active_gate.ACTIVE_ROOTS)
        self.assertEqual(gate.REQUIRED_APP_SEAM, active_gate.REQUIRED_APP_SOURCES)
        self.assertEqual(gate.SOURCE_PARENTS, active_gate.SOURCE_PARENTS)
        self.assertEqual(gate.RETIRED_ROOTS, active_gate.RETIRED_ROOTS)
        self.assertEqual(gate.RETIRED_APP_GLOBS, active_gate.RETIRED_APP_GLOBS)
        self.assertEqual(
            gate.RETIRED_MODULE_PATTERN, active_gate.RETIRED_MODULE_PATTERN,
        )
        self.assertEqual(gate.IMPORT_SCAN_ROOTS, active_gate.IMPORT_SCAN_ROOTS)
        self.assertEqual(gate.PACKAGE_MANIFESTS, active_gate.PACKAGE_MANIFESTS)

        provenance_sources, provenance_issues = gate.discover_active_sources(
            REPOSITORY,
        )
        manifest_sources, manifest_issues = active_gate.discover_active_sources(
            REPOSITORY,
        )
        self.assertEqual(provenance_issues, [])
        self.assertEqual(manifest_issues, [])
        self.assertEqual(
            [source.path for source in provenance_sources],
            [path.relative_to(REPOSITORY).as_posix() for path in manifest_sources],
        )

    def test_exact_and_identifier_normalized_matches_are_detected(self) -> None:
        historical_text = """
        func transform(source: Int, limit: Int) -> Int {
            var result = source
            if result < limit { result += 1 }
            while result < limit { result += 2 }
            return result
        }
        """
        exact = gate.find_matches(
            [document("Active.swift", historical_text)],
            [document("Historical.swift", historical_text)],
            "vendor", "exact", 12,
        )
        self.assertEqual(len(exact), 1)
        self.assertGreaterEqual(exact[0].token_count, 12)

        renamed = historical_text.replace("transform", "advance") \
            .replace("source", "origin").replace("limit", "boundary") \
            .replace("result", "cursor")
        structural = gate.find_matches(
            [document("Active.swift", renamed)],
            [document("Historical.swift", historical_text)],
            "retired", "structural", 12,
        )
        self.assertEqual(len(structural), 1)
        self.assertGreaterEqual(structural[0].token_count, 12)

    def test_short_platform_idiom_stays_below_threshold(self) -> None:
        snippet = "let descriptor = MTLRenderPipelineDescriptor()"
        matches = gate.find_matches(
            [document("Active.swift", snippet)],
            [document("Historical.swift", snippet)],
            "vendor", "exact", gate.EXACT_TOKEN_THRESHOLD,
        )
        self.assertEqual(matches, [])

    def test_discovery_includes_untracked_app_seam_and_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative_root, suffixes in gate.ACTIVE_ROOTS:
                directory = root / relative_root
                directory.mkdir(parents=True)
                (directory / ("Source" + suffixes[0])).write_text(
                    "public struct Source {}")
            app = root / "App"
            app.mkdir()
            for relative in gate.REQUIRED_APP_SEAM:
                path = root / relative
                path.write_text("final class Placeholder {}")
            untracked = app / "NewRendererSeam.swift"
            untracked.write_text("struct NewRendererSeam {}")
            nested = app / "Nested/IndirectSeam.swift"
            nested.parent.mkdir()
            nested.write_text("struct IndirectSeam {}")

            active, issues = gate.discover_active_sources(root)
            self.assertEqual(issues, [])
            self.assertIn("App/NewRendererSeam.swift", {item.path for item in active})
            self.assertIn("App/Nested/IndirectSeam.swift", {item.path for item in active})

            injected = root / "Core/Sources/CmdyPTYShim/Injected.cpp"
            injected.write_text("void injected() {}")
            _, issues = gate.discover_active_sources(root)
            self.assertIn(
                "unapproved source suffix in governed source tree: "
                "Core/Sources/CmdyPTYShim/Injected.cpp",
                issues,
            )
            injected.unlink()

            (root / "Core/Sources/CmdyPTY/Source.swift").unlink()
            _, issues = gate.discover_active_sources(root)
            self.assertIn(
                "active source root has no source files: Core/Sources/CmdyPTY",
                issues,
            )

            uncovered = root / "Core/Sources/CmdyNew/New.swift"
            uncovered.parent.mkdir()
            uncovered.write_text("struct NewSourceRoot {}")
            _, issues = gate.discover_active_sources(root)
            self.assertIn(
                "uncovered active source root: Core/Sources/CmdyNew", issues)

    def test_retired_source_and_module_import_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            retired = root / "Core/Sources/TermiteCore/Old.swift"
            retired.parent.mkdir(parents=True)
            retired.write_text("struct Old {}")
            for manifest in gate.PACKAGE_MANIFESTS:
                path = root / manifest
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// SwiftTerm is mentioned only in a comment\n")
            active = [
                document("App/Seam.swift", "import SwiftTerm\n"),
                document("App/Comment.swift", "/*\nimport TermiteCore\n*/\n"),
            ]
            hidden = root / "App/Hidden.swift"
            hidden.parent.mkdir(parents=True, exist_ok=True)
            hidden.write_text("import TermiteGPU\n")
            issues = gate.retired_source_issues(root, active)
            self.assertIn(
                "retired source remains active: Core/Sources/TermiteCore/Old.swift",
                issues,
            )
            self.assertIn("retired module import in App/Seam.swift: SwiftTerm", issues)
            self.assertIn("retired module import in App/Hidden.swift: TermiteGPU", issues)
            self.assertFalse(any("App/Comment.swift" in issue for issue in issues))
            self.assertFalse(any("package manifest" in issue for issue in issues))

            package = root / "Core/Package.swift"
            package.write_text(
                'let dependency = .package(\n'
                '    url: "https://example.invalid/SwiftTerm.git",\n'
                '    from: "1.0.0"\n'
                ')\n'
            )
            issues = gate.retired_source_issues(root, active)
            self.assertIn(
                "retired module reference in package manifest: Core/Package.swift",
                issues,
            )

    def test_allowlist_is_exact_and_stale_entries_fail(self) -> None:
        match = gate.Match(
            origin="vendor", mode="exact", active_path="Active.swift",
            active_start=1, active_end=3, historical_path="Historical.swift",
            historical_start=4, historical_end=6, token_count=40,
            fingerprint="a" * 64,
        )
        active = [document("Active.swift", "struct Active {}")]
        allowed = {
            "schemaVersion": 1,
            "matches": [{
                "id": "public-declaration",
                "origin": "vendor",
                "mode": "exact",
                "active": "Active.swift",
                "historical": "Historical.swift",
                "fingerprint": "a" * 64,
                "classification": "api-declaration",
                "rationale": "Frozen declaration only.",
            }],
            "reviewedRetainedSources": [],
        }
        classified, issues = gate.classify_matches([match], active, allowed)
        self.assertEqual(issues, [])
        self.assertEqual(classified[0].disposition, "api-declaration")

        changed = dataclasses.replace(match, fingerprint="b" * 64)
        classified, issues = gate.classify_matches([changed], active, allowed)
        self.assertEqual(classified[0].disposition, "unresolved")
        self.assertIn("stale allowlist match: public-declaration", issues)

        grouped = dict(allowed)
        grouped["matches"] = [{
            key: value for key, value in allowed["matches"][0].items()
            if key != "fingerprint"
        }]
        grouped["matches"][0]["fingerprints"] = ["a" * 64, "b" * 64]
        classified, issues = gate.classify_matches([match, changed], active, grouped)
        self.assertEqual(issues, [])
        self.assertEqual(
            [item.disposition for item in classified],
            ["api-declaration", "api-declaration"],
        )

    def test_complete_report_is_deterministic_on_untracked_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.run_git(root, "init", "-q")
            self.run_git(root, "config", "user.email", "gate@example.invalid")
            self.run_git(root, "config", "user.name", "Gate Test")

            vendor = root / "Vendor/SwiftTerm/Reference.swift"
            vendor.parent.mkdir(parents=True)
            vendor.write_text("func vendorOnly() { print(1) }")
            self.run_git(root, "add", ".")
            self.run_git(root, "commit", "-qm", "vendor")
            vendor_ref = self.run_git(root, "rev-parse", "HEAD").strip()
            vendor.unlink()
            vendor.parent.rmdir()

            retired = root / "Core/Sources/TermiteCore/Old.swift"
            retired.parent.mkdir(parents=True)
            retired.write_text("func retiredOnly() { print(2) }")
            self.run_git(root, "add", ".")
            self.run_git(root, "commit", "-qm", "retired")
            retired_ref = self.run_git(root, "rev-parse", "HEAD").strip()
            retired.unlink()
            retired.parent.rmdir()

            for relative_root, suffixes in gate.ACTIVE_ROOTS:
                directory = root / relative_root
                directory.mkdir(parents=True, exist_ok=True)
                (directory / ("Active" + suffixes[0])).write_text(
                    "public struct Active {}")
            app = root / "App"
            app.mkdir(exist_ok=True)
            for relative in gate.REQUIRED_APP_SEAM:
                path = root / relative
                path.write_text("final class SeamValue {}")
            for manifest in gate.PACKAGE_MANIFESTS:
                path = root / manifest
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// package fixture\n")
            allowlist = root / "allowlist.json"
            allowlist.write_text(json.dumps({
                "schemaVersion": 1,
                "matches": [],
                "reviewedRetainedSources": [],
            }))

            first = gate.build_report(root, vendor_ref, retired_ref, allowlist)
            second = gate.build_report(root, vendor_ref, retired_ref, allowlist)
            self.assertEqual(first, second)
            self.assertTrue(first["summary"]["ok"])
            self.assertGreaterEqual(first["summary"]["activeSourceCount"], 12)

    def test_check_fails_but_report_succeeds_for_unresolved_findings(self) -> None:
        report = {
            "summary": {
                "activeSourceCount": 1,
                "matchCount": 1,
                "classifiedMatchCount": 0,
                "unresolvedMatchCount": 1,
                "issueCount": 0,
                "ok": False,
            },
            "issues": [],
            "matches": [],
            "reportSHA256": "fixture",
        }
        with mock.patch.object(gate, "build_report", return_value=report):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(["--mode", "check"]), 1)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(["--mode", "report"]), 0)

    @staticmethod
    def run_git(root: Path, *arguments: str) -> str:
        return subprocess.check_output(
            ["git", *arguments], cwd=root, text=True,
            stderr=subprocess.STDOUT,
        )


if __name__ == "__main__":
    unittest.main()
