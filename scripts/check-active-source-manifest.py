#!/usr/bin/env python3
"""Generate or verify the active terminal-source path/hash manifest.

This checker is deliberately independent of the private historical refs used by
check-working-tree-provenance.py.  The historical comparison creates review
evidence before export; this tool binds the reviewed source bytes and discovery
policy so a one-commit public export can fail closed without those refs.

Generated manifests are engineering snapshots with reviewState=unreviewed.
Human approval must live in a separate review record that binds the manifest's
SHA-256; this tool never grants or infers that approval.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Sequence


SCHEMA_VERSION = 2
MANIFEST_KIND = "cmdy-active-terminal-source-manifest"
REVIEW_STATE = "unreviewed"
POLICY_ID = "cmdy-active-terminal-source-policy-v2"
POLICY_IMPLEMENTATION = "scripts/check-active-source-manifest.py"

SOURCE_SUFFIXES = frozenset((
    ".swift", ".metal",
    ".c", ".m", ".mm", ".cc", ".cpp", ".cxx",
    ".s", ".S",
    ".h", ".H", ".hh", ".hp", ".hpp", ".h++", ".hxx",
    ".inc", ".inl", ".ipp", ".tcc", ".def",
    ".modulemap", ".apinotes",
))
ACTIVE_ROOTS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("Core/Sources/CmdyCore", (".swift",)),
    ("Core/Sources/CmdyPTY", (".swift",)),
    ("Core/Sources/CmdyPTYShim", (".c", ".h")),
    ("Core/Sources/CmdyC", (".swift",)),
    ("Renderer/Sources/CmdyGPU", (".swift", ".metal")),
    ("Kit/Sources/CmdyKit", (".swift",)),
    ("Identity/Sources/ProductIdentity", (".swift",)),
    ("Plugins/CmdySDK/Sources/CmdySDK", (".swift",)),
    ("Plugins/chromium/Support/Sources/ChromiumSupport", (".swift",)),
)
REQUIRED_APP_SOURCES = (
    "App/CmdyCoreAdapter.swift",
    "App/CmdySnapshotShaper.swift",
    "App/CmdyTerminalSurface.swift",
    "App/EngineFactory.swift",
    "App/TerminalModel.swift",
)
SOURCE_PARENTS = (
    "Core/Sources",
    "Renderer/Sources",
    "Kit/Sources",
    "Identity/Sources",
    "Plugins/CmdySDK/Sources",
    "Plugins/chromium/Support/Sources",
)
RETIRED_ROOTS = (
    "Vendor/SwiftTerm",
    "Core/Sources/TermiteCore",
    "Core/Sources/TermitePTY",
    "Core/Tests/TermiteCoreTests",
    "Renderer/Sources/TermiteGPU",
    "Renderer/Tests/TermiteGPUTests",
    "Kit/Sources/TermiteKit",
    "Kit/Tests/TermiteKitTests",
    "Plugins/TermiteSDK",
)
RETIRED_APP_GLOBS = ("Termite*.swift", "SwiftTerm*.swift")
RETIRED_MODULES = (
    "SwiftTerm",
    "TermiteApp",
    "TermiteC",
    "TermiteCore",
    "TermiteEditor",
    "TermiteGPU",
    "TermiteKit",
    "TermitePTY",
    "TermiteSDK",
)
RETIRED_MODULE_PATTERN = r"(?:SwiftTerm|Termite[A-Za-z0-9_]*)"
IMPORT_SCAN_ROOTS = (
    "App",
    "Core/Sources",
    "Renderer/Sources",
    "Kit/Sources",
    "Identity/Sources",
    "Plugins/CmdySDK/Sources",
    "Plugins/chromium/Support/Sources",
)
PACKAGE_MANIFESTS = (
    "Package.swift",
    "Core/Package.swift",
    "Renderer/Package.swift",
    "Kit/Package.swift",
    "Identity/Package.swift",
    "Plugins/CmdySDK/Package.swift",
    "Plugins/chromium/Support/Package.swift",
)
PACKAGE_GRAPH_INPUTS = PACKAGE_MANIFESTS + (
    "Identity/Sources/ProductIdentity/Resources/product-identity.json",
)

COMMENT_OR_STRING_RE = re.compile(
    r'(?s)/\*.*?\*/|//[^\n]*|""".*?"""|"(?:\\.|[^"\\])*"'
)
RETIRED_IMPORT_RE = re.compile(
    r"^\s*(?:@[_A-Za-z]\w*(?:\([^\n)]*\))?\s+)*"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"(" + RETIRED_MODULE_PATTERN + r")\b",
    re.MULTILINE,
)
PATH_CONTROL_RE = re.compile(r"[\x00\r\n\t]")


class ManifestError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class SourceEntry:
    path: str
    mode: str
    size: int
    sha256: str

    def as_json(self) -> dict[str, object]:
        return dataclasses.asdict(self)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(
        value, ensure_ascii=False, indent=2, sort_keys=True,
    ) + "\n").encode("utf-8")


def _relative(root: Path, path: Path) -> str:
    relative = path.relative_to(root).as_posix()
    if not relative or relative.startswith("/") or PATH_CONTROL_RE.search(relative):
        raise ManifestError(f"unsupported source path: {relative!r}")
    if any(part in {"", ".", ".."} for part in Path(relative).parts):
        raise ManifestError(f"non-canonical source path: {relative!r}")
    return relative


def _first_symlink_component(root: Path, path: Path) -> str | None:
    """Return the first repository-relative symlink on a governed path."""
    current = root
    for part in path.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            return _relative(root, current)
    return None


def _strip_comments_and_strings(text: str) -> str:
    return COMMENT_OR_STRING_RE.sub(
        lambda found: "".join(
            "\n" if character == "\n" else " " for character in found.group()
        ),
        text,
    )


def _strip_comments_preserving_strings(text: str) -> str:
    def replacement(found: re.Match[str]) -> str:
        value = found.group()
        if value.startswith("//") or value.startswith("/*"):
            return "".join("\n" if character == "\n" else " " for character in value)
        return value

    return COMMENT_OR_STRING_RE.sub(replacement, text)


def policy_descriptor() -> dict[str, object]:
    """Return every path-discovery and retired-boundary rule as canonical data."""
    return {
        "activeRoots": [
            {"path": path, "suffixes": list(suffixes)}
            for path, suffixes in ACTIVE_ROOTS
        ],
        "appSourceRule": "all-recursive-swift",
        "importScanRoots": list(IMPORT_SCAN_ROOTS),
        "modeRule": "git-regular-100644-or-100755",
        "packageManifests": list(PACKAGE_MANIFESTS),
        "packageGraphInputs": list(PACKAGE_GRAPH_INPUTS),
        "policyId": POLICY_ID,
        "requiredAppSources": list(REQUIRED_APP_SOURCES),
        "retiredAppGlobs": list(RETIRED_APP_GLOBS),
        "retiredModulePattern": RETIRED_MODULE_PATTERN,
        "retiredModules": list(RETIRED_MODULES),
        "retiredRoots": list(RETIRED_ROOTS),
        "sourceParents": list(SOURCE_PARENTS),
        "sourceSuffixes": sorted(SOURCE_SUFFIXES),
        "symlinkRule": "reject-in-governed-source-trees",
    }


def _governed_files(
    root: Path,
    directory: Path,
    suffixes: frozenset[str],
    issues: list[str],
) -> list[Path]:
    result: list[Path] = []
    for path in sorted(directory.rglob("*")):
        relative = _relative(root, path)
        if path.is_symlink():
            issues.append(f"symlink in governed source tree: {relative}")
            continue
        if not path.is_file():
            continue
        if path.suffix in suffixes:
            result.append(path)
        elif path.suffix in SOURCE_SUFFIXES:
            issues.append(
                "unapproved source suffix in governed source tree: "
                f"{relative}"
            )
    return result


def discover_active_sources(root: Path) -> tuple[list[Path], list[str]]:
    """Discover the complete terminal-source review set directly from disk."""
    root = root.resolve()
    issues: list[str] = []
    paths: set[Path] = set()

    for relative_root, configured_suffixes in ACTIVE_ROOTS:
        directory = root / relative_root
        symlink = _first_symlink_component(root, directory)
        if symlink is not None:
            issues.append(
                f"active source root contains symlink component: {symlink}"
            )
            continue
        if not directory.is_dir():
            issues.append(f"missing active source root: {relative_root}")
            continue
        found = _governed_files(
            root, directory, frozenset(configured_suffixes), issues,
        )
        if not found:
            issues.append(f"active source root has no source files: {relative_root}")
        paths.update(found)

    configured_roots = {relative for relative, _ in ACTIVE_ROOTS}
    for parent_relative in SOURCE_PARENTS:
        parent = root / parent_relative
        symlink = _first_symlink_component(root, parent)
        if symlink is not None:
            issues.append(f"source parent contains symlink component: {symlink}")
            continue
        if not parent.is_dir():
            issues.append(f"missing source parent: {parent_relative}")
            continue
        for directory in sorted(parent.iterdir()):
            relative = _relative(root, directory)
            if directory.is_symlink():
                issues.append(f"symlink in source parent: {relative}")
                continue
            if not directory.is_dir():
                continue
            if relative in RETIRED_ROOTS:
                issues.append(f"retired source root remains: {relative}")
                continue
            if relative in configured_roots:
                continue
            if any(
                path.is_symlink()
                or (path.is_file() and path.suffix in SOURCE_SUFFIXES)
                for path in directory.rglob("*")
            ):
                issues.append(f"uncovered active source root: {relative}")

    app = root / "App"
    app_symlink = _first_symlink_component(root, app)
    if app_symlink is not None:
        issues.append(f"App source root contains symlink component: {app_symlink}")
    elif not app.is_dir():
        issues.append("missing App source root")
    else:
        paths.update(_governed_files(root, app, frozenset((".swift",)), issues))
        for relative in REQUIRED_APP_SOURCES:
            required = root / relative
            required_symlink = _first_symlink_component(root, required)
            if required_symlink is not None:
                issues.append(
                    "required App source contains symlink component: "
                    f"{required_symlink}"
                )
            elif not required.is_file():
                issues.append(f"missing required App source: {relative}")

    return sorted(paths, key=lambda path: _relative(root, path)), sorted(set(issues))


def retired_boundary_issues(root: Path) -> list[str]:
    root = root.resolve()
    issues: list[str] = []

    for relative in RETIRED_ROOTS:
        path = root / relative
        if path.exists() or path.is_symlink():
            issues.append(f"retired source root remains: {relative}")

    app = root / "App"
    if app.is_dir() and not app.is_symlink():
        for pattern in RETIRED_APP_GLOBS:
            for path in sorted(app.glob(pattern)):
                if path.exists() or path.is_symlink():
                    issues.append(
                        f"retired App source remains: {_relative(root, path)}"
                    )

    for relative_root in IMPORT_SCAN_ROOTS:
        directory = root / relative_root
        symlink = _first_symlink_component(root, directory)
        if symlink is not None:
            issues.append(f"import-scan root contains symlink component: {symlink}")
            continue
        if not directory.is_dir():
            issues.append(f"missing import-scan root: {relative_root}")
            continue
        for path in sorted(directory.rglob("*")):
            relative = _relative(root, path)
            if path.is_symlink():
                issues.append(f"symlink in import-scan tree: {relative}")
                continue
            if not path.is_file():
                continue
            if path.suffix not in {".swift", ".metal"}:
                continue
            source = path.read_text(encoding="utf-8", errors="replace")
            found = RETIRED_IMPORT_RE.search(_strip_comments_and_strings(source))
            if found:
                issues.append(
                    f"retired module import in {relative}: {found.group(1)}"
                )

    retired_spelling = re.compile(
        r"\b" + RETIRED_MODULE_PATTERN + r"\b", re.IGNORECASE,
    )
    for relative in PACKAGE_MANIFESTS:
        path = root / relative
        symlink = _first_symlink_component(root, path)
        if symlink is not None:
            issues.append(f"package manifest contains symlink component: {symlink}")
            continue
        if not path.is_file():
            issues.append(f"missing package manifest: {relative}")
            continue
        source = path.read_text(encoding="utf-8", errors="replace")
        if retired_spelling.search(_strip_comments_preserving_strings(source)):
            issues.append(f"retired module reference in package manifest: {relative}")

    for relative in sorted(set(PACKAGE_GRAPH_INPUTS) - set(PACKAGE_MANIFESTS)):
        path = root / relative
        symlink = _first_symlink_component(root, path)
        if symlink is not None:
            issues.append(f"package-graph input contains symlink component: {symlink}")
        elif not path.is_file():
            issues.append(f"missing package-graph input: {relative}")

    return sorted(set(issues))


def _source_entry(root: Path, path: Path) -> SourceEntry:
    relative = _relative(root, path)
    symlink = _first_symlink_component(root, path)
    if symlink is not None:
        raise ManifestError(f"active source path contains symlink component: {symlink}")
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode):
        raise ManifestError(f"active source must not be a symlink: {relative}")
    if not stat.S_ISREG(metadata.st_mode):
        raise ManifestError(f"active source must be a regular file: {relative}")
    data = path.read_bytes()
    mode = "100755" if metadata.st_mode & 0o111 else "100644"
    return SourceEntry(
        path=relative,
        mode=mode,
        size=len(data),
        sha256=sha256_bytes(data),
    )


def build_manifest(root: Path) -> dict[str, object]:
    root = root.resolve()
    sources, discovery_issues = discover_active_sources(root)
    issues = sorted(set(discovery_issues + retired_boundary_issues(root)))
    if issues:
        raise ManifestError("active source policy failed:\n" + "\n".join(issues))

    implementation = root / POLICY_IMPLEMENTATION
    implementation_symlink = _first_symlink_component(root, implementation)
    if implementation_symlink is not None:
        raise ManifestError(
            "policy implementation contains symlink component: "
            f"{implementation_symlink}"
        )
    if not implementation.is_file():
        raise ManifestError(
            f"missing policy implementation: {POLICY_IMPLEMENTATION}"
        )

    descriptor = policy_descriptor()
    entries = [_source_entry(root, path).as_json() for path in sources]
    trust_entries = [
        _source_entry(root, root / relative).as_json()
        for relative in sorted(PACKAGE_GRAPH_INPUTS)
    ]
    return {
        "kind": MANIFEST_KIND,
        "policy": {
            "descriptor": descriptor,
            "descriptorSHA256": sha256_bytes(canonical_bytes(descriptor)),
            "implementationPath": POLICY_IMPLEMENTATION,
            "implementationSHA256": sha256_bytes(implementation.read_bytes()),
        },
        "reviewState": REVIEW_STATE,
        "schemaVersion": SCHEMA_VERSION,
        "sourceCount": len(entries),
        "sources": entries,
        "trustFileCount": len(trust_entries),
        "trustFiles": trust_entries,
    }


def _entry_map(
    manifest: dict[str, object],
    *,
    entries_field: str,
    count_field: str,
    label: str,
) -> dict[str, dict[str, object]]:
    raw_sources = manifest.get(entries_field)
    if not isinstance(raw_sources, list):
        raise ManifestError(f"{label} {entries_field} must be an array")
    result: dict[str, dict[str, object]] = {}
    for raw in raw_sources:
        if not isinstance(raw, dict):
            raise ManifestError(f"{label} source entry must be an object")
        if set(raw) != {"mode", "path", "sha256", "size"}:
            raise ManifestError(f"{label} source entry has unexpected fields")
        path = raw.get("path")
        if not isinstance(path, str) or not path or PATH_CONTROL_RE.search(path):
            raise ManifestError(f"{label} source path is invalid: {path!r}")
        if path.startswith("/") or any(part in {"", ".", ".."} for part in Path(path).parts):
            raise ManifestError(f"{label} source path is non-canonical: {path!r}")
        if path in result:
            raise ManifestError(f"{label} contains duplicate source path: {path}")
        if raw.get("mode") not in {"100644", "100755"}:
            raise ManifestError(f"{label} source mode is invalid: {path}")
        size = raw.get("size")
        digest = raw.get("sha256")
        if type(size) is not int or size < 0:
            raise ManifestError(f"{label} source size is invalid: {path}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ManifestError(f"{label} source SHA-256 is invalid: {path}")
        result[path] = raw
    if list(result) != sorted(result):
        raise ManifestError(f"{label} source entries must be sorted by path")
    raw_count = manifest.get(count_field)
    if type(raw_count) is not int or raw_count != len(result):
        raise ManifestError(
            f"{label} {count_field} does not match its {entries_field}"
        )
    return result


def _source_map(manifest: dict[str, object], label: str) -> dict[str, dict[str, object]]:
    return _entry_map(
        manifest,
        entries_field="sources",
        count_field="sourceCount",
        label=label,
    )


def _trust_file_map(
    manifest: dict[str, object], label: str,
) -> dict[str, dict[str, object]]:
    return _entry_map(
        manifest,
        entries_field="trustFiles",
        count_field="trustFileCount",
        label=label,
    )


def load_manifest(
    path: Path, trust_root: Path,
) -> tuple[dict[str, object], bytes]:
    trust_root = Path(os.path.abspath(trust_root.expanduser()))
    if trust_root.is_symlink() or not trust_root.is_dir():
        raise ManifestError(
            f"manifest trust root must be a real directory: {trust_root}"
        )
    path = Path(os.path.abspath(path.expanduser()))
    try:
        path.relative_to(trust_root)
    except ValueError as error:
        raise ManifestError(
            f"manifest must be inside its trust root {trust_root}: {path}"
        ) from error
    symlink = _first_symlink_component(trust_root, path)
    if symlink is not None:
        raise ManifestError(
            f"manifest path contains symlink component: {symlink}"
        )
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read manifest {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError("manifest root must be an object")
    expected_keys = {
        "kind", "policy", "reviewState", "schemaVersion", "sourceCount", "sources",
        "trustFileCount", "trustFiles",
    }
    if set(value) != expected_keys:
        raise ManifestError("manifest root has unexpected or missing fields")
    if value.get("kind") != MANIFEST_KIND:
        raise ManifestError(f"manifest kind must be {MANIFEST_KIND!r}")
    if value.get("reviewState") != REVIEW_STATE:
        raise ManifestError(f"manifest reviewState must be {REVIEW_STATE!r}")
    if type(value.get("schemaVersion")) is not int or value.get("schemaVersion") != SCHEMA_VERSION:
        raise ManifestError(f"manifest schemaVersion must be {SCHEMA_VERSION}")
    _source_map(value, "manifest")
    trust_files = _trust_file_map(value, "manifest")
    if set(trust_files) != set(PACKAGE_GRAPH_INPUTS):
        raise ManifestError(
            "manifest trustFiles must be exactly the active package-graph inputs"
        )
    if raw != canonical_bytes(value):
        raise ManifestError("manifest JSON is not in canonical generated form")
    return value, raw


def comparison_issues(
    expected: dict[str, object], actual: dict[str, object],
) -> list[str]:
    issues: list[str] = []
    if expected.get("policy") != actual.get("policy"):
        issues.append("discovery policy or policy implementation drifted")

    expected_sources = _source_map(expected, "manifest")
    actual_sources = _source_map(actual, "working tree")
    expected_paths = set(expected_sources)
    actual_paths = set(actual_sources)
    for path in sorted(expected_paths - actual_paths):
        issues.append(f"missing active source: {path}")
    for path in sorted(actual_paths - expected_paths):
        issues.append(f"unexpected active source: {path}")
    for path in sorted(expected_paths & actual_paths):
        expected_entry = expected_sources[path]
        actual_entry = actual_sources[path]
        for field in ("mode", "size", "sha256"):
            if expected_entry[field] != actual_entry[field]:
                issues.append(f"active source {field} changed: {path}")

    expected_trust = _trust_file_map(expected, "manifest")
    actual_trust = _trust_file_map(actual, "working tree")
    expected_trust_paths = set(expected_trust)
    actual_trust_paths = set(actual_trust)
    for path in sorted(expected_trust_paths - actual_trust_paths):
        issues.append(f"missing trust file: {path}")
    for path in sorted(actual_trust_paths - expected_trust_paths):
        issues.append(f"unexpected trust file: {path}")
    for path in sorted(expected_trust_paths & actual_trust_paths):
        expected_entry = expected_trust[path]
        actual_entry = actual_trust[path]
        for field in ("mode", "size", "sha256"):
            if expected_entry[field] != actual_entry[field]:
                issues.append(f"trust file {field} changed: {path}")

    for field in (
        "kind", "reviewState", "schemaVersion", "sourceCount", "trustFileCount",
    ):
        if expected.get(field) != actual.get(field):
            issues.append(f"manifest field changed: {field}")
    if expected != actual and not issues:
        issues.append("manifest differs from the current canonical snapshot")
    return sorted(set(issues))


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate = subparsers.add_parser("generate", help="write an unreviewed manifest")
    generate.add_argument("--output", required=True, type=Path)
    verify = subparsers.add_parser("verify", help="verify a manifest fail-closed")
    verify.add_argument("--manifest", required=True, type=Path)
    verify.add_argument(
        "--manifest-root",
        type=Path,
        help=(
            "trusted real directory containing the manifest; defaults to --root"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.root.resolve()
    try:
        if args.command == "generate":
            manifest = build_manifest(root)
            raw = canonical_bytes(manifest)
            output = Path(os.path.abspath(args.output))
            if output.is_symlink():
                raise ManifestError(f"output manifest must not be a symlink: {output}")
            output.parent.mkdir(parents=True, exist_ok=True)
            try:
                with output.open("xb") as handle:
                    handle.write(raw)
            except FileExistsError as error:
                raise ManifestError(
                    f"refusing to overwrite existing manifest: {output}"
                ) from error
            print(
                "ACTIVE_SOURCE_MANIFEST generated "
                f"sources={manifest['sourceCount']} reviewState={REVIEW_STATE} "
                f"sha256={sha256_bytes(raw)} path={output}"
            )
            return 0

        manifest_root = (
            args.manifest_root if args.manifest_root is not None else args.root
        )
        expected, raw = load_manifest(args.manifest, manifest_root)
        actual = build_manifest(root)
        issues = comparison_issues(expected, actual)
        if issues:
            print("active source manifest verification failed:", file=sys.stderr)
            for issue in issues:
                print(f"- {issue}", file=sys.stderr)
            return 1
        print(
            "ACTIVE_SOURCE_MANIFEST verified "
            f"sources={actual['sourceCount']} reviewState={REVIEW_STATE} "
            f"sha256={sha256_bytes(raw)}"
        )
        return 0
    except (ManifestError, OSError, ValueError) as error:
        print(f"active source manifest check failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
