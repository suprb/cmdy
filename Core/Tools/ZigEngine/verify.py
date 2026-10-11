#!/usr/bin/env python3
"""Reject a missing, stale or damaged native archive before Swift is linked."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re

from source_inputs import native_inputs
from apple_toolchain import apple_toolchain

ARCHITECTURES = {"arm64", "x86_64"}
OPTIMIZATIONS = {"Debug", "ReleaseSafe", "ReleaseFast"}
MINIMUM_MACOS = {"26.0"}
IDENTITY_FIELDS = ("sources", "zig_version", "zig_sha256", "optimize", "architectures", "minimum_macos", "platform_toolchain")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(core: Path) -> dict:
    output = core / ".zig-build"
    manifest = output / "manifest.json"
    archive = output / "libcmdy_engine.a"
    try:
        receipt = json.loads(manifest.read_text())
        if not isinstance(receipt, dict):
            raise ValueError("native receipt must be an object")
        architectures = receipt["architectures"]
        if (not isinstance(architectures, list) or not architectures
                or any(not isinstance(value, str) or value not in ARCHITECTURES for value in architectures)
                or len(set(architectures)) != len(architectures)):
            raise ValueError("native receipt contains unsupported or duplicate architectures")
        if receipt["optimize"] not in OPTIMIZATIONS:
            raise ValueError("native receipt contains an unsupported optimization mode")
        if receipt["minimum_macos"] not in MINIMUM_MACOS:
            raise ValueError("native receipt contains an unsupported minimum macOS version")
        if receipt["zig_version"] != "0.15.2":
            raise ValueError("native receipt does not use the pinned Zig version")
        if not isinstance(receipt["zig_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", receipt["zig_sha256"]):
            raise ValueError("native receipt contains an invalid Zig checksum")
        identity = {key: receipt[key] for key in IDENTITY_FIELDS}
        if receipt["platform_toolchain"] != apple_toolchain():
            raise ValueError("native Apple SDK or platform compiler changed")
        source_key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        if receipt["source_key"] != source_key:
            raise ValueError("native receipt build identity does not match its source key")
        expected = receipt["sources"]
        actual = {str(path.relative_to(core)): digest(path) for path in native_inputs(core)}
        if receipt["status"] != "pass" or expected != actual:
            raise ValueError("native source hashes do not match the archive")
        artifact = output / "artifacts" / source_key
        if json.loads((artifact / "receipt.json").read_text()) != receipt:
            raise ValueError("immutable native artifact receipt does not match the selected build")
        if digest(artifact / "libcmdy_engine.a") != receipt["archive_sha256"]:
            raise ValueError("immutable native archive checksum does not match its receipt")
        if digest(archive) != receipt["archive_sha256"]:
            raise ValueError("native archive checksum does not match its receipt")
        stamp = (core / "Sources/CmdyNative/include/cmdy_engine_build.h").read_text()
        expected_stamp = (f'#define CMDY_ZIG_SOURCE_KEY "{source_key}"\n'
                          f'#define CMDY_ZIG_BUILD_MODE "{receipt["optimize"]}"\n')
        if stamp != expected_stamp:
            raise ValueError("native build header does not match the archive")
        return receipt
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ValueError(f"CMDY Zig engine needs rebuilding: {error}. Run ./build.sh from the repository root.") from error


def verification_source(receipt: dict) -> str:
    """SwiftPM compiles this in the consuming target's architecture and mode."""
    supported = " || ".join(f"arch({arch})" for arch in receipt["architectures"])
    result = (f'// Verified native archive: {receipt["source_key"]}\n'
              f'#if !CMDY_ZIG_SELECTED_{receipt["source_key"]}\n'
              '#error("CMDY native archive selection changed. Use ./build.sh or add --manifest-cache none --disable-build-manifest-caching to SwiftPM.")\n'
              '#endif\n'
              f'#if !({supported})\n'
              '#error("CMDY native archive does not contain this architecture. Run ./build.sh with matching --arch or --triple flags.")\n'
              '#endif\n')
    if receipt["optimize"] == "Debug":
        result += ('#if !DEBUG\n'
                   '#error("CMDY native Debug archive cannot be used in a release Swift build. Run ./build.sh -c release.")\n'
                   '#endif\n')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        receipt = verify(args.core.resolve())
    except ValueError as error:
        raise SystemExit(str(error))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(verification_source(receipt))
    print("CMDY native archive matches its source and build receipt")


if __name__ == "__main__":
    main()
