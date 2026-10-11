#!/usr/bin/env python3
"""Qualify the exact public store objects and production event-resolution bodies.

The selected candidate supplies immutable CmdyKit/ProductIdentity link objects.
Only synthetic NSEvents are constructed; no application or monitor is started.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from history_export_binding import install_binding
from history_export_phase import POLICY, CASES

HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extracted_dispatch(source):
    def section(start, end):
        assert source.count(start) == source.count(end) == 1
        return source[source.index(start):source.index(end)]
    parts = [section("    enum Action {", "    private weak var delegate:"),
             section("    func reloadImportedMappings() {", "    func invalidate() {"),
             section("    private static func importShortcut(", "    static func resolve(keyCode:")]
    generated = "final class StandardKeybindings {\n" + parts[0] + """
    private var importedMappings: [CMDYKeybindingShortcut: CMDYKeybindingCommand] = [:]
""" + "\n".join(parts[1:]) + """
    func fixtureAction(_ event: NSEvent) -> Action? {
        Self.importedCommand(for: event, mappings: importedMappings).flatMap(Self.action(for:))
    }
}
"""
    return generated, [hashlib.sha256(part.encode()).hexdigest() for part in parts]


def qualify(candidate, output):
    candidate = candidate.resolve(); output = output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads((candidate / "candidate.json").read_text())
    record = dict(status="running", candidate=str(candidate), candidateSHA256=sha(candidate / "candidate.json"),
                  signedAppSHA256=manifest["signed_binary_sha256"], processes=[], nativeAppRun=False,
                  eventsPosted=False, windowCreated=False, clipboardAccessed=False, performanceAdmission=False)
    def save():
        (output / "receipt.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    def run(name, command, env=None):
        log = output / (name + ".log")
        with log.open("xb") as stream:
            process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
            row = dict(command=command, pid=process.pid); record["processes"].append(row); save()
            try: row["returncode"] = process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                process.kill(); row["returncode"] = process.wait(); raise
            finally:
                row.update(reaped=process.returncode is not None, logSHA256=sha(log)); save()
        if row["returncode"]: raise RuntimeError("Headless binding check failed: " + str(log))
    try:
        names = ["App/StandardKeybindings.swift", "Kit/Sources/CmdyKit/KeybindingImport.swift", "Kit/Sources/CmdyKit/ConfigFile.swift"]
        record["bindingApplicationSources"] = {name: sha(candidate / "source" / name) for name in names}
        for name in names:
            assert sha(candidate / "source" / name) == manifest["files"]["source/" + name]["sha256"]
        dispatch, hashes = extracted_dispatch((candidate / "source" / names[0]).read_text())
        template = (HERE / "HistoryExportBindingTests.swift").read_text()
        assert template.count("// PRODUCTION_IMPORTED_DISPATCH") == 1
        source = output / "BindingTests.swift"
        source.write_text(template.replace("// PRODUCTION_IMPORTED_DISPATCH", dispatch))
        record["extractedProductionSectionsSHA256"] = hashes
        record["fixtureSHA256"] = {str(p): sha(p) for p in [source, HERE / "HistoryExportBindingTests.swift",
                                                           HERE / "history_export_key.swift", Path(__file__)]}
        objects = sorted((candidate / "build/CmdyKit.build").glob("*.o")) + sorted((candidate / "build/ProductIdentity.build").glob("*.o"))
        assert objects
        for path in objects: assert sha(path) == manifest["files"][str(path.relative_to(candidate))]["sha256"]
        record["candidateLinkObjectsSHA256"] = {str(p.relative_to(candidate)): sha(p) for p in objects}
        modules = output / "Modules"; modules.mkdir()
        products = Path(manifest["original_build_products"])
        for name in ("CmdyKit", "ProductIdentity"):
            shutil.copy2(products / "Modules" / (name + ".swiftmodule"), modules)
        record["moduleInterfacesSHA256"] = {p.name: sha(p) for p in sorted(modules.iterdir())}
        shutil.copytree(candidate / "build/ProductIdentity_ProductIdentity.bundle", output / "ProductIdentity_ProductIdentity.bundle")
        binary = output / "binding-tests"
        run("compile", ["/usr/bin/xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
            "-I", str(modules), "-module-cache-path", str(output / "swift-module-cache"),
            str(HERE / "history_export_key.swift"), str(source), *map(str, objects), "-o", str(binary)])
        record['publicCases'] = []
        for case in (None, *CASES):
            group = output / (case or 'legacy'); group.mkdir(mode=0o700)
            for terminal in ("cmdy", "ghostty"):
                directory = group / (terminal + "-config"); directory.mkdir(mode=0o700)
                config = directory / "config"; config.write_text("font-family = Menlo\nfont-size = 14\n")
                receipt = install_binding(terminal, config, case=case, policy=POLICY if case else None)
                (group / (terminal + "-binding.json")).write_text(json.dumps(receipt, indent=2) + "\n")
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMDY_CONFIG_DIR": str(group / "cmdy-config")}
            run("check-" + (case or 'legacy'), [str(binary), str(group / "cmdy-config"), *([case] if case else [])], environment)
            record['publicCases'].append(case or 'legacy')
        record.update(status="pass", binarySHA256=sha(binary), applicationSourcesUnchanged=all(
            sha(candidate / "source" / name) == digest for name, digest in record["bindingApplicationSources"].items()))
        assert record["applicationSourcesUnchanged"]
    except BaseException as error:
        record.update(status="failed", error=repr(error)); raise
    finally: save()
    return record


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(qualify(args.candidate, args.output), indent=2, sort_keys=True))
