#!/usr/bin/env python3
"""Fail-closed provenance scan for the active terminal-stack working tree.

Unlike audit-swiftterm-lineage.py, this gate reads files from disk (including
untracked files).  It compares token fingerprints with both the initial
SwiftTerm vendor import and the retired extracted implementation.  Expected
declaration, protocol-data, compatibility, data-plumbing, and platform-mechanic
matches must be classified in a reviewed JSON file; every other match fails.

This is an engineering source-similarity gate, not a legal conclusion.  It
cannot prove independent authorship or detect algorithms rewritten beyond its
token-fingerprint thresholds.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Sequence


SCHEMA_VERSION = 1
DEFAULT_VENDOR_REF = "512b859268662b8e01f5923fabd7958e12e280df"
DEFAULT_RETIRED_REF = "584624985809f6000a82d3b3b97e43ef885af572"
DEFAULT_ALLOWLIST = "docs/independence/WORKING_TREE_PROVENANCE_ALLOWLIST.json"
EXACT_TOKEN_THRESHOLD = 32
STRUCTURAL_TOKEN_THRESHOLD = 80
SOURCE_SUFFIXES = frozenset((
    ".swift", ".metal",
    ".c", ".m", ".mm", ".cc", ".cpp", ".cxx",
    ".s", ".S",
    ".h", ".H", ".hh", ".hp", ".hpp", ".h++", ".hxx",
    ".inc", ".inl", ".ipp", ".tcc", ".def",
    ".modulemap", ".apinotes",
))
# Historical reference scope is intentionally frozen to the source types used
# by the original comparison. Active coverage below is broader and mirrors the
# release manifest's complete SwiftPM source policy.
REFERENCE_SOURCE_SUFFIXES = frozenset(
    (".swift", ".metal", ".c", ".h", ".m", ".mm")
)

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
REQUIRED_APP_SEAM = (
    "App/CmdyCoreAdapter.swift",
    "App/CmdySnapshotShaper.swift",
    "App/CmdyTerminalSurface.swift",
    "App/EngineFactory.swift",
    "App/TerminalModel.swift",
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
RETIRED_MODULE_PATTERN = r"(?:SwiftTerm|Termite[A-Za-z0-9_]*)"
SOURCE_PARENTS = (
    "Core/Sources",
    "Renderer/Sources",
    "Kit/Sources",
    "Identity/Sources",
    "Plugins/CmdySDK/Sources",
    "Plugins/chromium/Support/Sources",
)
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
REFERENCE_LAYOUT = {
    "vendor": (
        ("Vendor/SwiftTerm",),
        DEFAULT_VENDOR_REF,
    ),
    "retired": (
        (
            "Core/Sources/TermiteCore",
            "Core/Sources/TermitePTY",
            "Renderer/Sources/TermiteGPU",
            "App/TermiteCoreAdapter.swift",
            "App/TermiteCoreShaping.swift",
            "App/TermiteCoreSurface.swift",
        ),
        DEFAULT_RETIRED_REF,
    ),
}
ALLOWED_CLASSIFICATIONS = {
    "api-declaration",
    "official-protocol-data",
    "compatibility-data",
    "data-plumbing",
    "standard-platform-mechanics",
    "non-substantive-structural-collision",
    "cmdy-original-retained-source",
}

SWIFT_KEYWORDS = frozenset(
    "actor associatedtype break case catch class continue convenience default "
    "defer deinit didSet do dynamic else enum extension fallthrough false "
    "fileprivate final for func get guard if import in indirect infix init "
    "inout internal is lazy let mutating nil nonisolated nonmutating open "
    "operator optional override package postfix precedencegroup prefix private "
    "protocol public repeat required rethrows return self Self some static "
    "struct subscript super switch throws true try typealias unowned var weak "
    "where while willSet async await any borrowing consuming isolated macro "
    "sending each".split()
)

# This is intentionally a small lexer rather than a Swift parser.  Comments do
# not participate in fingerprints; exact mode preserves identifiers/literals,
# while structural mode normalizes identifiers and string contents.
TOKEN_RE = re.compile(
    r"(?s)/\*.*?\*/|//[^\n]*|"
    r'""".*?"""|"(?:\\.|[^"\\])*"|'
    r"\b(?:0x[0-9A-Fa-f_]+|0b[01_]+|\d+(?:\.\d+)?)\b|"
    r"[A-Za-z_]\w*|==|!=|<=|>=|->|=>|&&|\|\||\.\.\.|\.\.<|"
    r"\?\?|\?\.|[{}()\[\],.:;?+*/%&|^!~<>@=-]"
)
COMMENT_OR_STRING_RE = re.compile(
    r'(?s)/\*.*?\*/|//[^\n]*|""".*?"""|"(?:\\.|[^"\\])*"'
)


class GateError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Token:
    value: str
    line: int


@dataclasses.dataclass(frozen=True)
class Document:
    path: str
    text: str
    sha256: str


@dataclasses.dataclass(frozen=True)
class Match:
    origin: str
    mode: str
    active_path: str
    active_start: int
    active_end: int
    historical_path: str
    historical_start: int
    historical_end: int
    token_count: int
    fingerprint: str

    @property
    def key(self) -> tuple[str, str, str, str, str]:
        return (
            self.origin,
            self.mode,
            self.active_path,
            self.historical_path,
            self.fingerprint,
        )


@dataclasses.dataclass(frozen=True)
class ClassifiedMatch:
    match: Match
    disposition: str
    classification_id: str | None
    rationale: str | None


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def strip_comments_preserving_strings(text: str) -> str:
    def replacement(found: re.Match[str]) -> str:
        value = found.group()
        if value.startswith("//") or value.startswith("/*"):
            return "".join("\n" if character == "\n" else " " for character in value)
        return value

    return COMMENT_OR_STRING_RE.sub(replacement, text)


def tokenize(text: str, mode: str) -> list[Token]:
    if mode not in {"exact", "structural"}:
        raise ValueError(f"unsupported token mode: {mode}")
    result: list[Token] = []
    line = 1
    previous = 0
    for found in TOKEN_RE.finditer(text):
        line += text.count("\n", previous, found.start())
        previous = found.start()
        value = found.group()
        if value.startswith("//") or value.startswith("/*"):
            continue
        if mode == "structural":
            if value.startswith('"'):
                value = "STR"
            elif re.fullmatch(r"[A-Za-z_]\w*", value) and value not in SWIFT_KEYWORDS:
                value = "ID"
        result.append(Token(value, line))
    return result


def _git(root: Path, *args: str) -> str:
    process = subprocess.run(
        ["git", *args], cwd=root, check=False, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        raise GateError(process.stderr.strip() or "git command failed")
    return process.stdout


def _relative(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def _first_symlink_component(root: Path, path: Path) -> str | None:
    current = root
    for part in path.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            return _relative(root, current)
    return None


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


def discover_active_sources(root: Path) -> tuple[list[Document], list[str]]:
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
        # App seam membership is not reliably inferable from imports because
        # same-module wrappers can mention only App-local abstractions. Scan
        # every App source so a new or untracked seam cannot evade the gate.
        paths.update(_governed_files(root, app, frozenset((".swift",)), issues))
        for relative in REQUIRED_APP_SEAM:
            path = root / relative
            symlink = _first_symlink_component(root, path)
            if symlink is not None:
                issues.append(
                    f"required App source contains symlink component: {symlink}"
                )
            elif not path.is_file():
                issues.append(f"missing required App seam source: {relative}")

    documents: list[Document] = []
    for path in sorted(paths, key=lambda candidate: _relative(root, candidate)):
        relative = _relative(root, path)
        if path.is_symlink():
            issues.append(f"active source must not be a symlink: {relative}")
            continue
        raw = path.read_bytes()
        documents.append(Document(
            path=relative,
            text=raw.decode("utf-8", errors="replace"),
            sha256=sha256_bytes(raw),
        ))
    return documents, sorted(set(issues))


def retired_source_issues(root: Path, active: Sequence[Document]) -> list[str]:
    root = root.resolve()
    issues: list[str] = []
    for relative_root in RETIRED_ROOTS:
        directory = root / relative_root
        if not directory.exists() and not directory.is_symlink():
            continue
        found_source = False
        if directory.is_dir() and not directory.is_symlink():
            for path in sorted(directory.rglob("*")):
                if path.is_file() and path.suffix in SOURCE_SUFFIXES:
                    found_source = True
                    issues.append(
                        f"retired source remains active: {_relative(root, path)}"
                    )
        if not found_source:
            issues.append(f"retired source root remains: {relative_root}")
    app = root / "App"
    if app.is_dir():
        for pattern in RETIRED_APP_GLOBS:
            for path in sorted(app.glob(pattern)):
                if path.is_file():
                    issues.append(f"retired App seam source remains active: {_relative(root, path)}")

    import_re = re.compile(
        r"^\s*(?:@[_A-Za-z]\w*(?:\([^\n)]*\))?\s+)*"
        r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
        r"(" + RETIRED_MODULE_PATTERN + r")\b",
        re.MULTILINE,
    )
    # Scan every source in the active package/application trees, not only the
    # files selected for similarity analysis. This prevents a newly added App
    # file with only a retired import from evading the seam-discovery heuristic.
    import_documents = {document.path: document.text for document in active}
    for relative_root in IMPORT_SCAN_ROOTS:
        directory = root / relative_root
        if not directory.is_dir():
            issues.append(f"missing import-scan root: {relative_root}")
            continue
        for path in sorted(directory.rglob("*")):
            if path.is_file() and path.suffix in {".swift", ".metal"}:
                relative = _relative(root, path)
                import_documents.setdefault(
                    relative,
                    path.read_text(encoding="utf-8", errors="replace"),
                )
    for path, source in sorted(import_documents.items()):
        found = import_re.search(strip_comments_preserving_strings(source))
        if found:
            issues.append(
                f"retired module import in {path}: {found.group(1)}")

    retired_spelling = re.compile(
        r"\b" + RETIRED_MODULE_PATTERN + r"\b", re.IGNORECASE,
    )
    for relative in PACKAGE_MANIFESTS:
        path = root / relative
        if not path.is_file():
            issues.append(f"missing package manifest: {relative}")
            continue
        # Preserve strings (including URL strings containing "//") while
        # removing comments. Any live SwiftTerm spelling in a package manifest
        # is dependency/configuration surface and must be reviewed.
        text = strip_comments_preserving_strings(
            path.read_text(encoding="utf-8", errors="replace"))
        if retired_spelling.search(text):
            issues.append(f"retired module reference in package manifest: {relative}")
    return sorted(set(issues))


def load_reference_documents(
    root: Path, origin: str, reference: str, prefixes: Sequence[str],
) -> tuple[str, list[Document]]:
    commit = _git(root, "rev-parse", "--verify", f"{reference}^{{commit}}").strip()
    listed = _git(root, "ls-tree", "-r", "--name-only", commit, "--", *prefixes)
    paths = sorted(set(
        path for path in listed.splitlines()
        if Path(path).suffix in REFERENCE_SOURCE_SUFFIXES
    ))
    if not paths:
        raise GateError(f"{origin} reference contains no source under configured paths")
    result: list[Document] = []
    for path in paths:
        raw = subprocess.run(
            ["git", "show", f"{commit}:{path}"], cwd=root, check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if raw.returncode != 0:
            raise GateError(raw.stderr.decode(errors="replace").strip())
        result.append(Document(
            path=path,
            text=raw.stdout.decode("utf-8", errors="replace"),
            sha256=sha256_bytes(raw.stdout),
        ))
    return commit, result


def _overlap(left: tuple[int, int], right: tuple[int, int]) -> int:
    return max(0, min(left[1], right[1]) - max(left[0], right[0]))


def find_matches(
    active: Sequence[Document], historical: Sequence[Document],
    origin: str, mode: str, minimum_tokens: int,
) -> list[Match]:
    historical_tokens = {
        document.path: tokenize(document.text, mode) for document in historical
    }
    index: dict[tuple[str, ...], list[tuple[str, int]]] = defaultdict(list)
    historical_values: dict[str, list[str]] = {}
    for document in historical:
        tokens = historical_tokens[document.path]
        values = [token.value for token in tokens]
        historical_values[document.path] = values
        for position in range(max(0, len(values) - minimum_tokens + 1)):
            index[tuple(values[position:position + minimum_tokens])].append(
                (document.path, position))

    matches: list[Match] = []
    for document in active:
        active_tokens = tokenize(document.text, mode)
        active_values = [token.value for token in active_tokens]
        candidates: list[tuple[int, int, int, str, int, int]] = []
        for active_start in range(max(0, len(active_values) - minimum_tokens + 1)):
            window = tuple(active_values[active_start:active_start + minimum_tokens])
            for historical_path, historical_start in index.get(window, ()):
                values = historical_values[historical_path]
                if (active_start > 0 and historical_start > 0
                        and active_values[active_start - 1] == values[historical_start - 1]):
                    continue
                length = minimum_tokens
                while (active_start + length < len(active_values)
                       and historical_start + length < len(values)
                       and active_values[active_start + length]
                           == values[historical_start + length]):
                    length += 1
                candidates.append((
                    length, active_start, active_start + length,
                    historical_path, historical_start, historical_start + length,
                ))

        # One longest, non-overlapping explanation per active token region keeps
        # repeated tables/initializers deterministic without hiding a disjoint
        # copied region elsewhere in the file.
        kept: list[tuple[int, int, int, str, int, int]] = []
        for candidate in sorted(
            candidates, key=lambda value: (-value[0], value[1], value[3], value[4])):
            if any(_overlap((candidate[1], candidate[2]), (item[1], item[2]))
                   for item in kept):
                continue
            kept.append(candidate)

        for length, active_start, active_end, historical_path, historical_start, historical_end in sorted(
                kept, key=lambda value: (value[1], value[3], value[4])):
            historical_list = historical_tokens[historical_path]
            sequence = "\0".join(active_values[active_start:active_end]).encode()
            matches.append(Match(
                origin=origin,
                mode=mode,
                active_path=document.path,
                active_start=active_tokens[active_start].line,
                active_end=active_tokens[active_end - 1].line,
                historical_path=historical_path,
                historical_start=historical_list[historical_start].line,
                historical_end=historical_list[historical_end - 1].line,
                token_count=length,
                fingerprint=sha256_bytes(mode.encode() + b"\0" + sequence),
            ))
    return sorted(matches, key=lambda value: (
        value.active_path, value.active_start, value.origin, value.mode,
        value.historical_path, value.historical_start,
    ))


def combined_matches(
    active: Sequence[Document], historical: Sequence[Document], origin: str,
    exact_threshold: int = EXACT_TOKEN_THRESHOLD,
    structural_threshold: int = STRUCTURAL_TOKEN_THRESHOLD,
) -> list[Match]:
    exact = find_matches(active, historical, origin, "exact", exact_threshold)
    structural = find_matches(
        active, historical, origin, "structural", structural_threshold)
    # An exact finding is the stronger explanation. Retain structural findings
    # only when at least half of their active region is not already represented.
    structural = [
        match for match in structural
        if not any(
            candidate.active_path == match.active_path
            and _line_overlap(candidate, match) * 2
                >= max(1, match.active_end - match.active_start + 1)
            for candidate in exact
        )
    ]
    return sorted(exact + structural, key=lambda value: (
        value.active_path, value.active_start, value.origin, value.mode,
        value.historical_path, value.historical_start,
    ))


def _line_overlap(left: Match, right: Match) -> int:
    return max(0, min(left.active_end, right.active_end)
               - max(left.active_start, right.active_start) + 1)


def load_allowlist(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"cannot read allowlist {path}: {error}") from error
    if not isinstance(value, dict) or value.get("schemaVersion") != SCHEMA_VERSION:
        raise GateError(f"allowlist must use schemaVersion {SCHEMA_VERSION}")
    if not isinstance(value.get("matches"), list):
        raise GateError("allowlist matches must be an array")
    if not isinstance(value.get("reviewedRetainedSources"), list):
        raise GateError("allowlist reviewedRetainedSources must be an array")
    return value


def classify_matches(
    matches: Sequence[Match], active: Sequence[Document], allowlist: dict[str, object],
) -> tuple[list[ClassifiedMatch], list[str]]:
    issues: list[str] = []
    active_hashes = {document.path: document.sha256 for document in active}
    explicit: dict[tuple[str, str, str, str, str], dict[str, object]] = {}
    explicit_ids: dict[tuple[str, str, str, str, str], str] = {}
    for raw in allowlist["matches"]:  # type: ignore[index]
        if not isinstance(raw, dict):
            issues.append("allowlist match entry must be an object")
            continue
        classification = raw.get("classification")
        if classification not in ALLOWED_CLASSIFICATIONS:
            issues.append(f"invalid allowlist classification: {classification!r}")
            continue
        identifier = str(raw.get("id", ""))
        rationale = str(raw.get("rationale", ""))
        if not identifier or not rationale:
            issues.append("allowlist match entries require nonempty id and rationale")
            continue
        base = tuple(str(raw.get(name, "")) for name in (
            "origin", "mode", "active", "historical"))
        singular = raw.get("fingerprint")
        plural = raw.get("fingerprints")
        if singular is not None and plural is not None:
            issues.append(
                f"allowlist match {identifier} cannot use both fingerprint forms")
            continue
        fingerprints: list[str]
        if plural is not None:
            if not isinstance(plural, list) or not plural:
                issues.append(
                    f"allowlist match {identifier} fingerprints must be a nonempty array")
                continue
            fingerprints = [str(value) for value in plural]
        else:
            fingerprints = [str(singular or "")]
        if any(not part for part in base) or any(not value for value in fingerprints):
            issues.append(f"allowlist match {identifier} has an incomplete key")
            continue
        for fingerprint in fingerprints:
            key = (*base, fingerprint)
            if key in explicit:
                issues.append(f"duplicate allowlist match key: {identifier}")
                continue
            explicit[key] = raw
            explicit_ids[key] = identifier

    retained: dict[tuple[str, str], dict[str, object]] = {}
    retained_ids: dict[tuple[str, str], str] = {}
    for raw in allowlist["reviewedRetainedSources"]:  # type: ignore[index]
        if not isinstance(raw, dict):
            issues.append("reviewed retained source entry must be an object")
            continue
        identifier = str(raw.get("id", ""))
        active_path = str(raw.get("active", ""))
        historical = str(raw.get("historical", ""))
        expected_hash = str(raw.get("sha256", ""))
        rationale = str(raw.get("rationale", ""))
        classification = raw.get("classification")
        if classification != "cmdy-original-retained-source":
            issues.append(f"retained source {identifier} has invalid classification")
            continue
        if not all((identifier, active_path, historical, expected_hash, rationale)):
            issues.append("retained source entries require id, paths, hash, and rationale")
            continue
        key = (active_path, historical)
        if key in retained:
            issues.append(f"duplicate retained source key: {identifier}")
            continue
        retained[key] = raw
        retained_ids[key] = identifier
        actual_hash = active_hashes.get(active_path)
        if actual_hash is None:
            issues.append(f"reviewed retained source is not active: {active_path}")
        elif actual_hash != expected_hash:
            issues.append(
                f"reviewed retained source changed: {active_path} "
                f"expected {expected_hash}, got {actual_hash}")

    used_explicit: set[tuple[str, str, str, str, str]] = set()
    used_retained: set[tuple[str, str]] = set()
    classified: list[ClassifiedMatch] = []
    for match in matches:
        raw = explicit.get(match.key)
        if raw is not None:
            used_explicit.add(match.key)
            classified.append(ClassifiedMatch(
                match, str(raw["classification"]), explicit_ids[match.key],
                str(raw["rationale"])))
            continue
        retained_key = (match.active_path, match.historical_path)
        retained_raw = retained.get(retained_key)
        if (match.origin == "retired" and retained_raw is not None
                and active_hashes.get(match.active_path) == retained_raw.get("sha256")):
            used_retained.add(retained_key)
            classified.append(ClassifiedMatch(
                match, "cmdy-original-retained-source",
                retained_ids[retained_key], str(retained_raw["rationale"])))
            continue
        classified.append(ClassifiedMatch(match, "unresolved", None, None))

    for key, identifier in sorted(explicit_ids.items(), key=lambda item: item[1]):
        if key not in used_explicit:
            issues.append(f"stale allowlist match: {identifier}")
    for key, identifier in sorted(retained_ids.items(), key=lambda item: item[1]):
        if key not in used_retained:
            issues.append(f"stale reviewed retained source: {identifier}")
    return classified, sorted(set(issues))


def build_report(
    root: Path, vendor_ref: str, retired_ref: str, allowlist_path: Path,
    exact_threshold: int = EXACT_TOKEN_THRESHOLD,
    structural_threshold: int = STRUCTURAL_TOKEN_THRESHOLD,
) -> dict[str, object]:
    active, discovery_issues = discover_active_sources(root)
    issues = discovery_issues + retired_source_issues(root, active)
    references: dict[str, dict[str, object]] = {}
    all_matches: list[Match] = []
    reference_specs = {
        "vendor": (REFERENCE_LAYOUT["vendor"][0], vendor_ref),
        "retired": (REFERENCE_LAYOUT["retired"][0], retired_ref),
    }
    for origin in ("vendor", "retired"):
        prefixes, reference = reference_specs[origin]
        commit, documents = load_reference_documents(root, origin, reference, prefixes)
        references[origin] = {"commit": commit, "sourceCount": len(documents)}
        all_matches.extend(combined_matches(
            active, documents, origin, exact_threshold, structural_threshold))

    allowlist = load_allowlist(allowlist_path)
    classified, classification_issues = classify_matches(
        all_matches, active, allowlist)
    issues.extend(classification_issues)
    unresolved = [item for item in classified if item.disposition == "unresolved"]
    ok = not issues and not unresolved

    report: dict[str, object] = {
        "schemaVersion": SCHEMA_VERSION,
        "thresholds": {
            "exactTokens": exact_threshold,
            "structuralTokens": structural_threshold,
        },
        "activeSources": [
            {"path": item.path, "sha256": item.sha256} for item in active
        ],
        "references": references,
        "matches": [
            {
                "origin": item.match.origin,
                "mode": item.match.mode,
                "active": item.match.active_path,
                "activeLines": [item.match.active_start, item.match.active_end],
                "historical": item.match.historical_path,
                "historicalLines": [
                    item.match.historical_start, item.match.historical_end],
                "tokenCount": item.match.token_count,
                "fingerprint": item.match.fingerprint,
                "disposition": item.disposition,
                "classificationId": item.classification_id,
                "rationale": item.rationale,
            }
            for item in classified
        ],
        "issues": sorted(set(issues)),
        "summary": {
            "activeSourceCount": len(active),
            "matchCount": len(classified),
            "classifiedMatchCount": len(classified) - len(unresolved),
            "unresolvedMatchCount": len(unresolved),
            "issueCount": len(set(issues)),
            "ok": ok,
        },
    }
    digest_input = json.dumps(report, sort_keys=True, separators=(",", ":")).encode()
    report["reportSHA256"] = sha256_bytes(digest_input)
    return report


def render_text(report: dict[str, object]) -> str:
    summary = report["summary"]  # type: ignore[assignment]
    assert isinstance(summary, dict)
    lines = [
        "WORKING_TREE_PROVENANCE "
        f"active={summary['activeSourceCount']} matches={summary['matchCount']} "
        f"classified={summary['classifiedMatchCount']} "
        f"unresolved={summary['unresolvedMatchCount']} "
        f"issues={summary['issueCount']} ok={str(summary['ok']).lower()} "
        f"sha256={report['reportSHA256']}"
    ]
    for issue in report["issues"]:  # type: ignore[index]
        lines.append(f"ISSUE {issue}")
    for item in report["matches"]:  # type: ignore[index]
        assert isinstance(item, dict)
        if item["disposition"] != "unresolved":
            continue
        active_lines = item["activeLines"]
        historical_lines = item["historicalLines"]
        lines.append(
            f"UNRESOLVED {item['mode']} tokens={item['tokenCount']} "
            f"{item['active']}:{active_lines[0]}-{active_lines[1]} <- "
            f"{item['origin']}:{item['historical']}:"
            f"{historical_lines[0]}-{historical_lines[1]} "
            f"fingerprint={item['fingerprint']}")
    return "\n".join(lines) + "\n"


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--vendor-ref", default=DEFAULT_VENDOR_REF)
    parser.add_argument("--retired-ref", default=DEFAULT_RETIRED_REF)
    parser.add_argument("--allowlist", type=Path)
    parser.add_argument("--mode", choices=("check", "report"), default="check")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = args.root.resolve()
    allowlist = args.allowlist or (root / DEFAULT_ALLOWLIST)
    if not allowlist.is_absolute():
        allowlist = root / allowlist
    try:
        report = build_report(
            root, args.vendor_ref, args.retired_ref, allowlist.resolve())
    except (GateError, OSError, ValueError) as error:
        print(f"working-tree provenance gate failed: {error}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(report, sort_keys=True, indent=2))
    else:
        sys.stdout.write(render_text(report))
    ok = bool(report["summary"]["ok"])  # type: ignore[index]
    return 0 if args.mode == "report" or ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
