#!/usr/bin/env python3
"""Fail-closed engineering and publication qualification for cmdy releases.

Engineering qualification verifies the exact checked-in trust inputs and runs
the unreviewed active-source integrity gate.  It never grants human approval.
Publication qualification is a strict superset: it requires a separately
recorded human approval and reviewed evidence bound to one committed
active-source snapshot. Project-owner approval is allowed only when the exact
public wording explicitly says that it is not an independent authorship or
legal clean-room review. The artifact phase additionally verifies the actual
notarized/stapled package inputs produced by release.sh.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Callable, Sequence


DEFAULT_RECORD = "docs/independence/RELEASE_QUALIFICATION.json"
PUBLICATION_EVIDENCE_ROOT = PurePosixPath("docs/independence/qualification")
EXPECTED_SCHEMA = "../../Schemas/release-qualification-v1.schema.json"
CORE_SEEDS = [
    49361, 104729, 123457, 99991, 2654435761, 130363, 155921,
    271828, 314159, 161803, 65537, 16777619, 20260820, 8675309,
    42424243, 314159265, 271828182,
]
CORE_CASES_PER_SEED = 3176
CORE_TOTAL_CASES = 53992
REQUIRED_BINDINGS = {
    "active-source-checker",
    "browser-release-script",
    "ci-workflow",
    "core-parity-checker",
    "independent-api-checker",
    "package-script",
    "package-resource-policy",
    "performance-gate",
    "product-identity",
    "product-identity-script",
    "provenance-allowlist",
    "provenance-checker",
    "qualification-checker",
    "qualification-schema",
    "renderer-corpus-archive",
    "renderer-corpus-lock",
    "renderer-corpus-validator-vector",
    "renderer-fixture",
    "renderer-parity-checker",
    "release-script",
    "release-workflow",
    "resource-stress-gate",
    "tui-zoo-gate",
    "zoo-review-checker",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OID_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?$")
UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
OWNER_APPROVAL_NOTICE = (
    "Project-owner approval; this is not an independent authorship or legal "
    "clean-room review."
)


class QualificationError(RuntimeError):
    pass


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False)
            + "\n").encode("utf-8")


def canonical_digest(value: object) -> str:
    return sha256_bytes(json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8"))


def _object_without_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise QualificationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json_bytes(raw: bytes, label: str) -> dict[str, object]:
    try:
        value = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_object_without_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise QualificationError(f"invalid JSON in {label}: {error}") from error
    if not isinstance(value, dict):
        raise QualificationError(f"{label} must contain a JSON object")
    return value


def expect_keys(value: object, expected: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise QualificationError(f"{label} must be an object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise QualificationError(
            f"{label} fields differ (missing={missing}, extra={extra})")
    return value


def expect_list(value: object, label: str) -> list[object]:
    if not isinstance(value, list):
        raise QualificationError(f"{label} must be an array")
    return value


def expect_string(value: object, label: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value.strip()):
        raise QualificationError(f"{label} must be a nonempty string")
    return value


def expect_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise QualificationError(f"{label} must be an integer")
    return value


def expect_bool(value: object, expected: bool, label: str) -> None:
    if not isinstance(value, bool) or value is not expected:
        raise QualificationError(f"{label} must be {str(expected).lower()}")


def expect_sha(value: object, label: str) -> str:
    text = expect_string(value, label)
    if not SHA256_RE.fullmatch(text):
        raise QualificationError(f"{label} must be a lowercase SHA-256")
    return text


def expect_oid(value: object, label: str) -> str:
    text = expect_string(value, label)
    if not GIT_OID_RE.fullmatch(text):
        raise QualificationError(f"{label} must be a full Git object ID")
    return text


def safe_relative_path(value: object, label: str) -> str:
    text = expect_string(value, label)
    if "\\" in text or any(ord(character) < 32 for character in text):
        raise QualificationError(f"{label} is not a canonical POSIX path")
    pure = PurePosixPath(text)
    if pure.is_absolute() or text != pure.as_posix() or any(
            part in ("", ".", "..") for part in pure.parts):
        raise QualificationError(f"{label} is not a safe relative path")
    return text


def resolve_real_file(root: Path, relative: str, label: str) -> Path:
    root = Path(os.path.abspath(root))
    if root.is_symlink() or not root.is_dir():
        raise QualificationError(f"repository root must be a real directory: {root}")
    current = root
    for part in PurePosixPath(relative).parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise QualificationError(f"missing {label}: {relative}") from error
        if stat.S_ISLNK(mode):
            raise QualificationError(f"{label} contains a symlink: {relative}")
    if not stat.S_ISREG(current.stat().st_mode):
        raise QualificationError(f"{label} must be a regular file: {relative}")
    return current


def validate_file_ref(root: Path, value: object, label: str) -> tuple[Path, str]:
    ref = expect_keys(value, {"path", "sha256"}, label)
    relative = safe_relative_path(ref["path"], f"{label}.path")
    expected = expect_sha(ref["sha256"], f"{label}.sha256")
    path = resolve_real_file(root, relative, label)
    actual = sha256_file(path)
    if actual != expected:
        raise QualificationError(
            f"{label} hash mismatch: expected {expected}, got {actual}")
    return path, expected


def iter_file_refs(value: object):
    if isinstance(value, dict):
        if set(value) == {"path", "sha256"}:
            yield value
            return
        for child in value.values():
            yield from iter_file_refs(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_file_refs(child)


def load_ref_json(root: Path, value: object, label: str) -> tuple[dict[str, object], Path]:
    path, expected = validate_file_ref(root, value, label)
    require_tracked(root, path, label)
    raw = path.read_bytes()
    if sha256_bytes(raw) != expected:
        raise QualificationError(f"{label} changed while it was being read")
    return parse_json_bytes(raw, label), path


def git(root: Path, *args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(
        ["git", *args], cwd=root, check=False, capture_output=True,
        text=text,
    )
    if result.returncode != 0:
        error = result.stderr.strip() if text else result.stderr.decode(errors="replace").strip()
        raise QualificationError(f"git {' '.join(args)} failed: {error}")
    return result.stdout


def require_clean_checkout(root: Path) -> None:
    status = str(git(root, "status", "--porcelain=v1", "--untracked-files=all"))
    if status:
        raise QualificationError("publication requires a clean checkout")


def require_tracked(root: Path, path: Path, label: str) -> None:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as error:
        raise QualificationError(f"{label} must be inside the repository") from error
    git(root, "ls-files", "--error-unmatch", "--", relative)


def require_reviewed_release_delta(
    root: Path, source_commit: str, head: str, record_path: Path,
    source: dict[str, object], evidence: dict[str, object],
) -> None:
    """Permit only the reviewed record and its exact evidence after source freeze.

    The source commit intentionally precedes the evidence/approval commit to
    avoid embedding its own object ID.  Treating any descendant as equivalent
    would nevertheless let unrelated native code, package inputs, or signing
    entitlements drift after review.  Every permitted descendant path is
    therefore both under the non-build qualification directory and referenced
    by an exact SHA-256 from the approved record.
    """
    try:
        record_relative = record_path.relative_to(root).as_posix()
    except ValueError as error:
        raise QualificationError(
            "qualification record must be inside repository root") from error

    refs = list(iter_file_refs({"source": source, "evidence": evidence}))
    operational, _ = load_ref_json(
        root, evidence["operational"]["record"], "operational delta evidence")
    refs.extend(iter_file_refs(operational))

    allowed = {record_relative}
    for index, ref in enumerate(refs):
        relative = safe_relative_path(
            ref["path"], f"publication delta evidence[{index}].path")
        pure = PurePosixPath(relative)
        if (len(pure.parts) <= len(PUBLICATION_EVIDENCE_ROOT.parts)
                or pure.parts[:len(PUBLICATION_EVIDENCE_ROOT.parts)]
                != PUBLICATION_EVIDENCE_ROOT.parts):
            raise QualificationError(
                "publication evidence must be stored under "
                f"{PUBLICATION_EVIDENCE_ROOT.as_posix()}/: {relative}")
        allowed.add(relative)

    raw = git(
        root, "diff", "--name-status", "-z", "--no-renames",
        source_commit, head, text=False)
    assert isinstance(raw, bytes)
    fields = raw.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % 2 != 0:
        raise QualificationError("could not parse release-tree delta")
    unexpected: list[str] = []
    for offset in range(0, len(fields), 2):
        status = fields[offset].decode("ascii", errors="replace")
        try:
            relative = fields[offset + 1].decode("utf-8")
        except UnicodeDecodeError as error:
            raise QualificationError(
                "release-tree delta contains a non-UTF-8 path") from error
        if status not in ("A", "M") or relative not in allowed:
            unexpected.append(f"{status} {relative}")
    if unexpected:
        raise QualificationError(
            "release HEAD differs from the reviewed source outside the exact "
            "approved evidence set: " + ", ".join(unexpected))


def load_record(root: Path, path: Path) -> tuple[dict[str, object], Path]:
    if not path.is_absolute():
        path = root / path
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as error:
        raise QualificationError("qualification record must be inside repository root") from error
    safe_relative_path(relative, "qualification record path")
    real = resolve_real_file(root, relative, "qualification record")
    raw = real.read_bytes()
    record = parse_json_bytes(raw, "qualification record")
    if raw != canonical_bytes(record):
        raise QualificationError("qualification record is not canonical JSON")
    return record, real


def validate_engineering(record: dict[str, object], root: Path) -> dict[str, object]:
    top = expect_keys(record, {
        "$schema", "engineering", "kind", "publication", "schemaVersion",
    }, "qualification record")
    if top["$schema"] != EXPECTED_SCHEMA:
        raise QualificationError("qualification record uses an unexpected schema")
    if (top["kind"] != "cmdy-release-qualification"
            or expect_int(top["schemaVersion"], "qualification schemaVersion") != 1):
        raise QualificationError("unsupported qualification kind or schema version")

    engineering = expect_keys(top["engineering"], {
        "bindings", "coreMatrix", "rendererCorpus",
    }, "engineering")
    bindings = expect_list(engineering["bindings"], "engineering.bindings")
    by_purpose: dict[str, tuple[Path, str]] = {}
    seen_paths: set[str] = set()
    for index, raw in enumerate(bindings):
        label = f"engineering.bindings[{index}]"
        binding = expect_keys(raw, {"path", "purpose", "sha256"}, label)
        purpose = expect_string(binding["purpose"], f"{label}.purpose")
        if purpose in by_purpose:
            raise QualificationError(f"duplicate engineering binding purpose: {purpose}")
        path_text = safe_relative_path(binding["path"], f"{label}.path")
        if path_text in seen_paths:
            raise QualificationError(f"duplicate engineering binding path: {path_text}")
        seen_paths.add(path_text)
        path, digest = validate_file_ref(root, {
            "path": path_text, "sha256": binding["sha256"],
        }, label)
        by_purpose[purpose] = (path, digest)
    if set(by_purpose) != REQUIRED_BINDINGS:
        raise QualificationError(
            "engineering binding purposes differ "
            f"(missing={sorted(REQUIRED_BINDINGS - set(by_purpose))}, "
            f"extra={sorted(set(by_purpose) - REQUIRED_BINDINGS)})")

    core = expect_keys(engineering["coreMatrix"], {
        "actionsPerCase", "casesPerSeed", "randomCasesPerSeed", "seeds",
        "totalCases",
    }, "engineering.coreMatrix")
    seeds = [expect_int(item, "engineering.coreMatrix.seeds[]")
             for item in expect_list(core["seeds"], "engineering.coreMatrix.seeds")]
    if seeds != CORE_SEEDS:
        raise QualificationError("engineering Core seed matrix differs from release policy")
    if expect_int(core["casesPerSeed"], "engineering.coreMatrix.casesPerSeed") != CORE_CASES_PER_SEED:
        raise QualificationError("engineering Core cases-per-seed must be 3176")
    if expect_int(core["totalCases"], "engineering.coreMatrix.totalCases") != CORE_TOTAL_CASES:
        raise QualificationError("engineering Core total must be 53992")
    if expect_int(core["randomCasesPerSeed"], "engineering.coreMatrix.randomCasesPerSeed") != 2000:
        raise QualificationError("engineering Core random-case count must be 2000")
    if expect_int(core["actionsPerCase"], "engineering.coreMatrix.actionsPerCase") != 180:
        raise QualificationError("engineering Core action count must be 180")

    renderer = expect_keys(engineering["rendererCorpus"], {
        "archiveSha256", "candidateFixtureSha256", "fixtureCount",
        "fixtureIndexSha256", "lockSha256", "referenceManifestSha256",
        "validatorVectorSha256",
    }, "engineering.rendererCorpus")
    for field in (
        "archiveSha256", "candidateFixtureSha256", "fixtureIndexSha256",
        "lockSha256", "referenceManifestSha256", "validatorVectorSha256",
    ):
        expect_sha(renderer[field], f"engineering.rendererCorpus.{field}")
    if expect_int(renderer["fixtureCount"], "engineering.rendererCorpus.fixtureCount") != 40:
        raise QualificationError("renderer fixture count must be 40")
    expected_binding_hashes = {
        "archiveSha256": by_purpose["renderer-corpus-archive"][1],
        "candidateFixtureSha256": by_purpose["renderer-fixture"][1],
        "lockSha256": by_purpose["renderer-corpus-lock"][1],
        "validatorVectorSha256": by_purpose["renderer-corpus-validator-vector"][1],
    }
    for field, expected in expected_binding_hashes.items():
        if renderer[field] != expected:
            raise QualificationError(f"renderer corpus {field} is not bound to its file")

    lock_path = by_purpose["renderer-corpus-lock"][0]
    lock = parse_json_bytes(lock_path.read_bytes(), "renderer corpus lock")
    if lock.get("archiveSha256") != renderer["archiveSha256"]:
        raise QualificationError("renderer lock/archive binding differs")
    if lock.get("fixtureCount") != 40 or lock.get("exceptions") != []:
        raise QualificationError("renderer lock must contain 40 fixtures and no exceptions")
    if lock.get("fixtureIndexSha256") != renderer["fixtureIndexSha256"]:
        raise QualificationError("renderer fixture-index binding differs")
    if lock.get("referenceManifestSha256") != renderer["referenceManifestSha256"]:
        raise QualificationError("renderer reference-manifest binding differs")
    vector_path = by_purpose["renderer-corpus-validator-vector"][0]
    vector = parse_json_bytes(vector_path.read_bytes(), "renderer validator vector")
    for field in ("archiveSha256", "fixtureIndexSha256", "referenceManifestSha256"):
        if vector.get(field) != renderer[field]:
            raise QualificationError(f"renderer validator {field} differs from policy")

    publication = expect_keys(top["publication"], {
        "approval", "evidence", "source", "state",
    }, "publication")
    if publication["state"] not in ("pending", "approved", "rejected"):
        raise QualificationError("publication.state must be pending, approved, or rejected")
    if publication["state"] != "approved" and publication["approval"] is not None:
        raise QualificationError("non-approved publication may not contain an approval")
    return {
        "bindings": by_purpose,
        "engineering": engineering,
        "publication": publication,
    }


def run_active_source_gate(root: Path, checker: Path) -> str:
    with tempfile.TemporaryDirectory(prefix="cmdy-active-source-") as temp:
        manifest = Path(temp) / "active-terminal-sources.json"
        commands = [
            [sys.executable, "-B", str(checker), "--root", str(root),
             "generate", "--output", str(manifest)],
            [sys.executable, "-B", str(checker), "--root", str(root),
             "verify", "--manifest-root", temp, "--manifest", str(manifest)],
        ]
        for command in commands:
            result = subprocess.run(command, cwd=root, check=False, capture_output=True, text=True)
            if result.returncode != 0:
                message = (result.stderr or result.stdout).strip()
                raise QualificationError(f"active-source integrity gate failed: {message}")
        generated = parse_json_bytes(manifest.read_bytes(), "generated active-source manifest")
        if generated.get("reviewState") != "unreviewed":
            raise QualificationError("engineering manifest must remain explicitly unreviewed")
        return sha256_file(manifest)


def validate_utc(value: object, label: str) -> str:
    text = expect_string(value, label)
    if not UTC_RE.fullmatch(text):
        raise QualificationError(f"{label} must use YYYY-MM-DDTHH:MM:SSZ")
    try:
        datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise QualificationError(f"{label} is not a real UTC timestamp") from error
    return text


def validate_approval(
    approval_value: object, engineering: dict[str, object],
    source: dict[str, object], evidence: dict[str, object],
) -> dict[str, object]:
    approval = expect_keys(approval_value, {
        "approvalReference", "approvedPublicWording", "decision",
        "engineeringDigestSha256", "evidenceDigestSha256",
        "reviewedAtUTC", "reviewerAffiliation",
        "reviewerIndependentFromImplementation", "reviewerKind", "reviewerName",
    }, "publication.approval")
    if approval["decision"] != "approved":
        raise QualificationError("publication approval decision must be approved")
    if approval["reviewerKind"] != "human":
        raise QualificationError("publication approval must be performed by a human")
    independent = approval["reviewerIndependentFromImplementation"]
    if not isinstance(independent, bool):
        raise QualificationError(
            "publication.approval.reviewerIndependentFromImplementation "
            "must be a boolean")
    for field in (
        "reviewerName", "reviewerAffiliation", "approvalReference",
        "approvedPublicWording",
    ):
        expect_string(approval[field], f"publication.approval.{field}")
    if not independent and OWNER_APPROVAL_NOTICE not in approval["approvedPublicWording"]:
        raise QualificationError(
            "project-owner approval must include the exact non-independent "
            "review notice in approvedPublicWording")
    validate_utc(approval["reviewedAtUTC"], "publication.approval.reviewedAtUTC")
    engineering_digest = expect_sha(
        approval["engineeringDigestSha256"],
        "publication.approval.engineeringDigestSha256")
    evidence_digest = expect_sha(
        approval["evidenceDigestSha256"],
        "publication.approval.evidenceDigestSha256")
    if engineering_digest != canonical_digest(engineering):
        raise QualificationError("human approval does not bind the engineering policy")
    if evidence_digest != canonical_digest({
            "approvedPublicWording": approval["approvedPublicWording"],
            "evidence": evidence,
            "source": source,
    }):
        raise QualificationError(
            "human approval does not bind the reviewed evidence set and exact public wording")
    return approval


def validate_manifest_against_commit(
    root: Path, manifest: dict[str, object], commit: str,
) -> None:
    sources = expect_list(manifest.get("sources"), "active manifest sources")
    trust = expect_list(manifest.get("trustFiles"), "active manifest trustFiles")
    if manifest.get("reviewState") != "unreviewed":
        raise QualificationError(
            "active manifest review state must remain unreviewed; approval belongs in the independent record")
    entries = sources + trust
    seen: set[str] = set()
    for index, raw in enumerate(entries):
        label = f"active manifest entry[{index}]"
        entry = expect_keys(raw, {"mode", "path", "sha256", "size"}, label)
        relative = safe_relative_path(entry["path"], f"{label}.path")
        if relative in seen:
            raise QualificationError(f"duplicate active manifest path: {relative}")
        seen.add(relative)
        expected_hash = expect_sha(entry["sha256"], f"{label}.sha256")
        expected_size = expect_int(entry["size"], f"{label}.size")
        expected_mode = expect_string(entry["mode"], f"{label}.mode")
        if expected_mode not in ("100644", "100755"):
            raise QualificationError(f"{label}.mode must be 100644 or 100755")
        tree_line = str(git(root, "ls-tree", commit, "--", relative)).rstrip("\n")
        if not tree_line:
            raise QualificationError(f"active manifest path absent from source commit: {relative}")
        mode, object_type, _rest = tree_line.split(None, 2)
        if mode != expected_mode or object_type != "blob":
            raise QualificationError(f"active manifest mode/type differs in source commit: {relative}")
        blob = git(root, "show", f"{commit}:{relative}", text=False)
        assert isinstance(blob, bytes)
        if len(blob) != expected_size or sha256_bytes(blob) != expected_hash:
            raise QualificationError(f"active manifest bytes differ in source commit: {relative}")


def validate_provenance(
    root: Path, value: object, manifest: dict[str, object],
) -> None:
    report, _path = load_ref_json(root, value, "publication.source.provenanceReport")
    summary = expect_keys(report.get("summary"), {
        "activeSourceCount", "classifiedMatchCount", "issueCount", "matchCount",
        "ok", "unresolvedMatchCount",
    }, "provenance summary")
    expect_bool(summary["ok"], True, "provenance summary.ok")
    if expect_int(summary["unresolvedMatchCount"], "provenance unresolved count") != 0:
        raise QualificationError("provenance report has unresolved matches")
    if expect_int(summary["issueCount"], "provenance issue count") != 0:
        raise QualificationError("provenance report has issues")
    if report.get("issues") != []:
        raise QualificationError("provenance report issue list is not empty")
    report_hash = expect_sha(report.get("reportSHA256"), "provenance reportSHA256")
    without_hash = dict(report)
    del without_hash["reportSHA256"]
    calculated = sha256_bytes(json.dumps(
        without_hash, sort_keys=True, separators=(",", ":"),
    ).encode())
    if report_hash != calculated:
        raise QualificationError("provenance report self-hash differs")
    manifest_sources = {
        item["path"]: item["sha256"]
        for item in expect_list(manifest.get("sources"), "active manifest sources")
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    provenance_sources = {
        item["path"]: item["sha256"]
        for item in expect_list(report.get("activeSources"), "provenance activeSources")
        if isinstance(item, dict) and set(item) == {"path", "sha256"}
    }
    if provenance_sources != manifest_sources:
        raise QualificationError("provenance report does not bind the active-source manifest")


def validate_core_evidence(
    root: Path, value: object, source_manifest_sha: str,
    engineering: dict[str, object],
) -> None:
    wrapper = expect_keys(value, {"record", "sourceManifestSha256"}, "evidence.core")
    if expect_sha(wrapper["sourceManifestSha256"], "evidence.core.sourceManifestSha256") != source_manifest_sha:
        raise QualificationError("Core evidence is not bound to the source manifest")
    record, _path = load_ref_json(root, wrapper["record"], "Core parity record")
    record = expect_keys(record, {
        "actionsPerCase", "candidateLibrarySha256", "checkerSha256",
        "exceptions", "failedCases", "kind", "randomCasesPerSeed",
        "referenceLibrarySha256", "schemaVersion", "seedResults",
        "sourceManifestSha256", "totalCases",
    }, "Core parity record")
    if (record["kind"] != "cmdy-core-parity-matrix"
            or expect_int(record["schemaVersion"], "Core schemaVersion") != 1):
        raise QualificationError("unsupported Core parity record")
    if record["sourceManifestSha256"] != source_manifest_sha:
        raise QualificationError("Core record source-manifest hash differs")
    expect_sha(record["referenceLibrarySha256"], "Core reference library hash")
    expect_sha(record["candidateLibrarySha256"], "Core candidate library hash")
    checker_hash = expect_sha(record["checkerSha256"], "Core checker hash")
    binding_hash = next(
        item["sha256"] for item in engineering["bindings"]
        if item["purpose"] == "core-parity-checker")
    if checker_hash != binding_hash:
        raise QualificationError("Core record used a different checker")
    if record["exceptions"] != [] or expect_int(record["failedCases"], "Core failedCases") != 0:
        raise QualificationError("Core parity contains failures or exceptions")
    if expect_int(record["totalCases"], "Core totalCases") != CORE_TOTAL_CASES:
        raise QualificationError("Core parity total must be 53992")
    if expect_int(record["randomCasesPerSeed"], "Core randomCasesPerSeed") != 2000:
        raise QualificationError("Core parity random-case count differs")
    if expect_int(record["actionsPerCase"], "Core actionsPerCase") != 180:
        raise QualificationError("Core parity action count differs")
    results = expect_list(record["seedResults"], "Core seedResults")
    actual_seeds: list[int] = []
    for index, raw in enumerate(results):
        result = expect_keys(raw, {
            "cases", "passed", "seed", "snapshotSha256",
        }, f"Core seedResults[{index}]")
        actual_seeds.append(expect_int(result["seed"], f"Core seedResults[{index}].seed"))
        if expect_int(result["cases"], f"Core seedResults[{index}].cases") != CORE_CASES_PER_SEED:
            raise QualificationError("Core seed result must contain 3176 cases")
        expect_bool(result["passed"], True, f"Core seedResults[{index}].passed")
        expect_sha(result["snapshotSha256"], f"Core seedResults[{index}].snapshotSha256")
    if actual_seeds != CORE_SEEDS:
        raise QualificationError("Core parity seed list is incomplete, reordered, or duplicated")


def validate_renderer_evidence(
    root: Path, value: object, source_manifest_sha: str,
    engineering: dict[str, object],
) -> None:
    wrapper = expect_keys(value, {
        "checkerSha256", "comparison", "environment", "sourceManifestSha256",
    }, "evidence.renderer")
    if expect_sha(wrapper["sourceManifestSha256"], "renderer sourceManifestSha256") != source_manifest_sha:
        raise QualificationError("renderer evidence is not bound to the source manifest")
    checker_hash = expect_sha(wrapper["checkerSha256"], "renderer checkerSha256")
    bound_checker_hash = next(
        item["sha256"] for item in engineering["bindings"]
        if item["purpose"] == "renderer-parity-checker")
    if checker_hash != bound_checker_hash:
        raise QualificationError("renderer evidence used a different checker")
    comparison, _comparison_path = load_ref_json(
        root, wrapper["comparison"], "renderer comparison")
    required = {
        "candidateFixtureIndexSha256", "candidateManifestSha256", "comparisons",
        "contract", "exceptions", "failedFixtureCount", "fixtureCount",
        "fixtureIndexesByteIdentical", "passed", "pixelFailedFixtureCount",
        "publicInputFailedFixtureCount", "referenceFixtureIndexSha256",
        "referenceManifestLocked", "referenceManifestSha256", "rule",
        "schemaVersion", "totalDifferingPixels",
    }
    comparison = expect_keys(comparison, required, "renderer comparison")
    if expect_int(comparison["schemaVersion"], "renderer comparison schemaVersion") != 2:
        raise QualificationError("renderer comparison schema must be 2")
    expect_bool(comparison["passed"], True, "renderer comparison passed")
    expect_bool(
        comparison["fixtureIndexesByteIdentical"], True,
        "renderer fixture indexes byte-identical")
    expect_bool(
        comparison["referenceManifestLocked"], True,
        "renderer reference manifest locked")
    for field in (
        "failedFixtureCount", "pixelFailedFixtureCount",
        "publicInputFailedFixtureCount", "totalDifferingPixels",
    ):
        if expect_int(comparison[field], f"renderer {field}") != 0:
            raise QualificationError(f"renderer {field} must be zero")
    if expect_int(comparison["fixtureCount"], "renderer fixtureCount") != 40:
        raise QualificationError("renderer fixtureCount must be 40")
    if comparison["exceptions"] != []:
        raise QualificationError("renderer exceptions must be empty")
    if comparison["rule"] != (
            "byte-identical public inputs and zero differing pixels; "
            "no implicit tolerance or exceptions"):
        raise QualificationError("renderer comparison rule permits drift or tolerance")
    if comparison["contract"] != "docs/independence/CMDYGPU_CONTRACT.md#13":
        raise QualificationError("renderer comparison is bound to the wrong contract")

    renderer_policy = engineering["rendererCorpus"]
    if comparison["referenceManifestSha256"] != renderer_policy["referenceManifestSha256"]:
        raise QualificationError("renderer comparison used a different reference manifest")
    for field in ("referenceFixtureIndexSha256", "candidateFixtureIndexSha256"):
        if comparison[field] != renderer_policy["fixtureIndexSha256"]:
            raise QualificationError(f"renderer {field} differs from the locked index")
    comparisons = expect_list(comparison["comparisons"], "renderer comparisons")
    if len(comparisons) != 40:
        raise QualificationError("renderer comparison must contain exactly 40 fixtures")
    names: set[tuple[str, int]] = set()
    names_by_scale: dict[int, set[str]] = {1: set(), 2: set()}
    comparison_fields = {
        "candidatePNGSha256", "candidatePublicInputSha256",
        "candidateRawRGBASha256", "differingChannels",
        "differingPixelBoundingBox", "differingPixels", "exactDeltaRGBA",
        "exactDeltaRGBASha256", "height", "maximumChannelDelta", "name",
        "publicInputMismatchCount", "publicInputMismatches",
        "publicInputsByteIdentical", "referencePNGSha256",
        "referencePublicInputSha256", "referenceRawRGBASha256", "scale",
        "totalAbsoluteChannelDelta", "totalPixels", "visualDiffPNG",
        "visualDiffPNGSha256", "width",
    }
    for index, raw in enumerate(comparisons):
        raw = expect_keys(raw, comparison_fields, f"renderer comparison[{index}]")
        name = expect_string(raw.get("name"), f"renderer comparison[{index}].name")
        scale = expect_int(raw.get("scale"), f"renderer comparison[{index}].scale")
        if scale not in names_by_scale:
            raise QualificationError("renderer fixture scale must be 1 or 2")
        if (name, scale) in names:
            raise QualificationError("renderer comparison contains a duplicate fixture")
        names.add((name, scale))
        names_by_scale[scale].add(name)
        zero_fields = (
            "differingChannels", "differingPixels", "maximumChannelDelta",
            "publicInputMismatchCount", "totalAbsoluteChannelDelta",
        )
        for field in zero_fields:
            if expect_int(raw.get(field), f"renderer comparison[{index}].{field}") != 0:
                raise QualificationError(f"renderer fixture {name} has a nonzero delta")
        expect_bool(
            raw.get("publicInputsByteIdentical"), True,
            f"renderer comparison[{index}].publicInputsByteIdentical")
        if raw.get("publicInputMismatches") != [] or raw.get("differingPixelBoundingBox") is not None:
            raise QualificationError(f"renderer fixture {name} contains a mismatch")
        for candidate, reference in (
            ("candidatePNGSha256", "referencePNGSha256"),
            ("candidatePublicInputSha256", "referencePublicInputSha256"),
            ("candidateRawRGBASha256", "referenceRawRGBASha256"),
        ):
            left = expect_sha(raw.get(candidate), f"renderer {candidate}")
            right = expect_sha(raw.get(reference), f"renderer {reference}")
            if left != right:
                raise QualificationError(f"renderer fixture {name} hashes differ")
        for hash_field in ("exactDeltaRGBASha256", "visualDiffPNGSha256"):
            expect_sha(raw[hash_field], f"renderer {hash_field}")
        expect_string(raw["exactDeltaRGBA"], "renderer exactDeltaRGBA")
        expect_string(raw["visualDiffPNG"], "renderer visualDiffPNG")
        width = expect_int(raw["width"], "renderer width")
        height = expect_int(raw["height"], "renderer height")
        total_pixels = expect_int(raw["totalPixels"], "renderer totalPixels")
        if width <= 0 or height <= 0 or total_pixels != width * height:
            raise QualificationError(f"renderer fixture {name} has invalid dimensions")
    if len(names_by_scale[1]) != 20 or names_by_scale[1] != names_by_scale[2]:
        raise QualificationError("renderer evidence must contain the same 20 fixtures at scales 1 and 2")

    environment, _environment_path = load_ref_json(
        root, wrapper["environment"], "renderer environment")
    environment = expect_keys(environment, {
        "candidate", "fixtureSourceSha256", "macOS", "machine", "reference",
        "schemaVersion", "swiftCompiler", "system", "xcode",
    }, "renderer environment")
    if expect_int(environment.get("schemaVersion"), "renderer environment schemaVersion") != 2:
        raise QualificationError("renderer environment schema must be 2")
    if environment.get("fixtureSourceSha256") != renderer_policy["candidateFixtureSha256"]:
        raise QualificationError("renderer environment used a different fixture source")
    candidate = expect_keys(
        environment.get("candidate"), {"kind", "moduleSha256", "objectSetSha256", "releaseBuild"},
        "renderer environment candidate")
    if candidate["kind"] != "build":
        raise QualificationError("renderer candidate environment must describe a build")
    expect_string(candidate["releaseBuild"], "renderer candidate releaseBuild")
    expect_sha(candidate["moduleSha256"], "renderer candidate module hash")
    expect_sha(candidate["objectSetSha256"], "renderer candidate object-set hash")
    reference = expect_keys(environment.get("reference"), {
        "archive", "archiveBytes", "archiveSha256", "corpusID",
        "fixtureIndexSha256", "kind", "lock", "lockSha256",
        "manifestSha256", "payloadSetSha256", "uncompressedTarSha256",
        "validatorVector", "validatorVectorSha256",
    }, "renderer environment reference")
    if reference.get("kind") != "locked-captures":
        raise QualificationError("renderer environment must use locked captures")
    for field in ("macOS", "machine", "swiftCompiler", "system", "xcode"):
        expect_string(environment[field], f"renderer environment {field}")
    for field, policy_field in (
        ("archiveSha256", "archiveSha256"),
        ("fixtureIndexSha256", "fixtureIndexSha256"),
        ("manifestSha256", "referenceManifestSha256"),
        ("lockSha256", "lockSha256"),
        ("validatorVectorSha256", "validatorVectorSha256"),
    ):
        if reference.get(field) != renderer_policy[policy_field]:
            raise QualificationError(f"renderer environment reference {field} differs")


def validate_operational_evidence(
    root: Path, value: object, source_manifest_sha: str,
    engineering: dict[str, object],
) -> None:
    wrapper = expect_keys(value, {"record", "sourceManifestSha256"}, "evidence.operational")
    if expect_sha(wrapper["sourceManifestSha256"], "operational sourceManifestSha256") != source_manifest_sha:
        raise QualificationError("operational evidence is not bound to the source manifest")
    record, _path = load_ref_json(root, wrapper["record"], "operational review")
    record = expect_keys(record, {
        "kind", "performance", "resourcePlateau", "review", "schemaVersion",
        "sourceManifestSha256", "zoo",
    }, "operational review")
    if (record["kind"] != "cmdy-operational-qualification-review"
            or expect_int(record["schemaVersion"], "operational schemaVersion") != 1):
        raise QualificationError("unsupported operational review record")
    if record["sourceManifestSha256"] != source_manifest_sha:
        raise QualificationError("operational review source-manifest hash differs")

    performance = expect_list(record["performance"], "operational performance")
    binding_hashes = {
        item["purpose"]: item["sha256"] for item in engineering["bindings"]
    }
    modes: list[str] = []
    for index, raw in enumerate(performance):
        item = expect_keys(raw, {
            "exceptions", "log", "mode", "passed", "scriptSha256",
        }, f"operational performance[{index}]")
        modes.append(expect_string(item["mode"], f"performance[{index}].mode"))
        expect_bool(item["passed"], True, f"performance[{index}].passed")
        if item["exceptions"] != []:
            raise QualificationError("performance evidence contains exceptions")
        if expect_sha(item["scriptSha256"], f"performance[{index}].scriptSha256") \
                != binding_hashes["performance-gate"]:
            raise QualificationError("performance evidence used a different gate")
        validate_file_ref(root, item["log"], f"performance[{index}].log")
        require_tracked(
            root,
            resolve_real_file(
                root, item["log"]["path"], f"performance[{index}].log"),
            f"performance[{index}].log")
    if modes != ["normal", "maximized"]:
        raise QualificationError("performance evidence must contain normal then maximized")

    plateau = expect_keys(record["resourcePlateau"], {
        "exceptions", "log", "monotonicGrowth", "passed", "runs",
        "scriptSha256", "zombieCount",
    }, "operational resourcePlateau")
    expect_bool(plateau["passed"], True, "resource plateau passed")
    expect_bool(plateau["monotonicGrowth"], False, "resource plateau monotonicGrowth")
    if expect_int(plateau["runs"], "resource plateau runs") < 3:
        raise QualificationError("resource plateau requires at least three runs")
    if expect_int(plateau["zombieCount"], "resource plateau zombieCount") != 0:
        raise QualificationError("resource plateau contains zombies")
    if plateau["exceptions"] != []:
        raise QualificationError("resource plateau contains exceptions")
    if expect_sha(plateau["scriptSha256"], "resource plateau scriptSha256") \
            != binding_hashes["resource-stress-gate"]:
        raise QualificationError("resource plateau used a different stress gate")
    validate_file_ref(root, plateau["log"], "resource plateau log")
    require_tracked(
        root, resolve_real_file(root, plateau["log"]["path"], "resource plateau log"),
        "resource plateau log")

    zoo = expect_keys(record["zoo"], {
        "captureCount", "captureManifest", "exceptions", "passed",
        "scriptSha256", "visualReview",
    }, "operational zoo")
    expect_bool(zoo["passed"], True, "zoo passed")
    if expect_int(zoo["captureCount"], "zoo captureCount") < 13:
        raise QualificationError("zoo evidence requires the complete capture set")
    if zoo["exceptions"] != []:
        raise QualificationError("zoo evidence contains exceptions")
    if expect_sha(zoo["scriptSha256"], "zoo scriptSha256") \
            != binding_hashes["tui-zoo-gate"]:
        raise QualificationError("zoo evidence used a different capture gate")
    validate_file_ref(root, zoo["captureManifest"], "zoo capture manifest")
    validate_file_ref(root, zoo["visualReview"], "zoo visual review")
    require_tracked(
        root, resolve_real_file(root, zoo["captureManifest"]["path"], "zoo capture manifest"),
        "zoo capture manifest")
    require_tracked(
        root, resolve_real_file(root, zoo["visualReview"]["path"], "zoo visual review"),
        "zoo visual review")
    zoo_checker = resolve_real_file(
        root,
        next(item["path"] for item in engineering["bindings"]
             if item["purpose"] == "zoo-review-checker"),
        "zoo review checker")
    zoo_result = subprocess.run([
        sys.executable, "-B", str(zoo_checker), "verify-review",
        "--manifest", str(root / zoo["captureManifest"]["path"]),
        "--review", str(root / zoo["visualReview"]["path"]),
        "--require-decision", "approved",
    ], cwd=root, check=False, capture_output=True, text=True)
    if zoo_result.returncode != 0:
        detail = (zoo_result.stderr or zoo_result.stdout).strip()
        raise QualificationError(f"zoo visual review verification failed: {detail}")
    zoo_summary = re.search(
        r"decision=approved manifest_sha256=([0-9a-f]{64}) captures=([0-9]+)",
        zoo_result.stdout)
    if not zoo_summary:
        raise QualificationError("zoo review checker did not emit its verified summary")
    if zoo_summary.group(1) != zoo["captureManifest"]["sha256"]:
        raise QualificationError("zoo review checker bound a different capture manifest")
    if int(zoo_summary.group(2)) != zoo["captureCount"]:
        raise QualificationError("zoo review checker reported a different capture count")

    review = expect_keys(record["review"], {
        "decision", "reference", "reviewedAtUTC", "reviewerName",
    }, "operational review approval")
    if review["decision"] != "approved":
        raise QualificationError("operational evidence has not been approved")
    expect_string(review["reviewerName"], "operational reviewerName")
    expect_string(review["reference"], "operational review reference")
    validate_utc(review["reviewedAtUTC"], "operational reviewedAtUTC")


def verify_publication_source(
    record: dict[str, object], record_path: Path, root: Path,
    engineering_state: dict[str, object], *, require_clean: bool = True,
    run_manifest_checker: bool = True,
) -> dict[str, object]:
    publication = engineering_state["publication"]
    assert isinstance(publication, dict)
    if publication["state"] != "approved":
        raise QualificationError(
            f"publication is {publication['state']}; human release approval is required")
    if publication["source"] is None or publication["evidence"] is None:
        raise QualificationError("approved publication is missing source or evidence")
    source = expect_keys(publication["source"], {
        "activeSourceManifest", "provenanceReport", "sourceCommit", "sourceTree",
    }, "publication.source")
    evidence = expect_keys(publication["evidence"], {
        "core", "operational", "renderer",
    }, "publication.evidence")
    engineering = engineering_state["engineering"]
    assert isinstance(engineering, dict)
    validate_approval(publication["approval"], engineering, source, evidence)

    if require_clean:
        require_clean_checkout(root)
        require_tracked(root, record_path, "qualification record")
    source_commit = expect_oid(source["sourceCommit"], "publication.source.sourceCommit")
    source_tree = expect_oid(source["sourceTree"], "publication.source.sourceTree")
    actual_tree = str(git(root, "rev-parse", f"{source_commit}^{{tree}}")).strip()
    if actual_tree != source_tree:
        raise QualificationError("publication source tree does not match source commit")
    head = str(git(root, "rev-parse", "HEAD")).strip()
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", source_commit, head], cwd=root,
        check=False, capture_output=True,
    )
    if ancestor.returncode != 0:
        raise QualificationError("reviewed source commit is not an ancestor of release HEAD")

    manifest, manifest_path = load_ref_json(
        root, source["activeSourceManifest"], "publication source manifest")
    manifest_sha = expect_sha(
        source["activeSourceManifest"]["sha256"], "publication source manifest sha256")
    if require_clean:
        require_tracked(root, manifest_path, "active-source manifest")
    validate_manifest_against_commit(root, manifest, source_commit)
    if run_manifest_checker:
        bindings = engineering_state["bindings"]
        assert isinstance(bindings, dict)
        checker = bindings["active-source-checker"][0]
        result = subprocess.run([
            sys.executable, "-B", str(checker), "--root", str(root), "verify",
            "--manifest-root", str(root), "--manifest", str(manifest_path),
        ], cwd=root, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            message = (result.stderr or result.stdout).strip()
            raise QualificationError(f"reviewed active-source manifest differs: {message}")

    validate_provenance(root, source["provenanceReport"], manifest)
    validate_core_evidence(root, evidence["core"], manifest_sha, engineering)
    validate_renderer_evidence(root, evidence["renderer"], manifest_sha, engineering)
    validate_operational_evidence(
        root, evidence["operational"], manifest_sha, engineering)
    require_reviewed_release_delta(
        root, source_commit, head, record_path, source, evidence)

    lock = parse_json_bytes(
        engineering_state["bindings"]["renderer-corpus-lock"][0].read_bytes(),
        "renderer corpus lock")
    if lock.get("humanReviewStatus") != "approved":
        raise QualificationError(
            "renderer corpus humanReviewStatus is pending; publication requires approved")
    if require_clean:
        operational_record, _ = load_ref_json(
            root, evidence["operational"]["record"], "operational review recheck")
        for index, ref in enumerate(iter_file_refs({
                "source": source, "evidence": evidence,
                "operational": operational_record})):
            validate_file_ref(root, ref, f"publication evidence recheck[{index}]")
        repeated_record, repeated_path = load_record(root, record_path)
        if repeated_record != record or repeated_path != record_path:
            raise QualificationError("qualification record changed during verification")
        validate_engineering(repeated_record, root)
        require_clean_checkout(root)
    return {
        "sourceCommit": source_commit,
        "sourceTree": source_tree,
        "releaseCommit": head,
        "releaseTree": str(git(root, "rev-parse", "HEAD^{tree}")).strip(),
        "sourceManifestSha256": manifest_sha,
    }


def parse_notary_receipt(path: Path, label: str) -> dict[str, str]:
    if path.is_symlink() or not path.is_file():
        raise QualificationError(f"{label} must be a real regular file")
    raw = path.read_bytes()
    value = parse_json_bytes(raw, label)
    if value.get("status") != "Accepted":
        raise QualificationError(f"{label} status must be Accepted")
    identifier = expect_string(value.get("id"), f"{label}.id")
    try:
        uuid.UUID(identifier)
    except ValueError as error:
        raise QualificationError(f"{label}.id must be a UUID") from error
    return {
        "id": identifier,
        "rawResultSha256": sha256_bytes(raw),
    }


def read_checksum(path: Path, artifact: Path, label: str) -> tuple[str, str]:
    if path.is_symlink() or not path.is_file():
        raise QualificationError(f"{label} must be a real regular file")
    raw = path.read_bytes()
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise QualificationError(f"{label} must be UTF-8") from error
    if len(lines) != 1:
        raise QualificationError(f"{label} must contain exactly one checksum")
    parts = lines[0].split()
    if len(parts) != 2 or not SHA256_RE.fullmatch(parts[0]):
        raise QualificationError(f"{label} has invalid shasum format")
    actual = sha256_file(artifact)
    if parts[0] != actual:
        raise QualificationError(f"{label} does not match {artifact.name}")
    recorded_name = parts[1].lstrip("*")
    if Path(recorded_name).name != artifact.name:
        raise QualificationError(f"{label} names a different artifact")
    return actual, sha256_bytes(raw)


def default_platform_assessor(app: Path, dmg: Path) -> dict[str, str]:
    commands = [
        ("app code signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)]),
        ("app stapler", ["/usr/bin/xcrun", "stapler", "validate", "-v", str(app)]),
        ("app Gatekeeper", ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app)]),
        ("DMG code signature", ["/usr/bin/codesign", "--verify", "--verbose=2", str(dmg)]),
        ("DMG structure", ["/usr/bin/hdiutil", "verify", str(dmg)]),
        ("DMG stapler", ["/usr/bin/xcrun", "stapler", "validate", "-v", str(dmg)]),
        ("DMG Gatekeeper", ["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(dmg)]),
    ]
    for label, command in commands:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            raise QualificationError(f"{label} verification failed: {detail}")
    signature = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], check=False,
        capture_output=True, text=True)
    detail = signature.stderr + signature.stdout
    if signature.returncode != 0 or "Authority=Developer ID Application:" not in detail:
        raise QualificationError("app is not signed by Developer ID Application")
    if not re.search(r"flags=.*\(runtime\)", detail):
        raise QualificationError("app signature does not enable hardened runtime")
    team_match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", detail, re.MULTILINE)
    if not team_match:
        raise QualificationError("app signature has no valid TeamIdentifier")
    cdhash_match = re.search(r"^CDHash=([0-9a-fA-F]+)$", detail, re.MULTILINE)
    if not cdhash_match:
        raise QualificationError("app signature has no CDHash")
    return {
        "teamIdentifier": team_match.group(1),
        "cdHash": cdhash_match.group(1).lower(),
    }


def verify_artifacts(
    source_identity: dict[str, object], record_path: Path, root: Path, *,
    app: Path, archive: Path, archive_checksum: Path, archive_receipt: Path,
    archive_submitted_sha256: str, dmg: Path, dmg_checksum: Path,
    dmg_receipt: Path, dmg_submitted_sha256: str, version: str, build: str,
    variant: str, output: Path,
    assessor: Callable[[Path, Path], dict[str, str]] = default_platform_assessor,
) -> dict[str, object]:
    if not VERSION_RE.fullmatch(version):
        raise QualificationError("artifact version is invalid")
    if not build.isdigit():
        raise QualificationError("artifact build number is invalid")
    for path, label in ((archive, "archive"), (dmg, "DMG")):
        if path.is_symlink() or not path.is_file():
            raise QualificationError(f"{label} must be a real regular file")
    if app.is_symlink() or not app.is_dir():
        raise QualificationError("app must be a real bundle directory")
    if not SHA256_RE.fullmatch(archive_submitted_sha256):
        raise QualificationError("archive submitted SHA-256 is invalid")
    if not SHA256_RE.fullmatch(dmg_submitted_sha256):
        raise QualificationError("DMG submitted SHA-256 is invalid")
    archive_notary = parse_notary_receipt(archive_receipt, "archive notary result")
    dmg_notary = parse_notary_receipt(dmg_receipt, "DMG notary result")
    archive_final, archive_checksum_hash = read_checksum(
        archive_checksum, archive, "archive checksum")
    dmg_final, dmg_checksum_hash = read_checksum(dmg_checksum, dmg, "DMG checksum")
    if archive_submitted_sha256 == archive_final:
        raise QualificationError(
            "rebuilt archive bytes must be distinguished from submitted archive bytes")
    if dmg_submitted_sha256 == dmg_final:
        raise QualificationError(
            "stapled DMG bytes must be distinguished from submitted DMG bytes")

    info_path = app / "Contents" / "Info.plist"
    if info_path.is_symlink() or not info_path.is_file():
        raise QualificationError("app Info.plist is missing or symlinked")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (plistlib.InvalidFileException, OSError) as error:
        raise QualificationError(f"invalid app Info.plist: {error}") from error
    identity_path = root / "Identity/Sources/ProductIdentity/Resources/product-identity.json"
    identity_bytes = identity_path.read_bytes()
    identity = parse_json_bytes(identity_bytes, "product identity")
    def require_packaged_identity(path: Path, label: str) -> None:
        if path.is_symlink() or not path.is_file():
            raise QualificationError(f"{label} is missing or symlinked")
        if path.read_bytes() != identity_bytes:
            raise QualificationError(
                f"{label} differs from the qualified source manifest")

    require_packaged_identity(
        app / "Contents/Resources/ProductIdentity_ProductIdentity.bundle/product-identity.json",
        "artifact product identity")
    if variant == "browser" or variant.startswith("browser-"):
        require_packaged_identity(
            app / "Contents/Resources/BrowserMCP/product-identity.json",
            "Browser MCP product identity")
    if info.get("CFBundleIdentifier") != identity.get("bundleIdentifier"):
        raise QualificationError("artifact bundle identifier differs from product identity")
    if info.get("CFBundleShortVersionString") != version:
        raise QualificationError("artifact version differs from requested version")
    if str(info.get("CFBundleVersion")) != build:
        raise QualificationError("artifact build differs from requested build")

    signature = assessor(app, dmg)
    output_record: dict[str, object] = {
        "artifacts": {
            "archive": {
                "checksumFileSha256": archive_checksum_hash,
                "finalSha256": archive_final,
                "name": archive.name,
                "notaryResultSha256": archive_notary["rawResultSha256"],
                "submissionId": archive_notary["id"],
                "submittedSha256": archive_submitted_sha256,
            },
            "dmg": {
                "checksumFileSha256": dmg_checksum_hash,
                "finalSha256": dmg_final,
                "name": dmg.name,
                "notaryResultSha256": dmg_notary["rawResultSha256"],
                "submissionId": dmg_notary["id"],
                "submittedSha256": dmg_submitted_sha256,
            },
        },
        "kind": "cmdy-publication-package",
        "product": {
            "build": build,
            "bundleIdentifier": info["CFBundleIdentifier"],
            "cdHash": signature["cdHash"],
            "teamIdentifier": signature["teamIdentifier"],
            "variant": variant or "lean",
            "version": version,
        },
        "qualificationSha256": sha256_file(record_path),
        "schemaVersion": 1,
        "source": source_identity,
        "verification": {
            "developerId": True,
            "gatekeeper": True,
            "hardenedRuntime": True,
            "notaryAccepted": True,
            "stapled": True,
        },
    }
    if output.is_symlink():
        raise QualificationError("artifact qualification output must not be a symlink")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_bytes(canonical_bytes(output_record))
    os.replace(temporary, output)
    return output_record


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--record", type=Path, default=Path(DEFAULT_RECORD))
    subparsers = parser.add_subparsers(dest="mode", required=True)
    subparsers.add_parser("engineering", help="verify engineering trust inputs")
    publication = subparsers.add_parser("publication", help="verify publication approval")
    publication.add_argument("--phase", choices=("source", "artifact"), default="source")
    publication.add_argument("--app", type=Path)
    publication.add_argument("--archive", type=Path)
    publication.add_argument("--archive-checksum", type=Path)
    publication.add_argument("--archive-notary-result", type=Path)
    publication.add_argument("--archive-submitted-sha256")
    publication.add_argument("--dmg", type=Path)
    publication.add_argument("--dmg-checksum", type=Path)
    publication.add_argument("--dmg-notary-result", type=Path)
    publication.add_argument("--dmg-submitted-sha256")
    publication.add_argument("--version")
    publication.add_argument("--build")
    publication.add_argument("--variant", default="")
    publication.add_argument("--output", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.root.resolve()
    try:
        record, record_path = load_record(root, args.record)
        state = validate_engineering(record, root)
        if args.mode == "engineering":
            active_hash = run_active_source_gate(
                root, state["bindings"]["active-source-checker"][0])
            publication_state = state["publication"]["state"]
            print(
                "RELEASE_QUALIFICATION engineering=passed "
                f"activeSourceManifestSha256={active_hash} "
                f"publication={publication_state}")
            return 0

        source_identity = verify_publication_source(
            record, record_path, root, state)
        if args.phase == "source":
            print(
                "RELEASE_QUALIFICATION publication=approved source=verified "
                f"sourceManifestSha256={source_identity['sourceManifestSha256']}")
            return 0

        required = {
            "app": args.app,
            "archive": args.archive,
            "archive_checksum": args.archive_checksum,
            "archive_receipt": args.archive_notary_result,
            "archive_submitted_sha256": args.archive_submitted_sha256,
            "dmg": args.dmg,
            "dmg_checksum": args.dmg_checksum,
            "dmg_receipt": args.dmg_notary_result,
            "dmg_submitted_sha256": args.dmg_submitted_sha256,
            "version": args.version,
            "build": args.build,
            "output": args.output,
        }
        missing = sorted(name for name, value in required.items() if value is None)
        if missing:
            raise QualificationError(f"artifact phase is missing arguments: {missing}")
        verify_artifacts(
            source_identity, record_path, root,
            app=args.app, archive=args.archive,
            archive_checksum=args.archive_checksum,
            archive_receipt=args.archive_notary_result,
            archive_submitted_sha256=args.archive_submitted_sha256,
            dmg=args.dmg, dmg_checksum=args.dmg_checksum,
            dmg_receipt=args.dmg_notary_result,
            dmg_submitted_sha256=args.dmg_submitted_sha256,
            version=args.version, build=args.build, variant=args.variant,
            output=args.output,
        )
        print(f"RELEASE_QUALIFICATION publication=approved artifact=verified output={args.output}")
        return 0
    except (QualificationError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f"release qualification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
