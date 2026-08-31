#!/usr/bin/env python3
"""Strict CmdyGPU reference/candidate pixel-parity gate.

The canonical mode validates a locked historical capture corpus, compiles the
public fixture only against the candidate, and makes exact pixel diffs. A
forensic build-vs-build mode remains available for reconstructing references,
but its independently scheduled animation clocks are not the release oracle.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


REPOSITORY = Path(__file__).resolve().parents[1]
FIXTURE_SOURCE = REPOSITORY / "Tests/RendererPixelOracle/RendererPixelFixture.swift"
DEFAULT_REFERENCE_CAPTURES = (
    REPOSITORY / "Tests/RendererPixelOracle/ReferenceCorpus"
)
REFERENCE_CORPUS_ID = "cmdygpu-historical-reference-v1"
REFERENCE_BASELINE_COMMIT = "584624985809f6000a82d3b3b97e43ef885af572"
REFERENCE_FIXTURE_SOURCE_SHA256 = (
    "27470b869272d2ce6e68a228ad29fe7f89757171441586c2975525b6f6e9d6a0"
)
REFERENCE_FIXTURE_INDEX_SHA256 = (
    "e52c987c52e495dc7bb7a14ccf8d9ef6b0abd4e8fed6d60facd469a2af6f9d5d"
)
REFERENCE_MANIFEST_SHA256 = (
    "868ffcb241e050c570278e5d6aa7fef2adfb6b15b938bee13e8917b7bd42d7b6"
)
REFERENCE_CORPUS_LOCK_SHA256 = (
    "a448c37b7e114505f4e8569ed9389c608698cb9bf50b7c0219daff4fd10ccd2f"
)
REFERENCE_VALIDATOR_VECTOR_SHA256 = (
    "9c987783edd7ede5cba9d2f4ea455667cd47ad55c620ebee26d27b70b6cc76fb"
)
REFERENCE_ARCHIVE_ENTRY_COUNT = 82
MAX_REFERENCE_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_REFERENCE_MEMBER_BYTES = 16 * 1024 * 1024
WIDTH_POINTS = 312
HEIGHT_POINTS = 216
SCALES = (1, 2)


def _covers(*values: str) -> tuple[str, ...]:
    return tuple(sorted(values))


EXPECTED_FIXTURES: dict[str, tuple[str, tuple[str, ...]]] = {
    "ascii-styles-backgrounds": (
        "current",
        _covers(
            "ascii",
            "styled-text",
            "default-background",
            "explicit-background",
            "selection-background",
            "strike-through",
        ),
    ),
    "unicode-clusters": (
        "current",
        _covers(
            "combining-text",
            "emoji-zwj",
            "color-emoji",
            "cjk-wide-cells",
            "adjacent-jamo-cells",
            "explicit-utf16-boundaries",
        ),
    ),
    "cursor-blink-block": (
        "current",
        _covers("cursor.blink-block", "cursor-focused", "cursor-cell-recolor"),
    ),
    "cursor-steady-block": (
        "current",
        _covers("cursor.steady-block", "cursor-focused", "cursor-cell-recolor"),
    ),
    "cursor-blink-underline": (
        "current",
        _covers("cursor.blink-underline", "cursor-focused", "cursor-cell-recolor"),
    ),
    "cursor-steady-underline": (
        "current",
        _covers("cursor.steady-underline", "cursor-focused", "cursor-cell-recolor"),
    ),
    "cursor-blink-bar": (
        "current",
        _covers("cursor.blink-bar", "cursor-focused", "cursor-cell-recolor"),
    ),
    "cursor-steady-bar": (
        "current",
        _covers("cursor.steady-bar", "cursor-focused", "cursor-cell-recolor"),
    ),
    "underline-styles": (
        "current",
        _covers(
            "underline.none",
            "underline.single",
            "underline.double",
            "underline.curly",
            "underline.dotted",
            "underline.dashed",
        ),
    ),
    "box-drawing-full-grid": (
        "current",
        _covers("box-drawing.U+2500-U+257F", "box-drawing.full-range"),
    ),
    "block-elements-full-grid": (
        "current",
        _covers("block-elements.U+2580-U+259F", "block-elements.full-range"),
    ),
    "line-modes": (
        "current",
        _covers(
            "line-mode.single",
            "line-mode.double-width",
            "line-mode.double-height-upper",
            "line-mode.double-height-lower",
        ),
    ),
    "image-z-layers-kitty": (
        "current",
        _covers(
            "image.negative-z",
            "image.zero-z",
            "image.positive-z",
            "image.text-composition",
            "kitty.placeholder",
            "kitty.rgba-payload",
        ),
    ),
    "insets-fractional-scroll": (
        "current",
        _covers(
            "inset.top",
            "inset.bottom",
            "inset.left",
            "inset.hard-clipping",
            "scroll.fractional",
            "scroll.pixel-snapping",
        ),
    ),
}

for _mode in (
    "current",
    "y-snap",
    "atlas-padding",
    "nearest",
    "high-contrast",
    "crisp",
):
    EXPECTED_FIXTURES[f"text-preset-{_mode}"] = (
        _mode,
        _covers(f"text-rendering-mode.{_mode}", "shader.mode-zero"),
    )


class GateError(RuntimeError):
    pass


@dataclass(frozen=True)
class BuildLayout:
    requested: Path
    release: Path
    module: Path
    objects: tuple[Path, ...]
    resource_bundles: tuple[Path, ...]


@dataclass(frozen=True)
class ReferenceCaptures:
    requested: Path
    lock: Path
    validator_vector: Path
    archive: Path
    corpus_id: str
    archive_sha256: str
    archive_bytes: int
    uncompressed_tar_sha256: str
    payload_set_sha256: str
    manifest_sha256: str
    fixture_index_sha256: str


@dataclass(frozen=True)
class DiffMetrics:
    differing_pixels: int
    differing_channels: int
    total_absolute_channel_delta: int
    maximum_channel_delta: int
    bounding_box: dict[str, int] | None
    exact_delta_rgba: bytes
    visual_delta_rgba: bytes


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(data: Any) -> bytes:
    return (json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def float_bits(value: float) -> str:
    return f"{struct.unpack('>Q', struct.pack('>d', value))[0]:016x}"


def write_json(path: Path, data: Any) -> None:
    path.write_bytes(canonical_json(data))


def require_sha256(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise GateError(f"{label} is not a lowercase SHA-256 digest")
    return value


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise GateError(f"{label} is not a regular file: {path}")
    try:
        value = json.loads(path.read_bytes())
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"invalid {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise GateError(f"{label} must contain a JSON object: {path}")
    return value


def locate_reference_captures(path: Path) -> ReferenceCaptures:
    requested = Path(os.path.abspath(path.expanduser()))
    if requested.is_symlink():
        raise GateError(f"reference-corpus input must not be a symlink: {requested}")
    lock_candidates: list[Path]
    vector_candidates: list[Path]
    selected_archive: Path | None = None
    if requested.is_dir():
        lock_candidates = sorted(requested.glob("*.lock.json"))
        vector_candidates = sorted(requested.glob("*.validator-vector.json"))
    elif requested.name.endswith(".lock.json"):
        lock_candidates = [requested]
        vector_candidates = sorted(requested.parent.glob("*.validator-vector.json"))
    elif requested.name.endswith(".tar.gz"):
        selected_archive = requested
        lock_candidates = sorted(requested.parent.glob("*.lock.json"))
        vector_candidates = sorted(requested.parent.glob("*.validator-vector.json"))
    else:
        raise GateError(
            "--reference-captures must name a locked corpus directory, "
            "its .lock.json, or its .tar.gz archive"
        )
    if len(lock_candidates) != 1:
        rendered = ", ".join(str(value) for value in lock_candidates) or "none"
        raise GateError(
            f"expected exactly one reference-corpus lock for {requested}; found {rendered}"
        )
    if len(vector_candidates) != 1:
        rendered = ", ".join(str(value) for value in vector_candidates) or "none"
        raise GateError(
            f"expected exactly one reference validator vector for {requested}; "
            f"found {rendered}"
        )
    lock_path = lock_candidates[0]
    vector_path = vector_candidates[0]
    if sha256_file(lock_path) != REFERENCE_CORPUS_LOCK_SHA256:
        raise GateError("reference-corpus lock does not match the frozen release lock")
    if sha256_file(vector_path) != REFERENCE_VALIDATOR_VECTOR_SHA256:
        raise GateError(
            "reference-corpus validator vector does not match the frozen release vector"
        )
    lock = load_json_object(lock_path, "reference-corpus lock")
    vector = load_json_object(vector_path, "reference-corpus validator vector")
    exact_fields: dict[str, Any] = {
        "schemaVersion": 1,
        "corpusID": REFERENCE_CORPUS_ID,
        "baselineCommit": REFERENCE_BASELINE_COMMIT,
        "archiveEntryCount": REFERENCE_ARCHIVE_ENTRY_COUNT,
        "fixtureCount": len(SCALES) * len(EXPECTED_FIXTURES),
        "scaleFactors": list(SCALES),
        "pixelFormat": "rgba8-unorm",
        "coordinateOrigin": "top-left",
        "fixtureSourceSha256": REFERENCE_FIXTURE_SOURCE_SHA256,
        "fixtureIndexSha256": REFERENCE_FIXTURE_INDEX_SHA256,
        "referenceManifestSha256": REFERENCE_MANIFEST_SHA256,
        "referencePixelsMatchedHistoricalManifest": True,
        "exceptions": [],
    }
    for field, expected in exact_fields.items():
        if lock.get(field) != expected:
            raise GateError(
                f"reference-corpus lock has {field}={lock.get(field)!r}; "
                f"expected {expected!r}"
            )
    archive_name = lock.get("archive")
    if (
        not isinstance(archive_name, str)
        or not archive_name
        or Path(archive_name).name != archive_name
        or not archive_name.endswith(".tar.gz")
    ):
        raise GateError("reference-corpus lock has an unsafe archive filename")
    archive_path = lock_path.parent / archive_name
    if selected_archive is not None and selected_archive != archive_path.absolute():
        raise GateError(
            f"reference archive {selected_archive} is not selected by lock {lock_path}"
        )
    if archive_path.is_symlink() or not archive_path.is_file():
        raise GateError(f"reference corpus archive is not a regular file: {archive_path}")
    archive_sha256 = require_sha256(
        lock.get("archiveSha256"), "reference-corpus archiveSha256"
    )
    archive_bytes = lock.get("archiveBytes")
    if isinstance(archive_bytes, bool) or not isinstance(archive_bytes, int):
        raise GateError("reference-corpus archiveBytes must be an integer")
    if archive_path.stat().st_size != archive_bytes:
        raise GateError(
            "reference corpus archive size mismatch: "
            f"expected {archive_bytes}, found {archive_path.stat().st_size}"
        )
    actual_archive_sha256 = sha256_file(archive_path)
    if actual_archive_sha256 != archive_sha256:
        raise GateError(
            "reference corpus archive hash mismatch: "
            f"expected {archive_sha256}, found {actual_archive_sha256}"
        )
    vector_fields = {
        "schemaVersion": 1,
        "archiveSha256": archive_sha256,
        "archiveBytes": archive_bytes,
        "gzipHeaderHex": "1f8b08000000000002ff",
        "uncompressedTarSha256": lock.get("uncompressedTarSha256"),
        "payloadSetAlgorithm": (
            "sha256(name-ascii || 00 || sha256(payload-bytes)) in member order"
        ),
        "payloadSetSha256": lock.get("payloadSetSha256"),
        "entryCount": REFERENCE_ARCHIVE_ENTRY_COUNT,
        "firstMember": "fixture-index.json",
        "lastMember": "s2__unicode-clusters.rgba",
        "referenceManifestSha256": REFERENCE_MANIFEST_SHA256,
        "fixtureIndexSha256": REFERENCE_FIXTURE_INDEX_SHA256,
        "expectedMetadata": {
            "memberNames": "strict ascending ASCII, canonical basename only",
            "memberType": "regular file",
            "mode": "0644",
            "uid": 0,
            "gid": 0,
            "uname": "",
            "gname": "",
            "mtime": 0,
            "gzipMtime": 0,
            "gzipOriginalFilename": "",
        },
        "negativeCases": [
            "reject one flipped archive byte before opening",
            "reject a duplicate member name",
            "reject an absolute or parent-traversal member name",
            "reject a directory, symlink, hard link, device, fifo, or pax member",
            "reject any metadata field that differs from expectedMetadata",
            "reject a missing or additional member",
            "reject any payload hash that differs from manifest.json",
        ],
    }
    for field, expected in vector_fields.items():
        if vector.get(field) != expected:
            raise GateError(
                f"reference validator vector has {field}={vector.get(field)!r}; "
                f"expected {expected!r}"
            )
    uncompressed_tar_sha256 = require_sha256(
        lock.get("uncompressedTarSha256"),
        "reference-corpus uncompressedTarSha256",
    )
    payload_set_sha256 = require_sha256(
        lock.get("payloadSetSha256"), "reference-corpus payloadSetSha256"
    )
    return ReferenceCaptures(
        requested=requested,
        lock=lock_path.absolute(),
        validator_vector=vector_path.absolute(),
        archive=archive_path.absolute(),
        corpus_id=REFERENCE_CORPUS_ID,
        archive_sha256=archive_sha256,
        archive_bytes=archive_bytes,
        uncompressed_tar_sha256=uncompressed_tar_sha256,
        payload_set_sha256=payload_set_sha256,
        manifest_sha256=REFERENCE_MANIFEST_SHA256,
        fixture_index_sha256=REFERENCE_FIXTURE_INDEX_SHA256,
    )


def canonical_archive_member_name(name: str) -> str:
    path = Path(name)
    if (
        not name
        or path.is_absolute()
        or len(path.parts) != 1
        or path.name != name
        or path.parts[0] in (".", "..")
        or "\\" in name
    ):
        raise GateError(f"unsafe reference-corpus archive member: {name!r}")
    try:
        name.encode("ascii")
    except UnicodeEncodeError as error:
        raise GateError(
            f"non-ASCII reference-corpus archive member: {name!r}"
        ) from error
    return name


def read_reference_archive(reference: ReferenceCaptures) -> dict[str, bytes]:
    archive_bytes = reference.archive.read_bytes()
    if (
        len(archive_bytes) != reference.archive_bytes
        or sha256_bytes(archive_bytes) != reference.archive_sha256
    ):
        raise GateError("reference corpus changed after lock validation")
    if archive_bytes[:10].hex() != "1f8b08000000000002ff":
        raise GateError("reference corpus has a non-canonical gzip header")
    try:
        uncompressed_tar = gzip.decompress(archive_bytes)
    except (OSError, EOFError) as error:
        raise GateError(f"cannot decompress reference corpus: {error}") from error
    if len(uncompressed_tar) > MAX_REFERENCE_ARCHIVE_BYTES:
        raise GateError("reference corpus exceeds the uncompressed size limit")
    if sha256_bytes(uncompressed_tar) != reference.uncompressed_tar_sha256:
        raise GateError("reference corpus uncompressed-tar hash mismatch")
    payloads: dict[str, bytes] = {}
    total_size = 0
    try:
        archive = tarfile.open(fileobj=io.BytesIO(uncompressed_tar), mode="r:")
    except (OSError, tarfile.TarError) as error:
        raise GateError(f"cannot read reference corpus {reference.archive}: {error}") from error
    with archive:
        if archive.pax_headers:
            raise GateError("reference corpus contains a global pax header")
        members = archive.getmembers()
        if len(members) != REFERENCE_ARCHIVE_ENTRY_COUNT:
            raise GateError(
                "reference corpus archive entry count mismatch: "
                f"expected {REFERENCE_ARCHIVE_ENTRY_COUNT}, found {len(members)}"
            )
        names = [canonical_archive_member_name(member.name) for member in members]
        if names != sorted(names):
            raise GateError("reference-corpus members are not in ascending ASCII order")
        payload_digest = hashlib.sha256()
        for member, name in zip(members, names):
            if name in payloads:
                raise GateError(f"duplicate reference-corpus archive member: {name}")
            if member.type != tarfile.REGTYPE or member.pax_headers:
                raise GateError(
                    f"reference-corpus member is not a regular file: {member.name!r}"
                )
            metadata = (
                member.mode,
                member.uid,
                member.gid,
                member.uname,
                member.gname,
                member.mtime,
            )
            if metadata != (0o644, 0, 0, "", "", 0):
                raise GateError(
                    f"reference-corpus member has non-canonical metadata: {name}"
                )
            if member.size < 0 or member.size > MAX_REFERENCE_MEMBER_BYTES:
                raise GateError(
                    f"reference-corpus member has unsafe size {member.size}: {name}"
                )
            total_size += member.size
            if total_size > MAX_REFERENCE_ARCHIVE_BYTES:
                raise GateError("reference corpus exceeds the uncompressed size limit")
            handle = archive.extractfile(member)
            if handle is None:
                raise GateError(f"cannot read reference-corpus member: {name}")
            data = handle.read(MAX_REFERENCE_MEMBER_BYTES + 1)
            if len(data) != member.size:
                raise GateError(
                    f"reference-corpus member size changed while reading: {name}"
                )
            payloads[name] = data
            payload_digest.update(name.encode("ascii"))
            payload_digest.update(b"\0")
            payload_digest.update(bytes.fromhex(sha256_bytes(data)))
        if payload_digest.hexdigest() != reference.payload_set_sha256:
            raise GateError("reference corpus payload-set hash mismatch")
    return payloads


def run_command(command: list[str], *, cwd: Path | None = None) -> str:
    print("+", " ".join(command), flush=True)
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if completed.stdout:
        print(completed.stdout, end="" if completed.stdout.endswith("\n") else "\n")
    if completed.returncode != 0:
        raise GateError(
            f"command failed with exit status {completed.returncode}: {' '.join(command)}"
        )
    return completed.stdout.strip()


def locate_build(path: Path) -> BuildLayout:
    requested = path.expanduser().resolve()
    candidates: list[Path] = []
    if (requested / "Modules/CmdyGPU.swiftmodule").is_file():
        candidates.append(requested)
    if requested.exists():
        candidates.extend(
            module.parent.parent
            for module in requested.glob("**/release/Modules/CmdyGPU.swiftmodule")
        )
    unique = sorted(set(candidate.resolve() for candidate in candidates))
    if len(unique) != 1:
        rendered = ", ".join(str(value) for value in unique) or "none"
        raise GateError(
            f"expected exactly one CmdyGPU release build under {requested}; found {rendered}"
        )
    release = unique[0]
    module = release / "Modules/CmdyGPU.swiftmodule"
    object_dir = release / "CmdyGPU.build"
    objects = tuple(sorted(object_dir.glob("*.o"), key=lambda value: value.name))
    if not objects:
        raise GateError(f"no CmdyGPU object files found in {object_dir}")
    bundles = tuple(
        sorted(
            (entry for entry in release.glob("*CmdyGPU*.bundle") if entry.is_dir()),
            key=lambda value: value.name,
        )
    )
    return BuildLayout(requested, release, module, objects, bundles)


def build_candidate() -> BuildLayout:
    run_command(
        [
            "swift",
            "build",
            "--package-path",
            str(REPOSITORY / "Renderer"),
            "-c",
            "release",
        ],
        cwd=REPOSITORY,
    )
    output = run_command(
        [
            "swift",
            "build",
            "--package-path",
            str(REPOSITORY / "Renderer"),
            "-c",
            "release",
            "--show-bin-path",
        ],
        cwd=REPOSITORY,
    )
    if not output:
        raise GateError("swift build did not report a release binary path")
    return locate_build(Path(output.splitlines()[-1]))


def object_set_sha256(objects: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in objects:
        digest.update(path.name.encode())
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(path)))
    return digest.hexdigest()


def compile_runner(
    label: str, build: BuildLayout, destination: Path, fixture_source: Path
) -> Path:
    runner_dir = destination / f"{label}-runner"
    runner_dir.mkdir()
    executable = runner_dir / "renderer-pixel-fixture"
    command = [
        "xcrun",
        "swiftc",
        "-O",
        "-swift-version",
        "5",
        "-parse-as-library",
        "-module-name",
        "RendererPixelFixture",
        "-I",
        str(build.release / "Modules"),
        str(fixture_source),
        *(str(path) for path in build.objects),
        "-o",
        str(executable),
    ]
    for framework in (
        "AppKit",
        "CoreGraphics",
        "CoreText",
        "Foundation",
        "ImageIO",
        "Metal",
        "MetalKit",
        "QuartzCore",
    ):
        command.extend(("-framework", framework))
    run_command(command, cwd=REPOSITORY)

    for bundle in build.resource_bundles:
        shutil.copytree(bundle, runner_dir / bundle.name)
    write_json(
        runner_dir / "link-inputs.json",
        {
            "schemaVersion": 1,
            "fixtureSource": str(fixture_source),
            "fixtureSourceSha256": sha256_file(fixture_source),
            "cmdyGPUModule": str(build.module),
            "cmdyGPUModuleSha256": sha256_file(build.module),
            "objectSetSha256": object_set_sha256(build.objects),
            "objects": [
                {"name": path.name, "sha256": sha256_file(path)}
                for path in build.objects
            ],
            "resourceBundles": [bundle.name for bundle in build.resource_bundles],
        },
    )
    return executable


def run_fixture(label: str, executable: Path, destination: Path) -> Path:
    output = destination / label
    output.mkdir()
    run_command(
        [str(executable), "--output", str(output)],
        cwd=executable.parent,
    )
    return output


def png_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise GateError("fixture output is not a canonical PNG")
    return struct.unpack(">II", data[16:24])


def safe_fixture_path(directory: Path, filename: Any) -> Path:
    if not isinstance(filename, str) or not filename or Path(filename).name != filename:
        raise GateError(f"unsafe fixture output filename: {filename!r}")
    path = directory / filename
    if not path.is_file():
        raise GateError(f"missing fixture output: {path}")
    return path


def validate_index(directory: Path) -> tuple[bytes, dict[tuple[int, str], dict[str, Any]]]:
    index_path = directory / "fixture-index.json"
    if not index_path.is_file():
        raise GateError(f"missing fixture index: {index_path}")
    encoded = index_path.read_bytes()
    try:
        index = json.loads(encoded)
    except json.JSONDecodeError as error:
        raise GateError(f"invalid fixture index {index_path}: {error}") from error
    expected_header = {
        "schemaVersion": 2,
        "contract": "docs/independence/CMDYGPU_CONTRACT.md#13",
        "pixelFormat": "rgba8-unorm",
        "coordinateOrigin": "top-left",
        "drawablePixelFormat": "bgra8-unorm",
        "outputColorSpace": "sRGB",
        "fontPostScriptName": "Menlo-Regular",
        "fontPointSize": 14,
    }
    for key, value in expected_header.items():
        if index.get(key) != value:
            raise GateError(
                f"fixture index {index_path} has {key}={index.get(key)!r}; expected {value!r}"
            )
    fixtures = index.get("fixtures")
    if not isinstance(fixtures, list):
        raise GateError(f"fixture index {index_path} has no fixture list")
    expected_keys = {
        (scale, name) for scale in SCALES for name in EXPECTED_FIXTURES
    }
    actual: dict[tuple[int, str], dict[str, Any]] = {}
    for entry in fixtures:
        if not isinstance(entry, dict):
            raise GateError(f"non-object fixture entry in {index_path}")
        key = (entry.get("scale"), entry.get("name"))
        if key in actual:
            raise GateError(f"duplicate fixture entry {key!r} in {index_path}")
        actual[key] = entry
    if set(actual) != expected_keys:
        missing = sorted(expected_keys - set(actual))
        unexpected = sorted(set(actual) - expected_keys)
        raise GateError(
            f"fixture inventory mismatch in {index_path}; missing={missing}, unexpected={unexpected}"
        )

    for (scale, name), entry in sorted(actual.items()):
        expected_mode, expected_covers = EXPECTED_FIXTURES[name]
        width = WIDTH_POINTS * scale
        height = HEIGHT_POINTS * scale
        stem = f"s{scale}__{name}"
        assertions = {
            "width": width,
            "height": height,
            "rawRGBA": f"{stem}.rgba",
            "png": f"{stem}.png",
            "covers": list(expected_covers),
            "textRenderingMode": expected_mode,
            "shaderMode": 0,
            "expectedSnappedScrollY": (
                1.0 if name == "insets-fractional-scroll" and scale == 1
                else 0.5 if name == "insets-fractional-scroll" and scale == 2
                else 0.0
            ),
        }
        for field, expected in assertions.items():
            if entry.get(field) != expected:
                raise GateError(
                    f"fixture {(scale, name)!r} has {field}={entry.get(field)!r}; "
                    f"expected {expected!r}"
                )
        descriptor = entry.get("publicInput")
        if not isinstance(descriptor, dict) or descriptor.get("schemaVersion") != 1:
            raise GateError(
                f"fixture {(scale, name)!r} has no version-1 public input descriptor"
            )
        descriptor_records = descriptor.get("records")
        if not isinstance(descriptor_records, list):
            raise GateError(
                f"fixture {(scale, name)!r} public input descriptor has no record list"
            )
        record_map: dict[str, str] = {}
        record_keys: list[str] = []
        for record in descriptor_records:
            if (
                not isinstance(record, dict)
                or not isinstance(record.get("key"), str)
                or not isinstance(record.get("value"), str)
            ):
                raise GateError(
                    f"fixture {(scale, name)!r} has a malformed public input record"
                )
            record_key = record["key"]
            if record_key in record_map:
                raise GateError(
                    f"fixture {(scale, name)!r} repeats public input key {record_key!r}"
                )
            record_keys.append(record_key)
            record_map[record_key] = record["value"]
        if record_keys != sorted(record_keys):
            raise GateError(
                f"fixture {(scale, name)!r} public input records are not canonical"
            )
        required_records = {
            "fixture.name": name,
            "runtime.architecture": "arm64",
            "runtime.view.colorSpace": "kCGColorSpaceSRGB",
            "runtime.drawableScale.x": float_bits(float(scale)),
            "runtime.drawableScale.y": float_bits(float(scale)),
            "renderer.shaderMode": "0",
            "renderer.textRenderingMode": expected_mode,
            "source.backingScaleFactor": float_bits(float(scale)),
            "source.contentXOrigin": float_bits(7.25 if name == "insets-fractional-scroll" else 8.0),
            "source.scrollContentOffset": (
                f"x={float_bits(0.0)};y={float_bits(1.26)}"
                if name == "insets-fractional-scroll"
                else f"x={float_bits(0.0)};y={float_bits(0.0)}"
            ),
            "source.grid.rows": "8",
            "source.grid.columns": "24",
            "source.line.0.version": "1",
            "source.line.7.version": "8",
        }
        for record_key, record_value in required_records.items():
            if record_map.get(record_key) != record_value:
                raise GateError(
                    f"fixture {(scale, name)!r} public input {record_key}="
                    f"{record_map.get(record_key)!r}; expected {record_value!r}"
                )
        font_record = record_map.get("source.normalFont", "")
        if "postscript=TWVubG8tUmVndWxhcg==" not in font_record:
            raise GateError(
                f"fixture {(scale, name)!r} public input does not identify Menlo-Regular"
            )
        raw_path = safe_fixture_path(directory, entry["rawRGBA"])
        png_path = safe_fixture_path(directory, entry["png"])
        if raw_path.stat().st_size != width * height * 4:
            raise GateError(
                f"fixture {key!r} raw byte count is {raw_path.stat().st_size}; "
                f"expected {width * height * 4}"
            )
        if png_dimensions(png_path.read_bytes()) != (width, height):
            raise GateError(f"fixture {key!r} PNG dimensions do not match its manifest")
    return encoded, actual


def diff_rgba(reference: bytes, candidate: bytes, width: int, height: int) -> DiffMetrics:
    expected = width * height * 4
    if len(reference) != expected or len(candidate) != expected:
        raise GateError("RGBA diff inputs do not match the declared dimensions")
    exact = bytearray(expected)
    visual = bytearray(expected)
    differing_pixels = 0
    differing_channels = 0
    total_delta = 0
    maximum_delta = 0
    min_x = width
    min_y = height
    max_x = -1
    max_y = -1
    for pixel in range(width * height):
        offset = pixel * 4
        pixel_differs = False
        for channel in range(4):
            delta = abs(reference[offset + channel] - candidate[offset + channel])
            exact[offset + channel] = delta
            if delta:
                differing_channels += 1
                total_delta += delta
                maximum_delta = max(maximum_delta, delta)
                pixel_differs = True
            if channel < 3:
                visual[offset + channel] = delta
        visual[offset + 3] = 255
        if pixel_differs:
            differing_pixels += 1
            x = pixel % width
            y = pixel // width
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    bounding_box = None
    if differing_pixels:
        bounding_box = {
            "x": min_x,
            "y": min_y,
            "width": max_x - min_x + 1,
            "height": max_y - min_y + 1,
        }
    return DiffMetrics(
        differing_pixels,
        differing_channels,
        total_delta,
        maximum_delta,
        bounding_box,
        bytes(exact),
        bytes(visual),
    )


def png_chunk(name: bytes, data: bytes) -> bytes:
    payload = name + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))


def write_rgba_png(path: Path, rgba: bytes, width: int, height: int) -> None:
    if len(rgba) != width * height * 4:
        raise GateError("cannot encode a PNG with an invalid RGBA byte count")
    rows = b"".join(
        b"\x00" + rgba[y * width * 4 : (y + 1) * width * 4]
        for y in range(height)
    )
    encoded = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(rows, level=9))
        + png_chunk(b"IEND", b"")
    )
    path.write_bytes(encoded)


def make_capture_manifest(
    label: str,
    directory: Path,
    entries: dict[tuple[int, str], dict[str, Any]],
) -> dict[str, Any]:
    fixtures: list[dict[str, Any]] = []
    for (scale, name), entry in sorted(entries.items()):
        raw_path = directory / entry["rawRGBA"]
        png_path = directory / entry["png"]
        fixtures.append(
            {
                "name": name,
                "scale": scale,
                "width": entry["width"],
                "height": entry["height"],
                "rawRGBA": entry["rawRGBA"],
                "rawRGBASha256": sha256_file(raw_path),
                "png": entry["png"],
                "pngSha256": sha256_file(png_path),
                "covers": entry["covers"],
                "textRenderingMode": entry["textRenderingMode"],
                "shaderMode": entry["shaderMode"],
                "expectedSnappedScrollY": entry["expectedSnappedScrollY"],
                "publicInputSha256": sha256_bytes(canonical_json(entry["publicInput"])),
            }
        )
    manifest = {
        "schemaVersion": 2,
        "implementation": label,
        "pixelFormat": "rgba8-unorm",
        "coordinateOrigin": "top-left",
        "fixtures": fixtures,
    }
    return manifest


def capture_manifest(
    label: str,
    directory: Path,
    entries: dict[tuple[int, str], dict[str, Any]],
) -> dict[str, Any]:
    manifest = make_capture_manifest(label, directory, entries)
    write_json(directory / "manifest.json", manifest)
    return manifest


def materialize_reference_captures(
    reference: ReferenceCaptures, destination: Path
) -> Path:
    payloads = read_reference_archive(reference)
    manifest_bytes = payloads.get("manifest.json")
    fixture_index_bytes = payloads.get("fixture-index.json")
    if manifest_bytes is None or fixture_index_bytes is None:
        raise GateError("reference corpus lacks manifest.json or fixture-index.json")
    if sha256_bytes(manifest_bytes) != reference.manifest_sha256:
        raise GateError(
            "reference corpus manifest hash mismatch: "
            f"expected {reference.manifest_sha256}, "
            f"found {sha256_bytes(manifest_bytes)}"
        )
    if sha256_bytes(fixture_index_bytes) != reference.fixture_index_sha256:
        raise GateError(
            "reference corpus fixture-index hash mismatch: "
            f"expected {reference.fixture_index_sha256}, "
            f"found {sha256_bytes(fixture_index_bytes)}"
        )
    if destination.exists():
        raise GateError(f"reference capture destination already exists: {destination}")
    destination.mkdir()
    for name, data in sorted(payloads.items()):
        (destination / name).write_bytes(data)

    index_bytes, entries = validate_index(destination)
    if sha256_bytes(index_bytes) != REFERENCE_FIXTURE_INDEX_SHA256:
        raise GateError("materialized reference fixture-index is not the frozen corpus")
    expected_files = {"manifest.json", "fixture-index.json"}
    for entry in entries.values():
        expected_files.add(entry["rawRGBA"])
        expected_files.add(entry["png"])
    if set(payloads) != expected_files:
        missing = sorted(expected_files - set(payloads))
        unexpected = sorted(set(payloads) - expected_files)
        raise GateError(
            "reference corpus payload inventory mismatch; "
            f"missing={missing}, unexpected={unexpected}"
        )

    expected_manifest = canonical_json(
        make_capture_manifest("reference", destination, entries)
    )
    if expected_manifest != manifest_bytes:
        raise GateError(
            "reference corpus manifest does not exactly bind every raw RGBA, "
            "PNG, and canonical public-input descriptor"
        )
    return destination


def public_input_mismatches(
    reference: dict[str, Any], candidate: dict[str, Any]
) -> list[dict[str, str | None]]:
    def by_key(descriptor: dict[str, Any]) -> dict[str, str]:
        return {record["key"]: record["value"] for record in descriptor["records"]}

    reference_records = by_key(reference)
    candidate_records = by_key(candidate)
    mismatches: list[dict[str, str | None]] = []
    for key in sorted(set(reference_records) | set(candidate_records)):
        reference_value = reference_records.get(key)
        candidate_value = candidate_records.get(key)
        if reference_value != candidate_value:
            mismatches.append(
                {
                    "key": key,
                    "reference": reference_value,
                    "candidate": candidate_value,
                }
            )
    if not mismatches:
        reference_bytes = canonical_json(reference)
        candidate_bytes = canonical_json(candidate)
        if reference_bytes != candidate_bytes:
            mismatches.append(
                {
                    "key": "$descriptor",
                    "reference": f"sha256:{sha256_bytes(reference_bytes)}",
                    "candidate": f"sha256:{sha256_bytes(candidate_bytes)}",
                }
            )
    return mismatches


def without_public_inputs(encoded: bytes) -> bytes:
    value = json.loads(encoded)
    for fixture in value["fixtures"]:
        fixture.pop("publicInput", None)
    return canonical_json(value)


def gate_passes(pixel_failures: int, public_input_failures: int) -> bool:
    return pixel_failures == 0 and public_input_failures == 0


def compare_captures(
    reference_dir: Path,
    candidate_dir: Path,
    destination: Path,
    *,
    reference_manifest_locked: bool = False,
) -> tuple[dict[str, Any], int]:
    reference_index_bytes, reference_entries = validate_index(reference_dir)
    candidate_index_bytes, candidate_entries = validate_index(candidate_dir)
    if without_public_inputs(reference_index_bytes) != without_public_inputs(
        candidate_index_bytes
    ):
        raise GateError(
            "reference and candidate fixture indexes differ outside public input descriptors"
        )
    if reference_manifest_locked:
        manifest_path = reference_dir / "manifest.json"
        if sha256_file(manifest_path) != REFERENCE_MANIFEST_SHA256:
            raise GateError("locked reference manifest changed before comparison")
    else:
        capture_manifest("reference", reference_dir, reference_entries)
    capture_manifest("candidate", candidate_dir, candidate_entries)

    diff_dir = destination / "diff"
    diff_dir.mkdir()
    comparisons: list[dict[str, Any]] = []
    pixel_failed = 0
    public_input_failed = 0
    failed_keys: set[tuple[int, str]] = set()
    total_differing_pixels = 0
    for key in sorted(reference_entries):
        scale, name = key
        reference_entry = reference_entries[key]
        candidate_entry = candidate_entries[key]
        width = reference_entry["width"]
        height = reference_entry["height"]
        reference_raw = (reference_dir / reference_entry["rawRGBA"]).read_bytes()
        candidate_raw = (candidate_dir / candidate_entry["rawRGBA"]).read_bytes()
        input_mismatches = public_input_mismatches(
            reference_entry["publicInput"], candidate_entry["publicInput"]
        )
        if input_mismatches:
            public_input_failed += 1
            failed_keys.add(key)
        metrics = diff_rgba(reference_raw, candidate_raw, width, height)
        stem = f"s{scale}__{name}"
        delta_name = f"{stem}.delta.rgba"
        visual_name = f"{stem}.diff.png"
        (diff_dir / delta_name).write_bytes(metrics.exact_delta_rgba)
        write_rgba_png(
            diff_dir / visual_name,
            metrics.visual_delta_rgba,
            width,
            height,
        )
        if metrics.differing_pixels:
            pixel_failed += 1
            failed_keys.add(key)
            total_differing_pixels += metrics.differing_pixels
        comparisons.append(
            {
                "name": name,
                "scale": scale,
                "width": width,
                "height": height,
                "totalPixels": width * height,
                "referenceRawRGBASha256": sha256_bytes(reference_raw),
                "candidateRawRGBASha256": sha256_bytes(candidate_raw),
                "referencePNGSha256": sha256_file(
                    reference_dir / reference_entry["png"]
                ),
                "candidatePNGSha256": sha256_file(
                    candidate_dir / candidate_entry["png"]
                ),
                "referencePublicInputSha256": sha256_bytes(
                    canonical_json(reference_entry["publicInput"])
                ),
                "candidatePublicInputSha256": sha256_bytes(
                    canonical_json(candidate_entry["publicInput"])
                ),
                "publicInputsByteIdentical": not input_mismatches,
                "publicInputMismatchCount": len(input_mismatches),
                "publicInputMismatches": input_mismatches,
                "differingPixels": metrics.differing_pixels,
                "differingChannels": metrics.differing_channels,
                "totalAbsoluteChannelDelta": metrics.total_absolute_channel_delta,
                "maximumChannelDelta": metrics.maximum_channel_delta,
                "differingPixelBoundingBox": metrics.bounding_box,
                "exactDeltaRGBA": f"diff/{delta_name}",
                "exactDeltaRGBASha256": sha256_bytes(metrics.exact_delta_rgba),
                "visualDiffPNG": f"diff/{visual_name}",
                "visualDiffPNGSha256": sha256_file(diff_dir / visual_name),
            }
        )
    result = {
        "schemaVersion": 2,
        "contract": "docs/independence/CMDYGPU_CONTRACT.md#13",
        "rule": (
            "byte-identical public inputs and zero differing pixels; "
            "no implicit tolerance or exceptions"
        ),
        "referenceFixtureIndexSha256": sha256_bytes(reference_index_bytes),
        "candidateFixtureIndexSha256": sha256_bytes(candidate_index_bytes),
        "referenceManifestSha256": sha256_file(reference_dir / "manifest.json"),
        "candidateManifestSha256": sha256_file(candidate_dir / "manifest.json"),
        "referenceManifestLocked": reference_manifest_locked,
        "fixtureIndexesByteIdentical": reference_index_bytes == candidate_index_bytes,
        "fixtureCount": len(comparisons),
        "failedFixtureCount": len(failed_keys),
        "pixelFailedFixtureCount": pixel_failed,
        "publicInputFailedFixtureCount": public_input_failed,
        "totalDifferingPixels": total_differing_pixels,
        "passed": gate_passes(pixel_failed, public_input_failed),
        "exceptions": [],
        "comparisons": comparisons,
    }
    write_json(destination / "comparison.json", result)
    return result, len(failed_keys)


def collect_environment(
    destination: Path,
    reference: BuildLayout | None,
    candidate: BuildLayout,
    fixture_source: Path,
    reference_captures: ReferenceCaptures | None = None,
) -> None:
    def version(command: list[str]) -> str:
        try:
            return subprocess.run(
                command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError) as error:
            return f"unavailable: {error}"

    if (reference is None) == (reference_captures is None):
        raise GateError("environment requires exactly one reference source")
    reference_identity: dict[str, Any]
    if reference is not None:
        reference_identity = {
            "kind": "build",
            "releaseBuild": str(reference.release),
            "moduleSha256": sha256_file(reference.module),
            "objectSetSha256": object_set_sha256(reference.objects),
        }
    else:
        assert reference_captures is not None
        reference_identity = {
            "kind": "locked-captures",
            "corpusID": reference_captures.corpus_id,
            "lock": str(reference_captures.lock),
            "lockSha256": sha256_file(reference_captures.lock),
            "validatorVector": str(reference_captures.validator_vector),
            "validatorVectorSha256": sha256_file(
                reference_captures.validator_vector
            ),
            "archive": str(reference_captures.archive),
            "archiveSha256": reference_captures.archive_sha256,
            "archiveBytes": reference_captures.archive_bytes,
            "uncompressedTarSha256": (
                reference_captures.uncompressed_tar_sha256
            ),
            "payloadSetSha256": reference_captures.payload_set_sha256,
            "manifestSha256": reference_captures.manifest_sha256,
            "fixtureIndexSha256": reference_captures.fixture_index_sha256,
        }
    write_json(
        destination / "environment.json",
        {
            "schemaVersion": 2,
            "system": platform.system(),
            "machine": platform.machine(),
            "macOS": platform.mac_ver()[0],
            "swiftCompiler": version(["xcrun", "swiftc", "--version"]),
            "xcode": version(["xcodebuild", "-version"]),
            "fixtureSourceSha256": sha256_file(fixture_source),
            "reference": reference_identity,
            "candidate": {
                "kind": "build",
                "releaseBuild": str(candidate.release),
                "moduleSha256": sha256_file(candidate.module),
                "objectSetSha256": object_set_sha256(candidate.objects),
            },
        },
    )


def ensure_output_directory(requested: Path | None) -> Path:
    if requested is None:
        return Path(tempfile.mkdtemp(prefix="cmdy-renderer-pixel-parity."))
    output = requested.expanduser().resolve()
    try:
        output.relative_to(REPOSITORY.resolve())
    except ValueError:
        pass
    else:
        raise GateError("pixel-parity results must be written outside the repository")
    if output.exists() and any(output.iterdir()):
        raise GateError(f"refusing to overwrite non-empty output directory {output}")
    output.mkdir(parents=True, exist_ok=True)
    return output


def self_test() -> None:
    if len(EXPECTED_FIXTURES) != 20:
        raise GateError("expected fixture inventory does not contain 20 definitions")
    if len({(scale, name) for scale in SCALES for name in EXPECTED_FIXTURES}) != 40:
        raise GateError("expected fixture matrix does not contain 40 captures")
    first = bytes((0, 10, 20, 255, 1, 2, 3, 4))
    second = bytes((0, 11, 18, 255, 1, 2, 3, 9))
    metrics = diff_rgba(first, second, width=2, height=1)
    assert metrics.differing_pixels == 2
    assert metrics.differing_channels == 3
    assert metrics.total_absolute_channel_delta == 8
    assert metrics.maximum_channel_delta == 5
    assert metrics.bounding_box == {"x": 0, "y": 0, "width": 2, "height": 1}
    assert metrics.exact_delta_rgba == bytes((0, 1, 2, 0, 0, 0, 0, 5))
    same = diff_rgba(first, first, width=2, height=1)
    assert same.differing_pixels == 0
    assert same.bounding_box is None
    descriptor = {
        "schemaVersion": 1,
        "records": [{"key": "source.scale", "value": "one"}],
    }
    changed_descriptor = {
        "schemaVersion": 1,
        "records": [{"key": "source.scale", "value": "two"}],
    }
    assert public_input_mismatches(descriptor, descriptor) == []
    assert public_input_mismatches(descriptor, changed_descriptor) == [
        {"key": "source.scale", "reference": "one", "candidate": "two"}
    ]
    extended_descriptor = dict(descriptor, unexpected="metadata")
    descriptor_mismatches = public_input_mismatches(
        descriptor, extended_descriptor
    )
    assert len(descriptor_mismatches) == 1
    assert descriptor_mismatches[0]["key"] == "$descriptor"
    assert gate_passes(pixel_failures=0, public_input_failures=0)
    assert not gate_passes(pixel_failures=1, public_input_failures=0)
    assert not gate_passes(pixel_failures=0, public_input_failures=1)
    with tempfile.TemporaryDirectory(prefix="cmdy-renderer-pixel-selftest.") as temp:
        path = Path(temp) / "diff.png"
        write_rgba_png(path, metrics.visual_delta_rgba, 2, 1)
        assert png_dimensions(path.read_bytes()) == (2, 1)
        reference = locate_reference_captures(DEFAULT_REFERENCE_CAPTURES)
        assert reference.archive_sha256 == (
            "5507d54ebe8e453edc9f38d3dbf84ac01ef132ae8370a3a7de39a1624d46188a"
        )
        payloads = read_reference_archive(reference)
        assert len(payloads) == REFERENCE_ARCHIVE_ENTRY_COUNT
        materialized = materialize_reference_captures(
            reference, Path(temp) / "reference"
        )
        assert sha256_file(materialized / "manifest.json") == (
            REFERENCE_MANIFEST_SHA256
        )
        assert sha256_file(materialized / "fixture-index.json") == (
            REFERENCE_FIXTURE_INDEX_SHA256
        )
        corrupt = Path(temp) / "corrupt-corpus"
        corrupt.mkdir()
        shutil.copyfile(reference.lock, corrupt / reference.lock.name)
        shutil.copyfile(
            reference.validator_vector,
            corrupt / reference.validator_vector.name,
        )
        damaged_archive = bytearray(reference.archive.read_bytes())
        damaged_archive[-1] ^= 0x01
        (corrupt / reference.archive.name).write_bytes(damaged_archive)
        try:
            locate_reference_captures(corrupt)
        except GateError as error:
            assert "archive hash mismatch" in str(error)
        else:
            raise AssertionError("one-byte reference archive corruption was accepted")
    for unsafe in ("", "./fixture", "../fixture", "/fixture", "nested/fixture",
                   "nested\\fixture", "fïxture"):
        try:
            canonical_archive_member_name(unsafe)
        except GateError:
            pass
        else:
            raise AssertionError(f"unsafe archive member was accepted: {unsafe!r}")
    print("renderer pixel parity self-test: strict diff and locked corpus checks passed")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    reference = parser.add_mutually_exclusive_group()
    reference.add_argument(
        "--reference-captures",
        type=Path,
        help=(
            "locked historical capture-corpus directory, lock, or archive "
            "(default: vendored ReferenceCorpus; canonical release mode)"
        ),
    )
    reference.add_argument(
        "--reference-build",
        type=Path,
        help=(
            "frozen reference build root or release directory; enables "
            "forensic build-vs-build mode"
        ),
    )
    parser.add_argument(
        "--candidate-build",
        type=Path,
        help="candidate build root/release directory; otherwise build Renderer release",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="new or empty results directory outside the repository (default: /tmp)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help=(
            "test inventory, diff accounting, deterministic PNG encoding, "
            "and the complete locked reference corpus"
        ),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.self_test:
        self_test()
        return 0
    if platform.system() != "Darwin":
        raise GateError("the CmdyGPU pixel gate requires macOS and Metal")
    if platform.machine() != "arm64":
        raise GateError("the frozen CmdyGPU reference build requires arm64")
    reference_build: BuildLayout | None = None
    reference_captures: ReferenceCaptures | None = None
    if arguments.reference_build is not None:
        reference_build = locate_build(arguments.reference_build)
    else:
        capture_argument = arguments.reference_captures
        if capture_argument is None:
            from_environment = os.environ.get("CMDY_RENDERER_REFERENCE_CAPTURES")
            capture_argument = (
                Path(from_environment) if from_environment
                else DEFAULT_REFERENCE_CAPTURES
            )
        reference_captures = locate_reference_captures(capture_argument)
    output = ensure_output_directory(arguments.output)
    print(f"renderer pixel parity results: {output}", flush=True)
    fixture_snapshot = output / "RendererPixelFixture.swift"
    shutil.copyfile(FIXTURE_SOURCE, fixture_snapshot)
    reference_manifest_locked = reference_captures is not None
    if reference_captures is not None:
        reference_output = materialize_reference_captures(
            reference_captures, output / "reference"
        )

    candidate = (
        locate_build(arguments.candidate_build)
        if arguments.candidate_build is not None
        else build_candidate()
    )
    if reference_build is not None and reference_build.release == candidate.release:
        raise GateError(
            "reference and candidate resolve to the same release directory; "
            "refusing a self-comparison"
        )
    collect_environment(
        output, reference_build, candidate, fixture_snapshot,
        reference_captures=reference_captures,
    )
    candidate_runner = compile_runner(
        "candidate", candidate, output, fixture_snapshot
    )
    if reference_captures is None:
        assert reference_build is not None
        reference_runner = compile_runner(
            "reference", reference_build, output, fixture_snapshot
        )
        reference_output = run_fixture("reference", reference_runner, output)
    candidate_output = run_fixture("candidate", candidate_runner, output)
    result, failed = compare_captures(
        reference_output,
        candidate_output,
        output,
        reference_manifest_locked=reference_manifest_locked,
    )
    print(
        f"renderer pixel parity: {result['fixtureCount'] - failed}/"
        f"{result['fixtureCount']} strict exact; "
        f"{result['pixelFailedFixtureCount']} pixel failures, "
        f"{result['publicInputFailedFixtureCount']} public-input failures, "
        f"{result['totalDifferingPixels']} differing pixels",
        flush=True,
    )
    print(f"comparison manifest: {output / 'comparison.json'}", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GateError as error:
        print(f"renderer pixel parity: {error}", file=sys.stderr)
        raise SystemExit(2)
