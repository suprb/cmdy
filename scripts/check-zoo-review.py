#!/usr/bin/env python3
"""Generate deterministic TUI-zoo evidence and verify human review records.

The capture command validates every PNG and writes an unopinionated manifest.
The review command only checks a separately authored human review record; it
never creates a review or changes its decision.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import stat
import struct
import sys
import tempfile
import zlib
from pathlib import Path
from typing import Sequence


CAPTURE_SCHEMA_VERSION = 1
CAPTURE_KIND = "cmdy-tui-zoo-capture-manifest"
REVIEW_SCHEMA_VERSION = 1
REVIEW_KIND = "cmdy-tui-zoo-visual-review"
REQUIRED_STATION_IDS = (
    "00-shell",
    "01-vim-open",
    "02-vim-scrolled",
    "03-vim-split",
    "04-man",
    "05-less",
    "06-less-end",
    "07-htop",
    "08-tmux",
    "09-tmux-echo",
    "10-tmux-split",
    "11-cat-10mb",
    "99-shell-after",
)
CLAUDE_STATION_ID = "12-claude-code"
CLAUDE_STATUSES = frozenset(("present", "skipped"))
REVIEW_DECISIONS = frozenset(("approved", "rejected", "pending"))
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_MAX_FILE_BYTES = 256 * 1024 * 1024
PNG_MAX_DECODED_BYTES = 512 * 1024 * 1024
PNG_MAX_DIMENSION = 32768
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
RFC3339_UTC_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\Z"
)


class ZooEvidenceError(RuntimeError):
    pass


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(
        value, ensure_ascii=False, indent=2, sort_keys=True,
    ) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _positive_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ZooEvidenceError(f"{label} must be a positive integer")
    return value


def _exact_keys(value: dict[str, object], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ZooEvidenceError(
            f"{label} fields differ (missing={missing}, extra={extra})"
        )


def _read_regular_file(path: Path, label: str, max_bytes: int | None = None) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        raise ZooEvidenceError(f"cannot inspect {label} {path}: {error}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ZooEvidenceError(f"{label} must be a regular non-symlink file: {path}")
    if max_bytes is not None and before.st_size > max_bytes:
        raise ZooEvidenceError(
            f"{label} exceeds {max_bytes} bytes: {path} ({before.st_size})"
        )
    try:
        value = path.read_bytes()
        after = path.lstat()
    except OSError as error:
        raise ZooEvidenceError(f"cannot read {label} {path}: {error}") from error
    identity_before = (
        before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
    )
    identity_after = (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
    )
    if identity_before != identity_after or len(value) != after.st_size:
        raise ZooEvidenceError(f"{label} changed while it was read: {path}")
    return value


def _hash_regular_file(
    path: Path, label: str, *, require_executable: bool = False,
) -> tuple[int, str]:
    try:
        before = path.lstat()
    except OSError as error:
        raise ZooEvidenceError(f"cannot inspect {label} {path}: {error}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ZooEvidenceError(f"{label} must be a regular non-symlink file: {path}")
    if before.st_size <= 0:
        raise ZooEvidenceError(f"{label} must not be empty: {path}")
    if require_executable and before.st_mode & 0o111 == 0:
        raise ZooEvidenceError(f"{label} is not executable: {path}")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        after = path.lstat()
    except OSError as error:
        raise ZooEvidenceError(f"cannot hash {label} {path}: {error}") from error
    identity_before = (
        before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
    )
    identity_after = (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
    )
    if identity_before != identity_after:
        raise ZooEvidenceError(f"{label} changed while it was hashed: {path}")
    return before.st_size, digest.hexdigest()


def _pass_dimensions(
    width: int, height: int, x_start: int, y_start: int, x_step: int, y_step: int,
) -> tuple[int, int]:
    pass_width = 0 if width <= x_start else (width - x_start + x_step - 1) // x_step
    pass_height = 0 if height <= y_start else (height - y_start + y_step - 1) // y_step
    return pass_width, pass_height


def _png_passes(width: int, height: int, interlace: int) -> list[tuple[int, int]]:
    if interlace == 0:
        return [(width, height)]
    adam7 = (
        (0, 0, 8, 8),
        (4, 0, 8, 8),
        (0, 4, 4, 8),
        (2, 0, 4, 4),
        (0, 2, 2, 4),
        (1, 0, 2, 2),
        (0, 1, 1, 2),
    )
    return [
        _pass_dimensions(width, height, x_start, y_start, x_step, y_step)
        for x_start, y_start, x_step, y_step in adam7
    ]


def validate_png(path: Path) -> tuple[int, int, int, str]:
    data = _read_regular_file(path, "PNG", PNG_MAX_FILE_BYTES)
    if not data.startswith(PNG_SIGNATURE):
        raise ZooEvidenceError(f"PNG signature is invalid: {path}")

    offset = len(PNG_SIGNATURE)
    chunks: list[tuple[bytes, bytes]] = []
    idat_parts: list[bytes] = []
    seen_ihdr = False
    seen_idat = False
    idat_finished = False
    seen_iend = False
    seen_plte = False
    while offset < len(data):
        if len(data) - offset < 12:
            raise ZooEvidenceError(f"PNG has a truncated chunk header: {path}")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        chunk_type = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise ZooEvidenceError(f"PNG has a truncated chunk payload: {path}")
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length:end])[0]
        actual_crc = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            name = chunk_type.decode("ascii", errors="replace")
            raise ZooEvidenceError(f"PNG chunk {name} has an invalid CRC: {path}")
        if len(chunk_type) != 4 or not all(
            65 <= character <= 90 or 97 <= character <= 122
            for character in chunk_type
        ):
            raise ZooEvidenceError(f"PNG has an invalid chunk type: {path}")
        if chunk_type[2] & 0x20:
            raise ZooEvidenceError(f"PNG chunk has a nonzero reserved bit: {path}")
        if not chunks and chunk_type != b"IHDR":
            raise ZooEvidenceError(f"PNG first chunk is not IHDR: {path}")
        if chunk_type == b"IHDR":
            if seen_ihdr or length != 13:
                raise ZooEvidenceError(f"PNG has an invalid IHDR: {path}")
            seen_ihdr = True
        elif not seen_ihdr:
            raise ZooEvidenceError(f"PNG is missing IHDR: {path}")
        elif chunk_type == b"PLTE":
            if seen_plte or seen_idat or length == 0 or length % 3 or length > 768:
                raise ZooEvidenceError(f"PNG has an invalid PLTE: {path}")
            seen_plte = True
        elif chunk_type == b"IDAT":
            if idat_finished:
                raise ZooEvidenceError(f"PNG IDAT chunks are not consecutive: {path}")
            seen_idat = True
            idat_parts.append(payload)
        elif chunk_type == b"IEND":
            if seen_iend or length != 0 or not seen_idat:
                raise ZooEvidenceError(f"PNG has an invalid IEND: {path}")
            seen_iend = True
            if end != len(data):
                raise ZooEvidenceError(f"PNG has bytes after IEND: {path}")
        elif chunk_type[0] & 0x20 == 0:
            name = chunk_type.decode("ascii", errors="replace")
            raise ZooEvidenceError(f"PNG has an unknown critical chunk {name}: {path}")
        if seen_idat and chunk_type not in (b"IDAT", b"IEND"):
            idat_finished = True
        chunks.append((chunk_type, payload))
        offset = end

    if not seen_ihdr or not seen_idat or not seen_iend:
        raise ZooEvidenceError(f"PNG is missing IHDR, IDAT, or IEND: {path}")

    ihdr = chunks[0][1]
    width, height, bit_depth, color_type, compression, filtering, interlace = (
        struct.unpack(">IIBBBBB", ihdr)
    )
    if not (1 <= width <= PNG_MAX_DIMENSION and 1 <= height <= PNG_MAX_DIMENSION):
        raise ZooEvidenceError(f"PNG dimensions are invalid: {path} ({width}x{height})")
    valid_depths = {
        0: frozenset((1, 2, 4, 8, 16)),
        2: frozenset((8, 16)),
        3: frozenset((1, 2, 4, 8)),
        4: frozenset((8, 16)),
        6: frozenset((8, 16)),
    }
    if color_type not in valid_depths or bit_depth not in valid_depths[color_type]:
        raise ZooEvidenceError(
            f"PNG bit depth/color type is invalid: {path} ({bit_depth}/{color_type})"
        )
    if compression != 0 or filtering != 0 or interlace not in (0, 1):
        raise ZooEvidenceError(f"PNG encoding methods are invalid: {path}")
    if color_type == 3 and not seen_plte:
        raise ZooEvidenceError(f"indexed PNG is missing PLTE: {path}")
    if color_type in (0, 4) and seen_plte:
        raise ZooEvidenceError(f"grayscale PNG cannot contain PLTE: {path}")
    if color_type == 3:
        palette = next(payload for kind, payload in chunks if kind == b"PLTE")
        if len(palette) // 3 > 1 << bit_depth:
            raise ZooEvidenceError(f"indexed PNG palette exceeds its bit depth: {path}")

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    passes = _png_passes(width, height, interlace)
    pass_layout: list[tuple[int, int]] = []
    expected_decoded = 0
    for pass_width, pass_height in passes:
        if pass_width == 0 or pass_height == 0:
            continue
        row_bytes = (pass_width * channels * bit_depth + 7) // 8
        pass_layout.append((row_bytes, pass_height))
        expected_decoded += (row_bytes + 1) * pass_height
    if expected_decoded <= 0 or expected_decoded > PNG_MAX_DECODED_BYTES:
        raise ZooEvidenceError(
            f"PNG decoded size is invalid: {path} ({expected_decoded} bytes)"
        )
    compressed = b"".join(idat_parts)
    try:
        decompressor = zlib.decompressobj()
        decoded = decompressor.decompress(compressed, expected_decoded + 1)
        if decompressor.unconsumed_tail or len(decoded) > expected_decoded:
            raise ZooEvidenceError(f"PNG decoded payload exceeds its dimensions: {path}")
        decoded += decompressor.flush(expected_decoded + 1 - len(decoded))
    except zlib.error as error:
        raise ZooEvidenceError(f"PNG IDAT stream is invalid: {path}: {error}") from error
    if (
        not decompressor.eof
        or decompressor.unused_data
        or decompressor.unconsumed_tail
        or len(decoded) != expected_decoded
    ):
        raise ZooEvidenceError(
            f"PNG decoded payload length is invalid: {path} "
            f"({len(decoded)} != {expected_decoded})"
        )
    decoded_offset = 0
    for row_bytes, pass_height in pass_layout:
        for _ in range(pass_height):
            if decoded[decoded_offset] > 4:
                raise ZooEvidenceError(f"PNG has an invalid row filter: {path}")
            decoded_offset += row_bytes + 1
    if decoded_offset != len(decoded):
        raise ZooEvidenceError(f"PNG row layout is inconsistent: {path}")
    return width, height, len(data), sha256_bytes(data)


def build_capture_manifest(
    captures_directory: Path,
    app_binary: Path,
    claude_status: str,
    claude_skip_reason: str | None = None,
    expected_app_sha256: str | None = None,
) -> dict[str, object]:
    if captures_directory.is_symlink() or not captures_directory.is_dir():
        raise ZooEvidenceError(
            f"captures must be a real directory: {captures_directory}"
        )
    if claude_status not in CLAUDE_STATUSES:
        raise ZooEvidenceError(f"unsupported Claude status: {claude_status!r}")
    if claude_status == "skipped":
        if not isinstance(claude_skip_reason, str) or not claude_skip_reason.strip():
            raise ZooEvidenceError("skipped Claude capture requires a nonempty reason")
        claude = {
            "reason": claude_skip_reason.strip(),
            "stationID": CLAUDE_STATION_ID,
            "status": "skipped",
        }
    else:
        if claude_skip_reason is not None:
            raise ZooEvidenceError("present Claude capture cannot have a skip reason")
        claude = {"stationID": CLAUDE_STATION_ID, "status": "present"}

    expected_ids = list(REQUIRED_STATION_IDS)
    if claude_status == "present":
        expected_ids.insert(-1, CLAUDE_STATION_ID)
    expected_files = {f"{station_id}.png" for station_id in expected_ids}
    actual_files = {
        path.name for path in captures_directory.iterdir()
        if path.name.lower().endswith(".png")
    }
    missing = sorted(expected_files - actual_files)
    extra = sorted(actual_files - expected_files)
    if missing or extra:
        raise ZooEvidenceError(
            f"zoo PNG set differs (missing={missing}, extra={extra})"
        )

    captures: list[dict[str, object]] = []
    for station_id in expected_ids:
        filename = f"{station_id}.png"
        width, height, size, digest = validate_png(captures_directory / filename)
        captures.append({
            "file": filename,
            "height": height,
            "sha256": digest,
            "size": size,
            "stationID": station_id,
            "width": width,
        })
    app_size, app_digest = _hash_regular_file(
        app_binary, "app binary", require_executable=True,
    )
    if expected_app_sha256 is not None:
        if not SHA256_RE.fullmatch(expected_app_sha256):
            raise ZooEvidenceError("expected app SHA-256 must be 64 lowercase hex digits")
        if app_digest != expected_app_sha256:
            raise ZooEvidenceError(
                "app binary changed after the pre-launch SHA-256 was recorded"
            )
    return {
        "appBinary": {
            "name": app_binary.name,
            "sha256": app_digest,
            "size": app_size,
        },
        "captureCount": len(captures),
        "captures": captures,
        "claude": claude,
        "kind": CAPTURE_KIND,
        "requiredStationIDs": list(REQUIRED_STATION_IDS),
        "schemaVersion": CAPTURE_SCHEMA_VERSION,
    }


def validate_capture_manifest(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ZooEvidenceError("capture manifest root must be an object")
    _exact_keys(value, {
        "appBinary", "captureCount", "captures", "claude", "kind",
        "requiredStationIDs", "schemaVersion",
    }, "capture manifest")
    if value["schemaVersion"] != CAPTURE_SCHEMA_VERSION or isinstance(
        value["schemaVersion"], bool
    ):
        raise ZooEvidenceError("unsupported capture manifest schemaVersion")
    if value["kind"] != CAPTURE_KIND:
        raise ZooEvidenceError("unsupported capture manifest kind")
    if value["requiredStationIDs"] != list(REQUIRED_STATION_IDS):
        raise ZooEvidenceError("capture manifest mandatory stations differ from policy")

    app = value["appBinary"]
    if not isinstance(app, dict):
        raise ZooEvidenceError("appBinary must be an object")
    _exact_keys(app, {"name", "sha256", "size"}, "appBinary")
    if (
        not isinstance(app["name"], str)
        or not app["name"]
        or Path(app["name"]).name != app["name"]
        or any(character in app["name"] for character in "\x00\r\n")
    ):
        raise ZooEvidenceError("appBinary.name must be a plain filename")
    _positive_int(app["size"], "appBinary.size")
    if not isinstance(app["sha256"], str) or not SHA256_RE.fullmatch(app["sha256"]):
        raise ZooEvidenceError("appBinary.sha256 must be lowercase SHA-256")

    claude = value["claude"]
    if not isinstance(claude, dict):
        raise ZooEvidenceError("claude must be an object")
    status = claude.get("status")
    if status == "present":
        _exact_keys(claude, {"stationID", "status"}, "claude")
    elif status == "skipped":
        _exact_keys(claude, {"reason", "stationID", "status"}, "claude")
        if not isinstance(claude["reason"], str) or not claude["reason"].strip():
            raise ZooEvidenceError("skipped Claude status needs a reason")
    else:
        raise ZooEvidenceError("Claude status must be present or skipped")
    if claude["stationID"] != CLAUDE_STATION_ID:
        raise ZooEvidenceError("Claude station ID differs from policy")

    captures = value["captures"]
    if not isinstance(captures, list):
        raise ZooEvidenceError("captures must be an array")
    capture_count = _positive_int(value["captureCount"], "captureCount")
    if capture_count != len(captures):
        raise ZooEvidenceError("captureCount does not match captures")
    expected_ids = list(REQUIRED_STATION_IDS)
    if status == "present":
        expected_ids.insert(-1, CLAUDE_STATION_ID)
    actual_ids: list[str] = []
    for index, capture in enumerate(captures):
        if not isinstance(capture, dict):
            raise ZooEvidenceError(f"capture {index} must be an object")
        _exact_keys(capture, {
            "file", "height", "sha256", "size", "stationID", "width",
        }, f"capture {index}")
        station_id = capture["stationID"]
        if not isinstance(station_id, str):
            raise ZooEvidenceError(f"capture {index} stationID must be a string")
        if capture["file"] != f"{station_id}.png":
            raise ZooEvidenceError(f"capture {index} filename does not match stationID")
        for field in ("size", "width", "height"):
            _positive_int(capture[field], f"capture {index} {field}")
        if (
            not isinstance(capture["sha256"], str)
            or not SHA256_RE.fullmatch(capture["sha256"])
        ):
            raise ZooEvidenceError(f"capture {index} sha256 must be lowercase SHA-256")
        actual_ids.append(station_id)
    if actual_ids != expected_ids:
        raise ZooEvidenceError(
            f"capture station order/coverage differs (expected={expected_ids}, "
            f"actual={actual_ids})"
        )
    return value


def _write_atomic(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ZooEvidenceError(f"refusing to replace symlink output: {path}")
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=path.parent, prefix=f".{path.name}.", delete=False,
        ) as handle:
            temporary_name = handle.name
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def load_capture_manifest(path: Path) -> tuple[dict[str, object], bytes]:
    raw = _read_regular_file(path, "capture manifest", 4 * 1024 * 1024)
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ZooEvidenceError(f"capture manifest is not valid UTF-8 JSON: {error}") from error
    manifest = validate_capture_manifest(value)
    if raw != canonical_bytes(manifest):
        raise ZooEvidenceError("capture manifest is not canonical JSON")
    return manifest, raw


def _validate_review_timestamp(value: object) -> None:
    if not isinstance(value, str) or not RFC3339_UTC_RE.fullmatch(value):
        raise ZooEvidenceError("reviewedAt must be an RFC3339 UTC timestamp ending in Z")
    try:
        dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ZooEvidenceError(f"reviewedAt is not a real timestamp: {value}") from error


def verify_review(
    manifest_path: Path,
    review_path: Path,
    required_decision: str | None = None,
) -> tuple[str, str, int, str]:
    manifest, raw_manifest = load_capture_manifest(manifest_path)
    raw_review = _read_regular_file(review_path, "review record", 1024 * 1024)
    try:
        review = json.loads(raw_review)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ZooEvidenceError(f"review record is not valid UTF-8 JSON: {error}") from error
    if not isinstance(review, dict):
        raise ZooEvidenceError("review record root must be an object")
    required_fields = {
        "decision", "kind", "manifestSHA256", "reviewedAt", "reviewer",
        "schemaVersion",
    }
    allowed_fields = required_fields | {"notes"}
    if not required_fields.issubset(review) or not set(review).issubset(allowed_fields):
        missing = sorted(required_fields - set(review))
        extra = sorted(set(review) - allowed_fields)
        raise ZooEvidenceError(
            f"review record fields differ (missing={missing}, extra={extra})"
        )
    if review["schemaVersion"] != REVIEW_SCHEMA_VERSION or isinstance(
        review["schemaVersion"], bool
    ):
        raise ZooEvidenceError("unsupported review schemaVersion")
    if review["kind"] != REVIEW_KIND:
        raise ZooEvidenceError("unsupported review kind")
    decision = review["decision"]
    if not isinstance(decision, str) or decision not in REVIEW_DECISIONS:
        raise ZooEvidenceError("review decision must be approved, rejected, or pending")
    reviewer = review["reviewer"]
    if not isinstance(reviewer, str) or not reviewer.strip():
        raise ZooEvidenceError("reviewer must be a nonempty human-supplied identity")
    _validate_review_timestamp(review["reviewedAt"])
    if "notes" in review and not isinstance(review["notes"], str):
        raise ZooEvidenceError("review notes must be a string")
    if decision == "rejected" and not str(review.get("notes", "")).strip():
        raise ZooEvidenceError("rejected review requires nonempty notes")
    expected_hash = sha256_bytes(raw_manifest)
    if review["manifestSHA256"] != expected_hash:
        raise ZooEvidenceError(
            "review manifestSHA256 does not match the exact capture manifest bytes"
        )
    if required_decision is not None and decision != required_decision:
        raise ZooEvidenceError(
            f"review decision is {decision}, required {required_decision}"
        )
    claude_status = str(manifest["claude"]["status"])
    return decision, expected_hash, int(manifest["captureCount"]), claude_status


def _command_capture(args: argparse.Namespace) -> int:
    manifest = build_capture_manifest(
        args.captures,
        args.app_binary,
        args.claude_status,
        args.claude_skip_reason,
        args.expected_app_sha256,
    )
    validate_capture_manifest(manifest)
    raw = canonical_bytes(manifest)
    _write_atomic(args.output, raw)
    print(
        "ZOO_CAPTURE_MANIFEST "
        f"sha256={sha256_bytes(raw)} captures={manifest['captureCount']} "
        f"claude={manifest['claude']['status']} output={args.output}"
    )
    return 0


def _command_review(args: argparse.Namespace) -> int:
    decision, manifest_hash, capture_count, claude_status = verify_review(
        args.manifest, args.review, args.require_decision,
    )
    print(
        "ZOO_REVIEW verified "
        f"decision={decision} manifest_sha256={manifest_hash} "
        f"captures={capture_count} claude={claude_status}"
    )
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    capture = commands.add_parser(
        "capture-manifest",
        help="validate zoo PNGs and write a deterministic capture manifest",
    )
    capture.add_argument("--captures", type=Path, required=True)
    capture.add_argument("--app-binary", type=Path, required=True)
    capture.add_argument("--expected-app-sha256", required=True)
    capture.add_argument("--claude-status", choices=sorted(CLAUDE_STATUSES), required=True)
    capture.add_argument("--claude-skip-reason")
    capture.add_argument("--output", type=Path, required=True)
    capture.set_defaults(handler=_command_capture)

    review = commands.add_parser(
        "verify-review",
        help="verify a human review bound to the exact capture-manifest SHA-256",
    )
    review.add_argument("--manifest", type=Path, required=True)
    review.add_argument("--review", type=Path, required=True)
    review.add_argument("--require-decision", choices=sorted(REVIEW_DECISIONS))
    review.set_defaults(handler=_command_review)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except ZooEvidenceError as error:
        print(f"zoo evidence check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
