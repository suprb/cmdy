#!/usr/bin/env python3
"""Freeze a qualified normal CMDY app for later comparisons, without running it.

This does not build, install, activate, measure, or approve an application. The
source archive and completed app evidence are explicit inputs: a dirty checkout
or a newer SwiftPM build cannot silently replace an already qualified baseline.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tarfile


ROOT = Path(__file__).resolve().parents[2]
POLICY_SHA256 = "f2b525aa70d86c41ab8809fd3017ea03ecbdccaf9a6a879051a997c928cfbfe5"
SUITES = ("scroll", "wheel", "reflow", "graphics", "shader")
SYMBOLS = ("_cmdy_zig_terminal_create", "_cmdy_zig_line_render_snapshot",
           "_cmdy_zig_line_snapshot_from_cells", "_cmdy_shape_line",
           "_cmdy_gpu_draw", "_cmdy_render_row_create")
BUNDLES = ("Kit_CmdyKit.bundle", "ProductIdentity_ProductIdentity.bundle")
REFERENCES = ("ACTIONS.md", "BUILDING.md", "CHANNELS.md", "EXTENSIONS.md",
              "EXTENSION_PROTOCOL.md", "MARKETPLACE.md", "PLATFORM.md",
              "SURFACE_PROTOCOL.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CEF-LICENSE.txt",
              "Schemas/action-manifest-v1.schema.json", "Schemas/extension-manifest-v1.schema.json",
              "Schemas/surface-v1.schema.json")
NATIVE_IDENTITY = ("sources", "zig_version", "zig_sha256", "optimize", "architectures",
                   "minimum_macos", "platform_toolchain")
FRAMEWORKS = ("AppKit", "Foundation", "CoreGraphics", "CoreText", "Metal", "MetalKit",
              "QuartzCore", "ImageIO", "UniformTypeIdentifiers")


class PreparationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PreparationError(message)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha(path: Path) -> str:
    require(path.is_file() and not path.is_symlink(), f"Not a regular input file: {path}")
    with path.open("rb") as stream:
        value = hashlib.file_digest(stream, "sha256")
    return value.hexdigest()


def relative(value: str) -> Path:
    require(isinstance(value, str) and bool(value), "Empty or invalid relative path")
    p = PurePosixPath(value)
    require(value != "." and not p.is_absolute() and ".." not in p.parts and str(p) == value,
            f"Unsafe or noncanonical path: {value!r}")
    return Path(*p.parts)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text())
    require(isinstance(value, dict), f"Expected a JSON object: {path}")
    return value


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def inventory(root: Path) -> dict:
    require(root.is_dir() and not root.is_symlink(), f"Not a directory: {root}")
    result = {}
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), f"Symlink in frozen input: {path}")
        if path.is_dir():
            continue
        require(path.is_file(), f"Nonregular frozen input: {path}")
        result[path.relative_to(root).as_posix()] = {
            "sha256": sha(path), "size": path.stat().st_size,
            "executable": bool(path.stat().st_mode & 0o111),
        }
    return result


def copy_file(source: Path, target: Path, expected: str | None = None) -> None:
    before = sha(source)
    require(expected is None or before == expected, f"Input checksum differs: {source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    require(not target.exists(), f"Refusing to overwrite: {target}")
    shutil.copy2(source, target)
    require(sha(source) == before == sha(target), f"Input changed while copying: {source}")


def copy_tree(source: Path, target: Path) -> None:
    before = inventory(source)
    shutil.copytree(source, target)
    require(before == inventory(source) == inventory(target), f"Tree changed while copying: {source}")


def evidence(q: dict, root: Path, name: str) -> Path:
    path = root / relative(name)
    expected = q.get("evidence", {}).get(name)
    require(isinstance(expected, dict), f"Qualification does not bind evidence: {name}")
    require(sha(path) == expected.get("sha256") and path.stat().st_size == expected.get("size"),
            f"Qualification evidence differs: {name}")
    return path


def qualified_inputs(qualification: Path) -> tuple[dict, dict, dict, list[Path]]:
    q = read_json(qualification)
    require(q.get("status") == "library_and_normal_macos_app_integration_pass",
            "A completed normal app qualification is required")
    require(q.get("performance_benchmarks_run") is False and q.get("not_performance_admission") is True,
            "Expected explicit correctness-only qualification")
    directory = qualification.parent
    manifest_name = "schedule-active-source-manifest-final-01.json"
    completion_name = "app-integration-final-01/completion.json"
    paths = [qualification, evidence(q, directory, manifest_name),
             evidence(q, directory, completion_name), evidence(q, directory, "source-snapshots.tar.gz")]
    m, c = read_json(paths[1]), read_json(paths[2])
    require(m.get("kind") == "cmdy-active-terminal-source-manifest" and m.get("reviewState") == "unreviewed",
            "Expected explicit unreviewed source inventory, not an inferred approval")
    for field, count in (("sources", "sourceCount"), ("trustFiles", "trustFileCount")):
        require(isinstance(m.get(field), list) and len(m[field]) == m.get(count), "Invalid source inventory count")
    rows = m["sources"] + m["trustFiles"]
    require(len({row["path"] for row in rows}) == len(rows), "Duplicate source inventory paths")
    for row in rows:
        relative(row["path"])
        require(row.get("mode") in ("100644", "100755") and isinstance(row.get("size"), int)
                and row["size"] >= 0 and re.fullmatch(r"[0-9a-f]{64}", row.get("sha256", "")),
                "Invalid source inventory entry")
    require(c.get("status") == "pass" and c.get("suites") == len(SUITES)
            and c.get("failures") == 0 and c.get("skips") == 0, "Headless app qualification is incomplete")
    require(c.get("foreground_activated") is False and c.get("os_clipboard_accessed") is False,
            "Headless evidence must explicitly exclude foreground and clipboard access")
    for field in ("native_source_key", "native_archive_sha256"):
        require(c.get(field) == q.get(field), f"Headless evidence has another {field}")
    require(c.get("binary_sha256") == q.get("app_binary_sha256"), "Headless evidence has another app")
    require(set(c.get("required_native_symbols", [])) == set(SYMBOLS), "Missing linked native implementation evidence")
    processes = c.get("processes", [])
    require(len(processes) == len(SUITES), "Missing headless processes")
    seen = set()
    for process in processes:
        argv = process.get("argv", [])
        require(len(argv) == 2 and argv[0] == c.get("binary") and argv[1].startswith("--")
                and argv[1].endswith("-test"), "Invalid headless command record")
        suite = argv[1][2:-5]
        require(suite in SUITES and suite not in seen, "Duplicate or unexpected headless suite")
        require(process.get("exit_code") == 0 and process.get("reaped") is True
                and process.get("skipped") is False, "Headless process did not pass and reap")
        log = evidence(q, directory, f"app-integration-final-01/{suite}.log")
        require(sha(log) == process.get("log_sha256"), "Headless log checksum differs")
        paths.append(log)
        seen.add(suite)
    symbols = evidence(q, directory, "app-integration-final-01/native-symbols-corrected.txt")
    require(sha(symbols) == c.get("native_symbol_inventory_sha256"), "Native symbol evidence differs")
    paths.append(symbols)
    return q, m, c, paths


def freeze_source(archive: Path, manifest: dict, output: Path) -> None:
    rows = {row["path"]: row for row in manifest["sources"] + manifest["trustFiles"]}
    expected = {"final/" + name for name in rows}
    with tarfile.open(archive, "r:gz") as stream:
        members = stream.getmembers()
        require(len({m.name for m in members}) == len(members), "Duplicate source archive members")
        for member in members:
            relative(member.name)
            require(member.isfile() and 0 <= member.size <= 32 * 1024 * 1024,
                    "Source archive contains an unsupported member")
        require(sum(m.size for m in members) <= 512 * 1024 * 1024, "Source archive is too large")
        require({m.name for m in members if m.name.startswith("final/")} == expected,
                "Qualified archive and final source inventory differ")
        for name, row in rows.items():
            member = stream.getmember("final/" + name)
            data = stream.extractfile(member).read()
            require(len(data) == row["size"] and digest(data) == row["sha256"], f"Archived source differs: {name}")
            target = output / relative(name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o755 if row["mode"] == "100755" else 0o644)


def native_receipt(artifact: Path, q: dict, source: Path) -> dict:
    receipt = read_json(artifact / "receipt.json")
    identity = {key: receipt[key] for key in NATIVE_IDENTITY}
    key = digest(json.dumps(identity, sort_keys=True).encode())
    require(receipt.get("status") == "pass" and receipt.get("source_key") == key == q.get("native_source_key"),
            "Native archive source identity differs")
    require(receipt.get("optimize") == "ReleaseFast" and receipt.get("zig_version") == "0.15.2"
            and receipt.get("minimum_macos") == "26.0" and receipt.get("architectures") == ["arm64"],
            "This runner requires the qualified arm64 ReleaseFast normal native build")
    require(sha(artifact / "libcmdy_engine.a") == receipt.get("archive_sha256") == q.get("native_archive_sha256"),
            "Native archive bytes differ")
    for name, checksum in receipt["sources"].items():
        require(sha(source / "Core" / relative(name)) == checksum, f"Native receipt/source mismatch: {name}")
    prefix = "Sources/CmdyNative/include/"
    expected = {name[len(prefix):]: value for name, value in receipt["sources"].items() if name.startswith(prefix)}
    actual = {name: row["sha256"] for name, row in inventory(artifact / "include").items()}
    stamp = actual.pop("cmdy_engine_build.h", None)
    if stamp is not None:
        text = f'#define CMDY_ZIG_SOURCE_KEY "{key}"\n#define CMDY_ZIG_BUILD_MODE "ReleaseFast"\n'
        require(stamp == digest(text.encode()), "Derived native header differs")
    require(actual == expected and bool(expected), "Native header inventory differs")
    return receipt


def native_verification_source(key: str) -> bytes:
    # This preparer accepts only the arm64 ReleaseFast receipt checked above.
    # Match the complete deterministic output of the qualified native plugin;
    # generated paths are never a blanket exception to source qualification.
    return (f'// Verified native archive: {key}\n'
            f'#if !CMDY_ZIG_SELECTED_{key}\n'
            '#error("CMDY native archive selection changed. Use ./build.sh or add --manifest-cache none --disable-build-manifest-caching to SwiftPM.")\n'
            '#endif\n'
            '#if !(arch(arm64))\n'
            '#error("CMDY native archive does not contain this architecture. Run ./build.sh with matching --arch or --triple flags.")\n'
            '#endif\n').encode()


def build_inputs(products: Path, source: Path, key: str) -> tuple[Path, list[Path], dict[str, Path]]:
    description = read_json(products / "description.json")
    commands = description["swiftCommands"].values()
    modules = {}
    for name in ("CmdyApp", "CmdyCore", "CmdyC", "CmdyGPU"):
        found = [c for c in commands if c.get("moduleName") == name]
        require(len(found) == 1, f"Build must have one {name} module")
        modules[name] = found[0]
    original = Path(modules["CmdyApp"]["moduleOutputPath"]).parent.parent
    require(original.is_absolute(), "Original build path must be absolute")
    app_sources = modules["CmdyApp"]["sources"]
    main = [Path(p) for p in app_sources if p.endswith("/App/main.swift")]
    require(len(main) == 1, "Normal app main.swift is missing from build description")
    original_repo = main[0].parent.parent
    module_map = products / "CmdyNative.build/module.modulemap"
    found = re.fullmatch(r'\s*module\s+CmdyNative\s*\{\s*umbrella\s+("(?:\\.|[^"\\])*")\s*export\s+\*\s*\}\s*',
                         module_map.read_text())
    require(found is not None and Path(json.loads(found[1])) == original_repo / "Core/Sources/CmdyNative/include",
            "Native module map does not identify the qualified Core package")
    generated = {}
    for name, folder in (("CmdyApp", "App"), ("CmdyCore", "Core/Sources/CmdyCoreZig"),
                         ("CmdyC", "Core/Sources/CmdyCZig"), ("CmdyGPU", "Renderer/Sources/CmdyGPUZig")):
        command = modules[name]
        package = "renderer" if name == "CmdyGPU" else "core"
        verifier = (original.parent.parent / "plugins/outputs" / package / name
                    / "destination/VerifyNativeEngine" / f"NativeEngineVerified-{name}.swift")
        authored = set()
        verifier_declared = False
        require(len(command["sources"]) == len(set(command["sources"])), "Duplicate build source")
        for value in command["sources"]:
            path = Path(value)
            require(path.is_absolute() and str(path) == value and ".." not in path.parts,
                    "Noncanonical build source")
            if path.is_relative_to(original_repo / folder):
                authored.add(str(path.relative_to(original_repo)))
            else:
                require(name != "CmdyApp" and path == verifier and not path.is_symlink(),
                        f"Unexpected generated source for {name}")
                verifier_declared = True
                # SwiftPM describes the separate compatibility product even
                # when a normal app build does not execute that compile job.
                if name == "CmdyC" and not path.exists():
                    continue
                require(path.is_file() and path.read_bytes() == native_verification_source(key),
                        f"Unexpected or changed generated source for {name}")
                generated[name] = path
        expected = {str(p.relative_to(source)) for p in (source / folder).rglob("*.swift")}
        require(authored == expected and bool(expected), f"Build source graph differs for {name}")
        if name != "CmdyApp":
            require(verifier_declared, f"Build omits the native verifier for {name}")
            flags = [v for v in command["otherArguments"] if v.startswith("-DCMDY_ZIG_SELECTED_")]
            require(flags == ["-DCMDY_ZIG_SELECTED_" + key], f"{name} selected another native archive")
    link_list = products / "cmdy.product/Objects.LinkFileList"
    objects = [Path(line) for line in link_list.read_text().splitlines()]
    require(objects and len(set(objects)) == len(objects), "Empty or duplicate link object list")
    relative_objects = []
    for path in objects:
        require(path.is_absolute() and path.is_relative_to(original) and path.suffix == ".o",
                "Unexpected object outside original build directory")
        relative_objects.append(path.relative_to(original))
    require(Path("CmdyNative.build/bridge.c.o") in relative_objects, "App does not link its native bridge")
    # CmdyC is a separately built public compatibility product; the normal app
    # consumes CmdyCore/PTY/GPU directly and does not link this unused product.
    for name, module in modules.items():
        if name == "CmdyC":
            require(all(Path(p).relative_to(original) not in relative_objects for p in module["objects"]),
                    "Normal app unexpectedly links the separate compatibility product")
            continue
        require(all(Path(p).relative_to(original) in relative_objects for p in module["objects"]),
                "App link list omits a module object")
    files = [products / "cmdy", products / "description.json", link_list,
             products / "CmdyNative.build/module.modulemap"] + [products / p for p in relative_objects]
    require(all(p.is_file() and not p.is_symlink() for p in files), "Completed build input is missing")
    return original, files, generated


def macho_sections(path: Path) -> dict:
    """Compare all file-backed sections across ad-hoc signing; exclude LINKEDIT signatures."""
    data = path.read_bytes()
    require(len(data) >= 32, "Truncated Mach-O header")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data)
    require(magic == 0xFEEDFACF and cpu == 0x100000C and filetype == 2,
            "Expected an arm64 Mach-O executable")
    require(32 + sizeofcmds <= len(data), "Truncated Mach-O commands")
    offset, sections = 32, []
    for _ in range(ncmds):
        require(offset + 8 <= 32 + sizeofcmds, "Truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= 32 + sizeofcmds, "Invalid Mach-O command length")
        if command == 0x19:
            require(size >= 72, "Truncated Mach-O segment")
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            require(size == 72 + nsects * 80, "Invalid Mach-O section table")
            for i in range(nsects):
                values = struct.unpack_from("<16s16sQQIIIIIIII", data, offset + 72 + i * 80)
                sect, seg, addr, length, start = values[:5]
                kind = values[8] & 0xFF
                zerofill = kind in (1, 12, 18)
                require(zerofill or start + length <= len(data), "Truncated Mach-O section")
                sections.append({"segment": seg.rstrip(b"\0").decode(), "section": sect.rstrip(b"\0").decode(),
                                 "address": addr, "size": length, "flags": values[8],
                                 "sha256": None if zerofill else digest(data[start:start + length])})
        offset += size
    require(offset == 32 + sizeofcmds and any(v["section"] == "__text" for v in sections),
            "Incomplete Mach-O code inventory")
    return {"cpu": cpu, "subtype": subtype, "filetype": filetype, "flags": flags, "sections": sections}


def command(argv: list[str], logs: Path, label: str) -> str:
    logs.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60, check=False)
    (logs / (label + ".log")).write_bytes(result.stdout)
    write_json(logs / (label + ".json"), {"argv": argv, "exit_code": result.returncode,
               "stdout_sha256": digest(result.stdout), "reaped": True})
    require(result.returncode == 0, f"Command failed ({label}); see {logs / (label + '.log')}")
    return result.stdout.decode(errors="replace").strip()


def verify_symbols(binary: Path, logs: Path) -> None:
    output = command(["/usr/bin/nm", "-gU", str(binary)], logs, "native-symbols")
    symbols = {line.split()[-1] for line in output.splitlines() if line.split()}
    require(set(SYMBOLS) <= symbols, "App lacks linked native implementations")


def identity_probe(output: Path, receipt: dict) -> None:
    probe = output / "NativeBuildIdentity.c"
    probe.write_text('#include <stdio.h>\nconst char *cmdy_native_engine_source_key(void);\n'
                     'const char *cmdy_native_engine_build_mode(void);\nint main(void) {\n'
                     'puts(cmdy_native_engine_source_key()); puts(cmdy_native_engine_build_mode()); return 0; }\n')
    argv = ["xcrun", "clang", str(probe), str(output / "build/CmdyNative.build/bridge.c.o"),
            str(output / "native/libcmdy_engine.a"), "-lobjc", "-o", str(output / "native-build-identity")]
    for framework in FRAMEWORKS:
        argv.extend(("-framework", framework))
    command(argv, output / "logs", "identity-link")
    actual = command([str(output / "native-build-identity")], output / "logs", "identity-run")
    require(actual == receipt["source_key"] + "\n" + receipt["optimize"], "Compiled native bridge selected other inputs")


def qualified_scripting(source: Path, plist: dict, resources: Path) -> Path | None:
    # source/ contains only manifest-bound bytes extracted from the qualified
    # archive. Never discover automation from the live checkout or a template.
    required = (source / "App/CmdyPasteAutomation.swift", source / "App/CmdyPasteAutomationBridge.swift",
                source / "App/Resources/Cmdy.sdef")
    present = [path.is_file() for path in required]
    require(not any(present) or all(present), "Incomplete source-qualified paste automation")
    dictionary = resources / "Cmdy.sdef"
    if not all(present):
        require(not plist.get("NSAppleScriptEnabled") and "OSAScriptingDefinition" not in plist
                and not dictionary.exists(), "Scripting template has no source-qualified implementation")
        return None
    require("OSAScriptingDefinition" not in plist or plist["OSAScriptingDefinition"] == "Cmdy.sdef",
            "Template selects another scripting dictionary")
    if dictionary.exists():
        require(sha(dictionary) == sha(required[-1]), "Template dictionary differs from qualified source")
    return required[-1]


def assemble_bundle(output: Path, template: Path, packaging: Path, source: Path) -> tuple[Path, Path]:
    identity = read_json(source / "Identity/Sources/ProductIdentity/Resources/product-identity.json")
    name = identity["name"]
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    require(slug == "cmdy", "This benchmark package expects the CMDY product identity")
    resources = template / "Contents/Resources"
    plist = plistlib.loads((template / "Contents/Info.plist").read_bytes())
    require(plist.get("CFBundleIdentifier") == identity["bundleIdentifier"]
            and plist.get("CFBundleExecutable") == slug and plist.get("LSMinimumSystemVersion") == "26.0",
            "Resource template has another application identity")
    require(not any(k.startswith("CMDYBrowser") for k in plist) and not (template / "Contents/Frameworks").exists(),
            "Only the lean resource template is supported")
    scripting = qualified_scripting(source, plist, resources)
    allowed = set(REFERENCES) | {slug + ".icns"}
    if scripting is not None and (resources / "Cmdy.sdef").exists():
        allowed.add("Cmdy.sdef")
    for bundle in BUNDLES:
        require(inventory(resources / bundle) == inventory(output / "build" / bundle),
                f"Template and completed build resource bundle differ: {bundle}")
        allowed.update(bundle + "/" + p for p in inventory(resources / bundle))
    require(set(inventory(resources)) == allowed, "Template has missing or unexpected resources")
    require(sha(resources / BUNDLES[1] / "product-identity.json") ==
            sha(source / "Identity/Sources/ProductIdentity/Resources/product-identity.json"),
            "Packaged product identity differs from qualified source")
    app = output / "app" / (slug + ".app")
    target_resources = app / "Contents/Resources"
    target_resources.mkdir(parents=True)
    for path in REFERENCES + (slug + ".icns",):
        copy_file(resources / path, target_resources / path)
    for bundle in BUNDLES:
        copy_tree(output / "build" / bundle, target_resources / bundle)
    if scripting is not None:
        copy_file(scripting, target_resources / "Cmdy.sdef")
        plist["NSAppleScriptEnabled"] = True
        plist["OSAScriptingDefinition"] = "Cmdy.sdef"
    version = (packaging / "VERSION").read_text().strip()
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) is not None, "Invalid package version")
    for key in ("CFBundleName", "CFBundleDisplayName"):
        plist[key] = name
    plist["CFBundleShortVersionString"] = version
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist, sort_keys=False))
    binary = app / "Contents/MacOS" / slug
    copy_file(output / "build/cmdy", binary)
    binary.chmod(0o755)
    helper_name = name + " Component Helper"
    helper = app / "Contents/Helpers" / (helper_name + ".app")
    helper_binary = helper / "Contents/MacOS" / (slug + "-component-helper")
    copy_file(output / "build/cmdy", helper_binary)
    helper_binary.chmod(0o755)
    helper_plist = {"CFBundleName": helper_name, "CFBundleDisplayName": helper_name,
                    "CFBundleIdentifier": identity["codeSigningIdentifierNamespace"] + ".component-switch",
                    "CFBundleExecutable": helper_binary.name, "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": version, "CFBundleVersion": plist["CFBundleVersion"],
                    "LSMinimumSystemVersion": "26.0", "LSUIElement": True}
    (helper / "Contents/Info.plist").write_bytes(plistlib.dumps(helper_plist, sort_keys=False))
    entitlements = output / "packaging/Cmdy.entitlements"
    command(["/usr/bin/codesign", "--force", "--sign", "-", str(helper)], output / "logs", "sign-helper")
    command(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identity["bundleIdentifier"],
             "--entitlements", str(entitlements), str(app)], output / "logs", "sign-app")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], output / "logs", "verify-signature")
    require(macho_sections(binary) == macho_sections(helper_binary) == macho_sections(output / "build/cmdy"),
            "Signing changed executable code/data sections")
    return app, helper_binary


def prepare(args: argparse.Namespace) -> dict:
    qpath = args.qualification.resolve()
    q, manifest, completion, proof_files = qualified_inputs(qpath)
    out = args.output.resolve()
    require(not out.exists() and not out.is_relative_to(args.repository.resolve()),
            "Output must be new and outside the repository")
    out.mkdir(parents=True)
    write_json(out / "state.json", {"status": "preparing", "not_performance_admission": True})
    for proof in proof_files:
        target = Path("qualification.json") if proof == qpath else proof.relative_to(qpath.parent)
        copy_file(proof, out / "qualification" / target)
    freeze_source(out / "qualification/source-snapshots.tar.gz", manifest, out / "source")
    receipt = native_receipt(args.artifact, q, out / "source")
    original, inputs, generated = build_inputs(args.build_products, out / "source", receipt["source_key"])
    require(sha(args.build_products / "cmdy") == q["app_binary_sha256"], "Completed app differs from qualified app")
    for source in inputs:
        copy_file(source, out / "build" / source.relative_to(args.build_products))
    for name, source in generated.items():
        copy_file(source, out / "build/native-verification" / f"{name}.swift",
                  digest(native_verification_source(receipt["source_key"])))
    for bundle in BUNDLES:
        copy_tree(args.build_products / bundle, out / "build" / bundle)
    for name in ("receipt.json", "libcmdy_engine.a"):
        copy_file(args.artifact / name, out / "native" / name)
    copy_tree(args.artifact / "include", out / "native/include")
    for name in ("package.sh", "Cmdy.entitlements", "VERSION", "scripts/product-identity.sh",
                 "scripts/package-resource-policy.sh"):
        copy_file(args.packaging_source / name, out / "packaging" / name)
    verify_symbols(out / "build/cmdy", out / "logs")
    identity_probe(out, receipt)
    app, helper = assemble_bundle(out, args.resource_template, args.packaging_source, out / "source")
    # Freeze the unchanged shared measurement policy and runner dependencies.
    # Test parameters, comparator evidence, timed scheduling and admission remain
    # the responsibility of their existing canonical harnesses.
    policy = args.repository / "Tests/parity-policy.json"
    require(sha(policy) == POLICY_SHA256, "Locked performance policy differs")
    for path in sorted((args.repository / "Tests").iterdir()):
        if path.is_file() and path.suffix in (".py", ".swift", ".c", ".sh", ".json"):
            copy_file(path, out / "tooling/Tests" / path.name)
    for name in ("prepare.py", "test_prepare.py", "README.md"):
        copy_file(Path(__file__).resolve().with_name(name), out / "tooling/Tests/NativePerformance" / name)
    current_differences = [row["path"] for row in manifest["sources"] + manifest["trustFiles"]
                           if not (args.repository / row["path"]).is_file()
                           or sha(args.repository / row["path"]) != row["sha256"]]
    record = {
        "schema_version": 1, "kind": "cmdy-normal-native-performance-candidate",
        "status": "prepared", "native_source_key": receipt["source_key"],
        "native_archive_sha256": receipt["archive_sha256"], "native_mode": receipt["optimize"],
        "raw_binary": "build/cmdy", "raw_binary_sha256": sha(out / "build/cmdy"),
        "app_bundle": app.relative_to(out).as_posix(),
        "binary": (app / "Contents/MacOS/cmdy").relative_to(out).as_posix(),
        "component_helper": helper.relative_to(out).as_posix(),
        "signed_binary_sha256": sha(app / "Contents/MacOS/cmdy"),
        "signed_helper_sha256": sha(helper), "executable_sections": macho_sections(out / "build/cmdy"),
        "qualified_source_files": manifest["sourceCount"], "qualified_build_files": manifest["trustFileCount"],
        "source_review_state": manifest["reviewState"], "qualification_sha256": sha(qpath),
        "source_binding": "exact qualified archive; newer working-tree edits do not replace baseline source",
        "working_tree_differences_from_qualified_source": current_differences,
        "original_build_products": str(original), "completed_build_inputs": str(args.build_products.resolve()),
        "headless_evidence": {"mode": "reused exact qualified raw app, native archive and source bytes",
                              "completion": "qualification/app-integration-final-01/completion.json",
                              "suites": list(SUITES), "new_app_processes": 0},
        "packaging": {"signing": "ad-hoc", "code_and_data_sections_equal_qualified_raw_app": True,
                      "runtime_bundle_launch_tested": False,
                      "resources": "exact completed-build bundles; explicit lean template docs and icon"},
        "policy": {"path": "tooling/Tests/parity-policy.json", "sha256": POLICY_SHA256},
        "comparison_inputs": {"cmdy_binary": str(app / "Contents/MacOS/cmdy"),
                              "cmdy_app": str(app), "tooling_dir": str(out / "tooling/Tests"),
                              "native_artifact": str(out / "native")},
        "timed_benchmarks_run": False, "performance_samples_inherited": False,
        "foreground_activated": False, "os_clipboard_accessed": False,
        "not_performance_admission": True, "not_release_approval": True,
    }
    (out / "state.json").unlink()
    record["files"] = inventory(out)
    write_json(out / "candidate.json", record)
    verify(out, verify_signature=True)
    return record


def verify(output: Path, verify_signature: bool = True) -> dict:
    record = read_json(output / "candidate.json")
    require(record.get("schema_version") == 1 and record.get("kind") == "cmdy-normal-native-performance-candidate"
            and record.get("status") == "prepared", "Not a prepared native candidate")
    actual = inventory(output)
    actual.pop("candidate.json", None)
    require(actual == record.get("files"), "Frozen candidate inventory changed")
    qpath = output / "qualification/qualification.json"
    require(sha(qpath) == record.get("qualification_sha256"), "Qualification identity changed")
    q, manifest, completion, _ = qualified_inputs(qpath)
    for row in manifest["sources"] + manifest["trustFiles"]:
        require(sha(output / "source" / relative(row["path"])) == row["sha256"], "Frozen source differs")
    receipt = native_receipt(output / "native", q, output / "source")
    require(record.get("native_source_key") == receipt["source_key"]
            and record.get("native_archive_sha256") == receipt["archive_sha256"], "Candidate native binding differs")
    raw = output / relative(record["raw_binary"])
    require(sha(raw) == record["raw_binary_sha256"] == q["app_binary_sha256"], "Qualified raw app changed")
    for field in ("binary", "component_helper"):
        require(macho_sections(output / relative(record[field])) == record["executable_sections"] == macho_sections(raw),
                "Signed candidate no longer has qualified executable sections")
    require(sha(output / relative(record["policy"]["path"])) == record["policy"]["sha256"] == POLICY_SHA256,
            "Frozen performance policy changed")
    if verify_signature:
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                                 str(output / relative(record["app_bundle"]))],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        require(result.returncode == 0, "Frozen app signature is invalid")
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("prepare", help="freeze and package a completed, qualified normal app")
    p.add_argument("--repository", type=Path, default=ROOT)
    p.add_argument("--build-products", type=Path, required=True)
    p.add_argument("--artifact", type=Path, required=True)
    p.add_argument("--qualification", type=Path, required=True)
    p.add_argument("--resource-template", type=Path, required=True)
    p.add_argument("--packaging-source", type=Path, default=ROOT)
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("verify", help="reject a changed frozen candidate before measurement")
    p.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        record = prepare(args) if args.action == "prepare" else verify(args.output.resolve())
        print(json.dumps({"status": record["status"], "native_source_key": record["native_source_key"],
                          "raw_binary_sha256": record["raw_binary_sha256"],
                          "binary": str(args.output.resolve() / record["binary"]),
                          "timed_benchmarks_run": False}))
    except (PreparationError, OSError, KeyError, TypeError, ValueError, struct.error,
            subprocess.TimeoutExpired, tarfile.TarError) as error:
        print(f"native candidate preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
