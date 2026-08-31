#!/usr/bin/env python3
"""Focused fail-closed tests for check-zoo-review.py."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parent.parent
SCRIPT = REPOSITORY / "scripts/check-zoo-review.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


zoo_review = load_module("check_zoo_review", SCRIPT)


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def valid_png(width: int = 2, height: int = 2) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raw = b"".join(
        b"\x00" + bytes((row, 20, 30, 255)) * width
        for row in range(height)
    )
    return (
        zoo_review.PNG_SIGNATURE
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(raw))
        + png_chunk(b"IEND", b"")
    )


class ZooReviewTests(unittest.TestCase):
    def fixture(
        self, claude_status: str = "skipped",
    ) -> tuple[tempfile.TemporaryDirectory[str], Path, Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        captures = root / "captures"
        captures.mkdir()
        station_ids = list(zoo_review.REQUIRED_STATION_IDS)
        if claude_status == "present":
            station_ids.insert(-1, zoo_review.CLAUDE_STATION_ID)
        for index, station_id in enumerate(station_ids):
            (captures / f"{station_id}.png").write_bytes(
                valid_png(width=2 + index % 3, height=2 + index % 2)
            )
        app = root / "cmdy"
        app.write_bytes(b"packaged cmdy executable\n")
        app.chmod(0o755)
        return temporary, captures, app

    def manifest(
        self, captures: Path, app: Path, status: str = "skipped",
    ) -> dict[str, object]:
        return zoo_review.build_capture_manifest(
            captures,
            app,
            status,
            "command-unavailable" if status == "skipped" else None,
        )

    def write_manifest(
        self, root: Path, manifest: dict[str, object], name: str = "capture.json",
    ) -> Path:
        path = root / name
        path.write_bytes(zoo_review.canonical_bytes(manifest))
        return path

    def write_review(
        self,
        root: Path,
        manifest_path: Path,
        decision: str,
        *,
        notes: str | None = None,
        manifest_hash: str | None = None,
    ) -> Path:
        record: dict[str, object] = {
            "decision": decision,
            "kind": zoo_review.REVIEW_KIND,
            "manifestSHA256": manifest_hash or hashlib.sha256(
                manifest_path.read_bytes()
            ).hexdigest(),
            "reviewedAt": "2026-08-26T18:30:00Z",
            "reviewer": "Human Reviewer <reviewer@example.test>",
            "schemaVersion": zoo_review.REVIEW_SCHEMA_VERSION,
        }
        if notes is not None:
            record["notes"] = notes
        path = root / f"review-{decision}.json"
        path.write_text(json.dumps(record), encoding="utf-8")
        return path

    def test_skipped_manifest_is_deterministic_and_binds_every_file(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        first = self.manifest(captures, app)
        second = self.manifest(captures, app)
        self.assertEqual(first, second)
        zoo_review.validate_capture_manifest(first)
        self.assertEqual(first["captureCount"], 13)
        self.assertEqual(first["claude"], {
            "reason": "command-unavailable",
            "stationID": "12-claude-code",
            "status": "skipped",
        })
        self.assertEqual(
            [entry["stationID"] for entry in first["captures"]],
            list(zoo_review.REQUIRED_STATION_IDS),
        )
        for entry in first["captures"]:
            payload = (captures / entry["file"]).read_bytes()
            self.assertEqual(entry["size"], len(payload))
            self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertGreater(entry["width"], 0)
            self.assertGreater(entry["height"], 0)
        self.assertEqual(first["appBinary"]["size"], app.stat().st_size)
        self.assertEqual(
            first["appBinary"]["sha256"], hashlib.sha256(app.read_bytes()).hexdigest(),
        )

    def test_present_claude_is_explicit_and_ordered_before_final_shell(self) -> None:
        temporary, captures, app = self.fixture("present")
        self.addCleanup(temporary.cleanup)
        manifest = self.manifest(captures, app, "present")
        self.assertEqual(manifest["captureCount"], 14)
        self.assertEqual(manifest["claude"], {
            "stationID": "12-claude-code", "status": "present",
        })
        ids = [entry["stationID"] for entry in manifest["captures"]]
        self.assertEqual(ids[-2:], ["12-claude-code", "99-shell-after"])

    def test_missing_extra_and_inconsistent_claude_captures_fail(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        missing = captures / "04-man.png"
        missing.unlink()
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "missing=.*04-man"):
            self.manifest(captures, app)
        missing.write_bytes(valid_png())
        (captures / "unexpected.png").write_bytes(valid_png())
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "extra=.*unexpected"):
            self.manifest(captures, app)
        (captures / "unexpected.png").unlink()
        (captures / "12-claude-code.png").write_bytes(valid_png())
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "extra=.*12-claude-code"):
            self.manifest(captures, app)
        (captures / "12-claude-code.png").unlink()
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "missing=.*12-claude-code"):
            self.manifest(captures, app, "present")

    def test_png_parser_rejects_fake_corrupt_and_trailing_data(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "capture.png"
        mutations = {
            "signature": b"not-a-png",
            "CRC": valid_png()[:-5] + b"x" + valid_png()[-4:],
            "truncated": valid_png()[:-3],
            "after IEND": valid_png() + b"trailing",
        }
        for label, payload in mutations.items():
            with self.subTest(label=label):
                path.write_bytes(payload)
                with self.assertRaises(zoo_review.ZooEvidenceError):
                    zoo_review.validate_png(path)

    def test_png_parser_rejects_bad_dimensions_stream_and_filter(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "capture.png"
        bad_dimensions = (
            zoo_review.PNG_SIGNATURE
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 0, 1, 8, 6, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(b"\x00"))
            + png_chunk(b"IEND", b"")
        )
        two_by_two_ihdr = struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0)
        bad_stream = (
            zoo_review.PNG_SIGNATURE
            + png_chunk(b"IHDR", two_by_two_ihdr)
            + png_chunk(b"IDAT", zlib.compress(b"short"))
            + png_chunk(b"IEND", b"")
        )
        ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
        bad_filter = (
            zoo_review.PNG_SIGNATURE
            + png_chunk(b"IHDR", ihdr)
            + png_chunk(b"IDAT", zlib.compress(b"\x05\x00\x00\x00\xff"))
            + png_chunk(b"IEND", b"")
        )
        for label, payload in (
            ("dimensions", bad_dimensions),
            ("stream", bad_stream),
            ("filter", bad_filter),
        ):
            with self.subTest(label=label):
                path.write_bytes(payload)
                with self.assertRaises(zoo_review.ZooEvidenceError):
                    zoo_review.validate_png(path)

    def test_symlinked_capture_and_non_executable_or_symlinked_app_fail(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        original = captures / "04-man.png"
        target = Path(temporary.name) / "real-man.png"
        original.rename(target)
        original.symlink_to(target)
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "non-symlink"):
            self.manifest(captures, app)
        original.unlink()
        target.rename(original)
        app.chmod(0o644)
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "not executable"):
            self.manifest(captures, app)
        app.chmod(0o755)
        target_app = app.with_name("real-cmdy")
        app.rename(target_app)
        app.symlink_to(target_app)
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "non-symlink"):
            self.manifest(captures, app)

    def test_prelaunch_app_hash_rejects_binary_drift(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        prelaunch_hash = hashlib.sha256(app.read_bytes()).hexdigest()
        zoo_review.build_capture_manifest(
            captures, app, "skipped", "command-unavailable", prelaunch_hash,
        )
        app.write_bytes(b"concurrent rebuild bytes\n")
        app.chmod(0o755)
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "changed after"):
            zoo_review.build_capture_manifest(
                captures, app, "skipped", "command-unavailable", prelaunch_hash,
            )

    def test_manifest_policy_is_fail_closed(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        manifest = self.manifest(captures, app)
        mutations: list[tuple[str, object]] = []
        missing_policy = copy.deepcopy(manifest)
        missing_policy["requiredStationIDs"].remove("04-man")
        mutations.append(("mandatory", missing_policy))
        bool_size = copy.deepcopy(manifest)
        bool_size["captures"][0]["size"] = True
        mutations.append(("positive integer", bool_size))
        reordered = copy.deepcopy(manifest)
        reordered["captures"][0], reordered["captures"][1] = (
            reordered["captures"][1], reordered["captures"][0]
        )
        mutations.append(("order/coverage", reordered))
        extra_field = copy.deepcopy(manifest)
        extra_field["selfApproved"] = True
        mutations.append(("fields differ", extra_field))
        for expected, mutation in mutations:
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(zoo_review.ZooEvidenceError, expected):
                    zoo_review.validate_capture_manifest(mutation)

    def test_all_human_decisions_bind_exact_manifest_bytes(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        manifest_path = self.write_manifest(root, self.manifest(captures, app))
        for decision, notes in (
            ("approved", None),
            ("pending", None),
            ("rejected", "04-man is visibly clipped"),
        ):
            with self.subTest(decision=decision):
                review_path = self.write_review(
                    root, manifest_path, decision, notes=notes,
                )
                actual, digest, count, claude = zoo_review.verify_review(
                    manifest_path, review_path,
                )
                self.assertEqual(actual, decision)
                self.assertEqual(digest, hashlib.sha256(
                    manifest_path.read_bytes()
                ).hexdigest())
                self.assertEqual(count, 13)
                self.assertEqual(claude, "skipped")

    def test_required_approved_decision_rejects_pending_and_rejected(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        manifest_path = self.write_manifest(root, self.manifest(captures, app))
        approved = self.write_review(root, manifest_path, "approved")
        zoo_review.verify_review(manifest_path, approved, "approved")
        for decision, notes in (
            ("pending", None), ("rejected", "terminal is corrupt"),
        ):
            review_path = self.write_review(
                root, manifest_path, decision, notes=notes,
            )
            with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "required approved"):
                zoo_review.verify_review(manifest_path, review_path, "approved")

    def test_review_hash_identity_and_human_fields_fail_closed(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        manifest_path = self.write_manifest(root, self.manifest(captures, app))
        wrong_hash = self.write_review(
            root, manifest_path, "pending", manifest_hash="0" * 64,
        )
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "exact capture"):
            zoo_review.verify_review(manifest_path, wrong_hash)

        cases = (
            ("reviewer", ""),
            ("reviewedAt", "not-a-date"),
            ("decision", "self-approved"),
        )
        for field, value in cases:
            review_path = self.write_review(root, manifest_path, "pending")
            record = json.loads(review_path.read_text(encoding="utf-8"))
            record[field] = value
            review_path.write_text(json.dumps(record), encoding="utf-8")
            with self.subTest(field=field):
                with self.assertRaises(zoo_review.ZooEvidenceError):
                    zoo_review.verify_review(manifest_path, review_path)
        rejected = self.write_review(root, manifest_path, "rejected", notes="")
        with self.assertRaisesRegex(zoo_review.ZooEvidenceError, "requires nonempty notes"):
            zoo_review.verify_review(manifest_path, rejected)

    def test_cli_round_trip_and_no_review_creation(self) -> None:
        temporary, captures, app = self.fixture()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        manifest_path = root / "evidence" / "capture-manifest.json"
        completed = subprocess.run(
            [
                sys.executable, "-B", str(SCRIPT), "capture-manifest",
                "--captures", str(captures),
                "--app-binary", str(app),
                "--expected-app-sha256", hashlib.sha256(
                    app.read_bytes()
                ).hexdigest(),
                "--claude-status", "skipped",
                "--claude-skip-reason", "command-unavailable",
                "--output", str(manifest_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("ZOO_CAPTURE_MANIFEST", completed.stdout)
        self.assertTrue(manifest_path.is_file())
        self.assertEqual(
            list(manifest_path.parent.glob("*review*")), [],
            "capture command must not fabricate a human review",
        )
        review_path = self.write_review(root, manifest_path, "pending")
        completed = subprocess.run(
            [
                sys.executable, "-B", str(SCRIPT), "verify-review",
                "--manifest", str(manifest_path),
                "--review", str(review_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("decision=pending", completed.stdout)


if __name__ == "__main__":
    unittest.main()
