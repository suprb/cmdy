#!/usr/bin/env python3
"""Focused fail-closed tests for release qualification."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts/check-release-qualification.py"
SPEC = importlib.util.spec_from_file_location("cmdy_release_qualification", CHECKER)
assert SPEC is not None and SPEC.loader is not None
qualification = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = qualification
SPEC.loader.exec_module(qualification)


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class QualificationFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.paths: dict[str, Path] = {}
        self.record: dict[str, object] = {}
        self.record_path = root / "docs/independence/RELEASE_QUALIFICATION.json"
        self._init_git()
        self.engineering = self._engineering()
        self._write("Source/current.swift", b"struct CurrentSource {}\n")
        self._commit("source freeze")
        self.source_commit = self._git("rev-parse", "HEAD")
        self.source_tree = self._git("rev-parse", "HEAD^{tree}")
        self.manifest = self._manifest()
        self.manifest_path = self._write_json(
            "docs/independence/qualification/active-terminal-sources.json",
            self.manifest)
        self.manifest_sha = qualification.sha256_file(self.manifest_path)
        provenance = self._provenance()
        provenance_path = self._write_json(
            "docs/independence/qualification/provenance.json", provenance)
        core_path = self._write_json(
            "docs/independence/qualification/core.json", self._core())
        comparison_path = self._write_json(
            "docs/independence/qualification/renderer-comparison.json",
            self._renderer_comparison())
        environment_path = self._write_json(
            "docs/independence/qualification/renderer-environment.json",
            self._renderer_environment())
        operational_path = self._write_json(
            "docs/independence/qualification/operational.json",
            self._operational())
        source = {
            "activeSourceManifest": self._ref(self.manifest_path),
            "provenanceReport": self._ref(provenance_path),
            "sourceCommit": self.source_commit,
            "sourceTree": self.source_tree,
        }
        evidence = {
            "core": {
                "record": self._ref(core_path),
                "sourceManifestSha256": self.manifest_sha,
            },
            "operational": {
                "record": self._ref(operational_path),
                "sourceManifestSha256": self.manifest_sha,
            },
            "renderer": {
                "checkerSha256": self._binding_hash("renderer-parity-checker"),
                "comparison": self._ref(comparison_path),
                "environment": self._ref(environment_path),
                "sourceManifestSha256": self.manifest_sha,
            },
        }
        approval = {
            "approvalReference": "https://review.example.test/approval/1",
            "approvedPublicWording": "The reviewed terminal stack is independently implemented.",
            "decision": "approved",
            "engineeringDigestSha256": qualification.canonical_digest(self.engineering),
            "evidenceDigestSha256": qualification.canonical_digest({
                "approvedPublicWording": "The reviewed terminal stack is independently implemented.",
                "evidence": evidence,
                "source": source,
            }),
            "reviewedAtUTC": "2026-08-26T12:00:00Z",
            "reviewerAffiliation": "Independent Review Lab",
            "reviewerIndependentFromImplementation": True,
            "reviewerKind": "human",
            "reviewerName": "Fixture Reviewer",
        }
        self.record = {
            "$schema": qualification.EXPECTED_SCHEMA,
            "engineering": self.engineering,
            "kind": "cmdy-release-qualification",
            "publication": {
                "approval": approval,
                "evidence": evidence,
                "source": source,
                "state": "approved",
            },
            "schemaVersion": 1,
        }
        self._write_json(
            "docs/independence/RELEASE_QUALIFICATION.json", self.record)
        self._commit("review approval")

    def _init_git(self) -> None:
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "fixture@example.test"],
            cwd=self.root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Fixture"], cwd=self.root, check=True)

    def _git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=self.root, check=True, capture_output=True,
            text=True).stdout.strip()

    def _commit(self, message: str) -> None:
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", message], cwd=self.root, check=True)

    def _write(self, relative: str, data: bytes) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.paths[relative] = path
        return path

    def _write_json(self, relative: str, value: object) -> Path:
        return self._write(relative, qualification.canonical_bytes(value))

    def _ref(self, path: Path) -> dict[str, str]:
        return {
            "path": path.relative_to(self.root).as_posix(),
            "sha256": qualification.sha256_file(path),
        }

    def _binding_hash(self, purpose: str) -> str:
        return next(
            item["sha256"] for item in self.engineering["bindings"]
            if item["purpose"] == purpose)

    def _engineering(self) -> dict[str, object]:
        payloads: dict[str, bytes] = {
            purpose: f"fixture trust input: {purpose}\n".encode()
            for purpose in qualification.REQUIRED_BINDINGS
        }
        payloads["active-source-checker"] = (
            b"#!/usr/bin/env python3\nraise SystemExit(0)\n")
        payloads["zoo-review-checker"] = (
            b"#!/usr/bin/env python3\n"
            b"import hashlib, pathlib, sys\n"
            b"p=pathlib.Path(sys.argv[sys.argv.index('--manifest')+1])\n"
            b"h=hashlib.sha256(p.read_bytes()).hexdigest()\n"
            b"print(f'ZOO_REVIEW verified decision=approved manifest_sha256={h} captures=13 claude=skipped')\n"
        )
        archive = b"locked renderer corpus\n"
        payloads["renderer-corpus-archive"] = archive
        archive_sha = digest_bytes(archive)
        fixture_index = digest_bytes(b"fixture index")
        manifest_sha = digest_bytes(b"reference manifest")
        lock = {
            "archiveSha256": archive_sha,
            "exceptions": [],
            "fixtureCount": 40,
            "fixtureIndexSha256": fixture_index,
            "humanReviewStatus": "approved",
            "referenceManifestSha256": manifest_sha,
        }
        payloads["renderer-corpus-lock"] = qualification.canonical_bytes(lock)
        vector = {
            "archiveSha256": archive_sha,
            "fixtureIndexSha256": fixture_index,
            "referenceManifestSha256": manifest_sha,
        }
        payloads["renderer-corpus-validator-vector"] = qualification.canonical_bytes(vector)
        bindings = []
        for purpose in sorted(qualification.REQUIRED_BINDINGS):
            suffix = ".py" if purpose in (
                "active-source-checker", "zoo-review-checker") else ".data"
            path = self._write(f"trust/{purpose}{suffix}", payloads[purpose])
            bindings.append({
                "path": path.relative_to(self.root).as_posix(),
                "purpose": purpose,
                "sha256": qualification.sha256_file(path),
            })
        return {
            "bindings": bindings,
            "coreMatrix": {
                "actionsPerCase": 180,
                "casesPerSeed": 3176,
                "randomCasesPerSeed": 2000,
                "seeds": qualification.CORE_SEEDS,
                "totalCases": 53992,
            },
            "rendererCorpus": {
                "archiveSha256": archive_sha,
                "candidateFixtureSha256": self._binding_hash_from(bindings, "renderer-fixture"),
                "fixtureCount": 40,
                "fixtureIndexSha256": fixture_index,
                "lockSha256": self._binding_hash_from(bindings, "renderer-corpus-lock"),
                "referenceManifestSha256": manifest_sha,
                "validatorVectorSha256": self._binding_hash_from(
                    bindings, "renderer-corpus-validator-vector"),
            },
        }

    @staticmethod
    def _binding_hash_from(bindings: list[dict[str, str]], purpose: str) -> str:
        return next(item["sha256"] for item in bindings if item["purpose"] == purpose)

    def _manifest(self) -> dict[str, object]:
        source = self.root / "Source/current.swift"
        return {
            "reviewState": "unreviewed",
            "sourceCount": 1,
            "sources": [{
                "mode": "100644",
                "path": "Source/current.swift",
                "sha256": qualification.sha256_file(source),
                "size": source.stat().st_size,
            }],
            "trustFileCount": 0,
            "trustFiles": [],
        }

    def _provenance(self) -> dict[str, object]:
        report: dict[str, object] = {
            "activeSources": [{
                "path": "Source/current.swift",
                "sha256": qualification.sha256_file(self.root / "Source/current.swift"),
            }],
            "issues": [],
            "matches": [],
            "references": {},
            "schemaVersion": 2,
            "summary": {
                "activeSourceCount": 1,
                "classifiedMatchCount": 0,
                "issueCount": 0,
                "matchCount": 0,
                "ok": True,
                "unresolvedMatchCount": 0,
            },
            "thresholds": {},
        }
        report["reportSHA256"] = digest_bytes(json.dumps(
            report, sort_keys=True, separators=(",", ":")).encode())
        return report

    def _core(self) -> dict[str, object]:
        return {
            "actionsPerCase": 180,
            "candidateLibrarySha256": digest_bytes(b"candidate core"),
            "checkerSha256": self._binding_hash("core-parity-checker"),
            "exceptions": [],
            "failedCases": 0,
            "kind": "cmdy-core-parity-matrix",
            "randomCasesPerSeed": 2000,
            "referenceLibrarySha256": digest_bytes(b"reference core"),
            "schemaVersion": 1,
            "seedResults": [{
                "cases": 3176,
                "passed": True,
                "seed": seed,
                "snapshotSha256": digest_bytes(f"seed:{seed}".encode()),
            } for seed in qualification.CORE_SEEDS],
            "sourceManifestSha256": self.manifest_sha,
            "totalCases": 53992,
        }

    def _renderer_comparison(self) -> dict[str, object]:
        comparisons = []
        for index in range(40):
            pixel = digest_bytes(f"pixel:{index}".encode())
            public = digest_bytes(f"public:{index}".encode())
            width = 10 * (1 if index < 20 else 2)
            height = 8 * (1 if index < 20 else 2)
            comparisons.append({
                "candidatePNGSha256": pixel,
                "candidatePublicInputSha256": public,
                "candidateRawRGBASha256": pixel,
                "differingChannels": 0,
                "differingPixelBoundingBox": None,
                "differingPixels": 0,
                "exactDeltaRGBA": f"diff/{index}.rgba",
                "exactDeltaRGBASha256": digest_bytes(f"delta:{index}".encode()),
                "height": height,
                "maximumChannelDelta": 0,
                "name": f"fixture-{index % 20}",
                "publicInputMismatchCount": 0,
                "publicInputMismatches": [],
                "publicInputsByteIdentical": True,
                "referencePNGSha256": pixel,
                "referencePublicInputSha256": public,
                "referenceRawRGBASha256": pixel,
                "scale": 1 if index < 20 else 2,
                "totalAbsoluteChannelDelta": 0,
                "totalPixels": width * height,
                "visualDiffPNG": f"diff/{index}.png",
                "visualDiffPNGSha256": digest_bytes(f"visual:{index}".encode()),
                "width": width,
            })
        policy = self.engineering["rendererCorpus"]
        return {
            "candidateFixtureIndexSha256": policy["fixtureIndexSha256"],
            "candidateManifestSha256": digest_bytes(b"candidate manifest"),
            "comparisons": comparisons,
            "contract": "docs/independence/CMDYGPU_CONTRACT.md#13",
            "exceptions": [],
            "failedFixtureCount": 0,
            "fixtureCount": 40,
            "fixtureIndexesByteIdentical": True,
            "passed": True,
            "pixelFailedFixtureCount": 0,
            "publicInputFailedFixtureCount": 0,
            "referenceFixtureIndexSha256": policy["fixtureIndexSha256"],
            "referenceManifestLocked": True,
            "referenceManifestSha256": policy["referenceManifestSha256"],
            "rule": "byte-identical public inputs and zero differing pixels; no implicit tolerance or exceptions",
            "schemaVersion": 2,
            "totalDifferingPixels": 0,
        }

    def _renderer_environment(self) -> dict[str, object]:
        policy = self.engineering["rendererCorpus"]
        return {
            "candidate": {
                "kind": "build",
                "moduleSha256": digest_bytes(b"module"),
                "objectSetSha256": digest_bytes(b"objects"),
                "releaseBuild": "/isolated/candidate",
            },
            "fixtureSourceSha256": policy["candidateFixtureSha256"],
            "macOS": "fixture macOS",
            "machine": "arm64",
            "reference": {
                "archive": "/isolated/reference.tar.gz",
                "archiveBytes": 22,
                "archiveSha256": policy["archiveSha256"],
                "corpusID": "fixture-corpus",
                "fixtureIndexSha256": policy["fixtureIndexSha256"],
                "kind": "locked-captures",
                "lock": "/isolated/reference.lock.json",
                "lockSha256": policy["lockSha256"],
                "manifestSha256": policy["referenceManifestSha256"],
                "payloadSetSha256": digest_bytes(b"payload set"),
                "uncompressedTarSha256": digest_bytes(b"tar"),
                "validatorVector": "/isolated/vector.json",
                "validatorVectorSha256": policy["validatorVectorSha256"],
            },
            "schemaVersion": 2,
            "swiftCompiler": "fixture Swift",
            "system": "Darwin",
            "xcode": "fixture Xcode",
        }

    def _operational(self) -> dict[str, object]:
        normal = self._write("docs/independence/qualification/perf-normal.log", b"passed\n")
        maximized = self._write("docs/independence/qualification/perf-max.log", b"passed\n")
        resource = self._write("docs/independence/qualification/resource.log", b"stable\n")
        captures = self._write("docs/independence/qualification/zoo.json", b"{}\n")
        review = self._write("docs/independence/qualification/zoo-review.json", b"{}\n")
        perf_hash = self._binding_hash("performance-gate")
        return {
            "kind": "cmdy-operational-qualification-review",
            "performance": [{
                "exceptions": [],
                "log": self._ref(normal),
                "mode": "normal",
                "passed": True,
                "scriptSha256": perf_hash,
            }, {
                "exceptions": [],
                "log": self._ref(maximized),
                "mode": "maximized",
                "passed": True,
                "scriptSha256": perf_hash,
            }],
            "resourcePlateau": {
                "exceptions": [],
                "log": self._ref(resource),
                "monotonicGrowth": False,
                "passed": True,
                "runs": 3,
                "scriptSha256": self._binding_hash("resource-stress-gate"),
                "zombieCount": 0,
            },
            "review": {
                "decision": "approved",
                "reference": "https://review.example.test/operational/1",
                "reviewedAtUTC": "2026-08-26T11:00:00Z",
                "reviewerName": "Visual Reviewer",
            },
            "schemaVersion": 1,
            "sourceManifestSha256": self.manifest_sha,
            "zoo": {
                "captureCount": 13,
                "captureManifest": self._ref(captures),
                "exceptions": [],
                "passed": True,
                "scriptSha256": self._binding_hash("tui-zoo-gate"),
                "visualReview": self._ref(review),
            },
        }


class ReleaseQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cmdy-qualification-test-")
        self.fixture = QualificationFixture(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_approved_fixture_passes_publication_source(self) -> None:
        record, path = qualification.load_record(
            self.fixture.root, self.fixture.record_path)
        state = qualification.validate_engineering(record, self.fixture.root)
        result = qualification.verify_publication_source(
            record, path, self.fixture.root, state)
        self.assertEqual(result["sourceCommit"], self.fixture.source_commit)
        self.assertEqual(result["sourceManifestSha256"], self.fixture.manifest_sha)

    def test_unbound_descendant_source_change_fails(self) -> None:
        self.fixture._write(
            "Native/Injected.mm", b"void post_review_native_change(void) {}\n")
        self.fixture._commit("unreviewed native drift")
        record, path = qualification.load_record(
            self.fixture.root, self.fixture.record_path)
        state = qualification.validate_engineering(record, self.fixture.root)
        with self.assertRaisesRegex(
                qualification.QualificationError,
                "outside the exact approved evidence set"):
            qualification.verify_publication_source(
                record, path, self.fixture.root, state)

    def test_unreferenced_qualification_file_fails(self) -> None:
        self.fixture._write(
            "docs/independence/qualification/unbound.json", b"{}\n")
        self.fixture._commit("unreferenced evidence drift")
        record, path = qualification.load_record(
            self.fixture.root, self.fixture.record_path)
        state = qualification.validate_engineering(record, self.fixture.root)
        with self.assertRaisesRegex(
                qualification.QualificationError,
                "outside the exact approved evidence set"):
            qualification.verify_publication_source(
                record, path, self.fixture.root, state)

    def test_engineering_binding_drift_fails(self) -> None:
        bound = self.fixture.root / self.fixture.engineering["bindings"][0]["path"]
        bound.write_bytes(bound.read_bytes() + b"drift")
        with self.assertRaisesRegex(qualification.QualificationError, "hash mismatch"):
            qualification.validate_engineering(self.fixture.record, self.fixture.root)

    def test_pending_publication_fails(self) -> None:
        record = copy.deepcopy(self.fixture.record)
        record["publication"] = {
            "approval": None, "evidence": None, "source": None, "state": "pending",
        }
        state = qualification.validate_engineering(record, self.fixture.root)
        with self.assertRaisesRegex(qualification.QualificationError, "publication is pending"):
            qualification.verify_publication_source(
                record, self.fixture.record_path, self.fixture.root, state,
                require_clean=False, run_manifest_checker=False)

    def test_non_independent_approval_fails(self) -> None:
        record = copy.deepcopy(self.fixture.record)
        record["publication"]["approval"]["reviewerIndependentFromImplementation"] = False
        state = qualification.validate_engineering(record, self.fixture.root)
        with self.assertRaisesRegex(qualification.QualificationError, "must be true"):
            qualification.verify_publication_source(
                record, self.fixture.record_path, self.fixture.root, state,
                require_clean=False, run_manifest_checker=False)

    def test_core_seed_omission_fails(self) -> None:
        record_path = self.fixture.root / "docs/independence/qualification/core.json"
        record = json.loads(record_path.read_text())
        record["seedResults"] = record["seedResults"][:-1]
        record_path.write_bytes(qualification.canonical_bytes(record))
        wrapper = {
            "record": self.fixture._ref(record_path),
            "sourceManifestSha256": self.fixture.manifest_sha,
        }
        with self.assertRaisesRegex(qualification.QualificationError, "seed list"):
            qualification.validate_core_evidence(
                self.fixture.root, wrapper, self.fixture.manifest_sha,
                self.fixture.engineering)

    def test_renderer_exception_fails(self) -> None:
        path = self.fixture.root / "docs/independence/qualification/renderer-comparison.json"
        comparison = json.loads(path.read_text())
        comparison["exceptions"] = ["cursor"]
        path.write_bytes(qualification.canonical_bytes(comparison))
        wrapper = copy.deepcopy(self.fixture.record["publication"]["evidence"]["renderer"])
        wrapper["comparison"] = self.fixture._ref(path)
        with self.assertRaisesRegex(qualification.QualificationError, "exceptions"):
            qualification.validate_renderer_evidence(
                self.fixture.root, wrapper, self.fixture.manifest_sha,
                self.fixture.engineering)

    def test_unreviewed_operational_evidence_fails(self) -> None:
        path = self.fixture.root / "docs/independence/qualification/operational.json"
        operational = json.loads(path.read_text())
        operational["review"]["decision"] = "pending"
        path.write_bytes(qualification.canonical_bytes(operational))
        wrapper = {
            "record": self.fixture._ref(path),
            "sourceManifestSha256": self.fixture.manifest_sha,
        }
        with self.assertRaisesRegex(qualification.QualificationError, "not been approved"):
            qualification.validate_operational_evidence(
                self.fixture.root, wrapper, self.fixture.manifest_sha,
                self.fixture.engineering)

    def test_rejected_notary_result_fails(self) -> None:
        receipt = self.fixture._write_json("receipt.json", {
            "id": "12345678-1234-1234-1234-123456789abc",
            "status": "Rejected",
        })
        with self.assertRaisesRegex(qualification.QualificationError, "Accepted"):
            qualification.parse_notary_receipt(receipt, "fixture receipt")

    def test_artifact_fixture_passes_and_distinguishes_submitted_bytes(self) -> None:
        app = self.fixture.root / "cmdy.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.cmdy.app",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        }))
        identity = self.fixture.root / "Identity/Sources/ProductIdentity/Resources/product-identity.json"
        identity.parent.mkdir(parents=True, exist_ok=True)
        identity.write_bytes(qualification.canonical_bytes({
            "bundleIdentifier": "com.cmdy.app",
        }))
        archive = self.fixture._write("dist/cmdy.zip", b"final archive")
        dmg = self.fixture._write("dist/cmdy.dmg", b"final dmg")
        archive_checksum = self.fixture._write(
            "dist/cmdy.zip.sha256",
            f"{qualification.sha256_file(archive)}  {archive}\n".encode())
        dmg_checksum = self.fixture._write(
            "dist/cmdy.dmg.sha256",
            f"{qualification.sha256_file(dmg)}  {dmg}\n".encode())
        receipt_payload = {
            "id": "12345678-1234-1234-1234-123456789abc",
            "status": "Accepted",
        }
        archive_receipt = self.fixture._write_json("archive-notary.json", receipt_payload)
        dmg_receipt = self.fixture._write_json("dmg-notary.json", receipt_payload)
        output = self.fixture.root / "dist/package.qualification.json"
        result = qualification.verify_artifacts(
            {"sourceCommit": "a" * 40}, self.fixture.record_path,
            self.fixture.root, app=app, archive=archive,
            archive_checksum=archive_checksum, archive_receipt=archive_receipt,
            archive_submitted_sha256=digest_bytes(b"submitted archive"),
            dmg=dmg, dmg_checksum=dmg_checksum, dmg_receipt=dmg_receipt,
            dmg_submitted_sha256=digest_bytes(b"submitted dmg"),
            version="1.2.3", build="42", variant="lean", output=output,
            assessor=lambda _app, _dmg: {
                "teamIdentifier": "ABCDEFGHIJ", "cdHash": "abc123",
            })
        self.assertNotEqual(
            result["artifacts"]["dmg"]["submittedSha256"],
            result["artifacts"]["dmg"]["finalSha256"])
        self.assertTrue(output.is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
