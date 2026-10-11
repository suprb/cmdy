"""Package completed normal release products with frozen source/artifact identity."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "Tests/NativePerformance"))
import prepare

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    products = (REPO / ".build/release").resolve()
    native = REPO / "Core/.zig-build"
    receipt = prepare.read_json(native / "manifest.json")
    assert receipt["status"] == "pass" and receipt["optimize"] == "ReleaseFast"
    subprocess.run([sys.executable, str(REPO / "Core/Tools/ZigEngine/verify.py"), "--core", str(REPO / "Core")], check=True)
    prepare.copy_file(products / "cmdy", output / "build/cmdy")
    prepare.copy_tree(products / "CmdyNative.build", output / "build/CmdyNative.build")
    for bundle in prepare.BUNDLES: prepare.copy_tree(products / bundle, output / "build" / bundle)
    for name in ("libcmdy_engine.a", "manifest.json"): prepare.copy_file(native / name, output / "native" / name)
    for name in ("Cmdy.entitlements", "VERSION"): prepare.copy_file(REPO / name, output / "packaging" / name)
    prepare.identity_probe(output, receipt)
    app, helper = prepare.assemble_bundle(output, args.template.resolve(), output / "packaging", REPO)
    names = set(subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=REPO).decode().split("\0"))
    names = sorted(name for name in names if name and (REPO / name).is_file()
                   and Path(name).suffix in (".swift", ".zig", ".c", ".h", ".m", ".metal", ".json", ".sh", ".py")
                   and not name.startswith(("docs/", "website/", "site/", "Experiments/")))
    hashes = {name: prepare.sha(REPO / name) for name in names}
    with tarfile.open(output / "source.tar.gz", "w:gz") as archive:
        for name in names: archive.add(REPO / name, arcname=name, recursive=False)
    assert all(prepare.sha(REPO / name) == value for name, value in hashes.items())
    prepare.write_json(output / "source-hashes.json", hashes)
    prepare.write_json(output / "package.json", dict(status="packaged-validation-pending", app=str(app),
        executableSHA256=prepare.sha(app / "Contents/MacOS/cmdy"), rawExecutableSHA256=prepare.sha(products / "cmdy"),
        nativeSourceKey=receipt["source_key"], nativeArchiveSHA256=receipt["archive_sha256"],
        sourceArchiveSHA256=prepare.sha(output / "source.tar.gz"), sourceFiles=len(hashes),
        installed=False, published=False, notarized=False))
    print(app)

if __name__ == "__main__": main()
