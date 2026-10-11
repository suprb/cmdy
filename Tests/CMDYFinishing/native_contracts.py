"""Run native ownership, allocator and Metal contracts on the selected archive."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Core/Tools/ZigEngine"))
from apple_toolchain import apple_toolchain, zig_platform_flags, platform_link_flags

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--contracts-only", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    native = ROOT / "Core/.zig-build"
    receipt = json.loads((native / "manifest.json").read_text())
    artifact = native / "artifacts" / receipt["source_key"]
    archive = artifact / "libcmdy_engine.a"
    record = dict(status="running", sourceKey=receipt["source_key"], nativeSHA256=hashlib.sha256(archive.read_bytes()).hexdigest(), commands=[])
    source_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
        for directory in (ROOT / "Tests/RendererPort", ROOT / "Core/Platform", ROOT / "Core/Sources/CmdyNative/include")
        for p in directory.rglob("*") if p.is_file() and p.suffix in (".m", ".h")}
    record["sourceHashes"] = source_hashes
    def run(label, command):
        row = dict(label=label, command=command); record["commands"].append(row)
        with (output / (label + ".log")).open("x") as log:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            row["pid"] = process.pid
            try: row["exitCode"] = process.wait(timeout=300)
            except subprocess.TimeoutExpired: process.kill(); process.wait(); raise
            finally:
                row["reaped"] = process.poll() is not None
                (output / "result.json").write_text(json.dumps(record, indent=2))
        if row["exitCode"]: raise RuntimeError(label + " failed")
    try:
        zig = subprocess.check_output([str(ROOT / "scripts/bootstrap-zig.sh")], text=True).strip()
        objects = [str(artifact / name) for name in receipt["platform_objects"]["arm64"]]
        for mode in (() if args.contracts_only else ("Debug", "ReleaseSafe")):
            run("zig-" + mode, [zig, "test", str(ROOT / "Core/Zig/tests.zig"), *objects, "-lc", "-O" + mode,
                *zig_platform_flags(apple_toolchain(), ROOT / "Core/Sources/CmdyNative/include", ROOT / "Core/Platform"),
                *platform_link_flags(), "-target", "aarch64-macos.26.0.0",
                "--cache-dir", str(output / "cache"), "--global-cache-dir", str(output / "global-cache")])
        for name in ("CapacitySession", "ModelPublishedSession", "PublishedSession", "TimedSession", "ViewportFrames", "TargetCommitOwnership", "CancelledPacingSession"):
            executable = output / name
            selected = archive
            replacements = ["commit", "encoder_end"] if name in ("ModelPublishedSession", "PublishedSession", "TimedSession", "TargetCommitOwnership", "CancelledPacingSession") else []
            if name in ("ModelPublishedSession", "PublishedSession", "TimedSession", "CancelledPacingSession"): replacements.append("presented")
            if name == "CancelledPacingSession": replacements.append("uptime")
            if replacements:
                instrument = output / (name + "-platform.o")
                run(name + "-platform", ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-std=c11", "-O2", "-mmacosx-version-min=26.0",
                    "-ICore/Sources/CmdyNative/include", "-ICore/Platform",
                    *[f"-Dcmdy_gpu_apple_{part}=fixture_{part}_impl" for part in replacements],
                    "-c", "Core/Platform/platform_gpu.m", "-o", str(instrument)])
                selected = output / (name + ".a"); shutil.copy2(archive, selected)
                run(name + "-remove", ["xcrun", "ar", "-d", str(selected), "platform_gpu.m.o"])
                run(name + "-insert", ["xcrun", "ar", "-r", str(selected), str(instrument)])
            run(name + "-build", ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-std=c11", "-O2", "-mmacosx-version-min=26.0",
                *(["-DCMDY_TARGET_INSTRUMENTED=1"] if name == "TargetCommitOwnership" else []),
                "-ICore/Sources/CmdyNative/include", "-ICore/Platform", str(ROOT / "Tests/RendererPort" / (name + ".m")),
                str(selected), *platform_link_flags(), "-o", str(executable)])
            run(name, [str(executable)])
        record["status"] = "pass"
    except BaseException as error: record.update(status="fail", error=repr(error)); raise
    finally:
        record["sourceInputsUnchanged"] = all(p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest() == digest
            for name, digest in source_hashes.items() for p in (Path(name),))
        if not record["sourceInputsUnchanged"]:
            record.update(status="fail", error="Native contract sources changed during execution")
        (output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        if not record["sourceInputsUnchanged"]: raise RuntimeError(record["error"])

if __name__ == "__main__": main()
