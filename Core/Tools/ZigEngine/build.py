#!/usr/bin/env python3
"""Build the native engine before SwiftPM, with an explicit source receipt.

SwiftPM currently rejects generated non-Swift plugin sources. A conventional
static archive keeps the Zig compiler and the Swift linker independently
inspectable, without package-manifest side effects or a runtime loader.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
from source_inputs import native_inputs
from apple_toolchain import apple_toolchain, zig_platform_flags

CORE = Path(__file__).resolve().parents[2]
ZIG_VERSION = "0.15.2"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_bytes(path: Path, value: bytes) -> None:
    if path.exists() and path.read_bytes() == value:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(value)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--optimize", choices=["Debug", "ReleaseSafe", "ReleaseFast"], default="ReleaseFast")
    parser.add_argument("--arch", choices=["native", "arm64", "x86_64", "universal"], default="native")
    parser.add_argument("--output", type=Path, default=CORE / ".zig-build")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("The macOS app build requires macOS. Linux remains a separate task.")
    zig_name = os.environ.get("CMDY_ZIG", "zig")
    resolved = shutil.which(zig_name)
    if not resolved:
        raise SystemExit(f"Zig {ZIG_VERSION} is required. Set CMDY_ZIG to its executable or add zig to PATH.")
    zig = Path(resolved).resolve()
    version = subprocess.check_output([str(zig), "version"], text=True).strip()
    if version != ZIG_VERSION:
        raise SystemExit(f"Expected Zig {ZIG_VERSION}, found {version} at {zig}.")
    architectures = ["arm64", "x86_64"] if args.arch == "universal" else [platform.machine() if args.arch == "native" else args.arch]
    if architectures == ["aarch64"]:
        architectures = ["arm64"]
    if any(value not in ["arm64", "x86_64"] for value in architectures):
        raise SystemExit(f"Unsupported macOS build architecture: {architectures}")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with (output / "build.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        inputs = native_inputs(CORE)
        sources = [path for path in inputs if path.is_relative_to(CORE / "Zig")]
        source_hashes = {str(path.relative_to(CORE)): digest(path) for path in inputs}
        identity = {"sources": source_hashes, "zig_version": version, "zig_sha256": digest(zig),
                    "optimize": args.optimize, "architectures": architectures, "minimum_macos": "26.0",
                    "platform_toolchain": apple_toolchain()}
        key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        artifact = output / "artifacts" / key
        archive = artifact / "libcmdy_engine.a"
        receipt_path = artifact / "receipt.json"
        if not archive.exists() or not receipt_path.exists():
            # A failed build remains inspectable; each attempt gets a fresh directory.
            attempts = output / "attempts"
            attempts.mkdir(exist_ok=True)
            attempt = Path(tempfile.mkdtemp(prefix=key[:16] + "-", dir=attempts))
            frozen = attempt / "source"
            frozen.mkdir()
            for path in sources:
                destination = frozen / path.relative_to(CORE / "Zig")
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
            include = attempt / "include"
            platform_sources = attempt / "platform"
            include.mkdir(); platform_sources.mkdir()
            for path in inputs:
                if path.is_relative_to(CORE / "Sources/CmdyNative/include"):
                    destination = include / path.relative_to(CORE / "Sources/CmdyNative/include")
                elif path.is_relative_to(CORE / "Platform"):
                    destination = platform_sources / path.relative_to(CORE / "Platform")
                else:
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
            receipt = dict(identity, source_key=key, processes=[], platform_objects={}, status="building")
            (attempt / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            libraries = []
            for arch in architectures:
                library = attempt / f"libcmdy_engine-{arch}.a"
                target = ("aarch64" if arch == "arm64" else arch) + "-macos.26.0.0"
                objects = []
                for source in sorted(platform_sources.rglob("*")):
                    if source.suffix not in (".c", ".m"):
                        continue
                    obj = attempt / "objects" / arch / source.relative_to(platform_sources).with_suffix(source.suffix + ".o")
                    obj.parent.mkdir(parents=True, exist_ok=True)
                    platform_command = [identity["platform_toolchain"]["clang_path"], "-c", str(source), "-o", str(obj),
                        "-target", arch + "-apple-macosx26.0", "-isysroot", identity["platform_toolchain"]["sdk_path"],
                        "-I", str(include), "-I", str(platform_sources), "-fblocks",
                        {"Debug": "-O0", "ReleaseSafe": "-O2", "ReleaseFast": "-O3"}[args.optimize]]
                    if source.suffix == ".m": platform_command += ["-fobjc-arc"]
                    with (attempt / (arch + "-" + source.name + ".log")).open("wb") as log:
                        process = subprocess.Popen(platform_command, stdout=log, stderr=subprocess.STDOUT)
                        code = process.wait()
                    receipt["processes"].append({"argv": platform_command, "pid": process.pid, "exit_code": code, "reaped": True})
                    if code:
                        receipt["status"] = "failed"
                        (attempt / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
                        raise SystemExit(f"Platform build failed. See {attempt / (arch + '-' + source.name + '.log')}")
                    objects.append(obj)
                receipt["platform_objects"][arch] = [str(obj.relative_to(attempt)) for obj in objects]
                command = [str(zig), "build-lib", str(frozen / "abi.zig"), *map(str, objects), "-lc", "-O" + args.optimize,
                           "-target", target, "-femit-bin=" + str(library),
                           *zig_platform_flags(identity["platform_toolchain"], include, platform_sources),
                           "--cache-dir", str(output / "cache" / arch),
                           "--global-cache-dir", str(output / "global-cache")]
                with (attempt / f"{arch}.log").open("wb") as log:
                    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                    code = process.wait()
                receipt["processes"].append({"argv": command, "pid": process.pid, "exit_code": code, "reaped": True})
                if code:
                    receipt["status"] = "failed"
                    (attempt / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
                    raise SystemExit(f"Native build failed. See {attempt / (arch + '.log')}")
                libraries.append(library)
            combined = attempt / "libcmdy_engine.a"
            if len(libraries) == 1:
                shutil.copy2(libraries[0], combined)
            else:
                command = ["xcrun", "lipo", "-create", *map(str, libraries), "-output", str(combined)]
                with (attempt / "lipo.log").open("wb") as log:
                    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                    code = process.wait()
                receipt["processes"].append({"argv": command, "pid": process.pid, "exit_code": code, "reaped": True})
                if code:
                    receipt["status"] = "failed"
                    (attempt / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
                    raise SystemExit(f"Universal archive build failed. See {attempt / 'lipo.log'}")
            # Ensure a source mutation during compilation cannot be silently admitted.
            current_hashes = {str(path.relative_to(CORE)): digest(path) for path in native_inputs(CORE)}
            if current_hashes != source_hashes or apple_toolchain() != identity["platform_toolchain"]:
                receipt["status"] = "source_changed"
                (attempt / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
                raise SystemExit(f"Native inputs changed during build. Frozen attempt preserved: {attempt}")
            receipt.update(status="pass", archive_sha256=digest(combined))
            (attempt / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            artifact.parent.mkdir(parents=True, exist_ok=True)
            os.replace(attempt, artifact)
        receipt = json.loads(receipt_path.read_text())
        if digest(archive) != receipt["archive_sha256"]:
            raise SystemExit(f"Native archive hash mismatch: {archive}")
        replace_bytes(output / "libcmdy_engine.a", archive.read_bytes())
        replace_bytes(output / "manifest.json", (json.dumps(receipt, indent=2) + "\n").encode())
        # Alternate outputs carry their own header and cannot invalidate the
        # production package. Its bridge header is published only by the
        # default output and checked against SwiftPM's immutable selection.
        header = f'#define CMDY_ZIG_SOURCE_KEY "{key}"\n#define CMDY_ZIG_BUILD_MODE "{args.optimize}"\n'
        replace_bytes(output / "cmdy_engine_build.h", header.encode())
        if output == (CORE / ".zig-build").resolve():
            replace_bytes(CORE / "Sources/CmdyNative/include/cmdy_engine_build.h", header.encode())
        print(f"Zig engine ready ({args.optimize}, {','.join(architectures)}): {output / 'libcmdy_engine.a'}")


if __name__ == "__main__":
    main()
