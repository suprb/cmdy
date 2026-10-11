"""Execute both real main audit call expressions without running native setup."""
import ast
from contextlib import ExitStack
from copy import deepcopy
import hashlib
import inspect
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import paste_bench
from competitive_bench import BenchOptions, binary_metadata
from paste_dictionary import validate_sdef
from scroll_bench import check_source_manifest

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class AuditFixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="paste-finish-audit-")
        self.root = Path(self.temporary.name).resolve()
        self.output = self.root / "explicit-evidence"; self.output.mkdir()
        self.source = self.root / "source"; self.source.mkdir()
        self.tooling = self.root / "tooling"; self.tooling.mkdir()
        self.source_file = self.source / "Main.swift"; self.source_file.write_text("synthetic source\n")
        self.manifest = self.output / "app-source-manifest.json"
        self.manifest.write_text(json.dumps({"sourceRoot": str(self.source), "sources": {"Main.swift": sha(self.source_file)}}))
        self.font = self.root / "synthetic-font"; self.font.write_text("synthetic font bytes; not loaded\n")
        self.binaries = {}
        for name in ("cmdy", "ghostty"):
            binary = self.root / name; binary.write_text("synthetic binary bytes; not executable\n")
            self.binaries[name] = binary_metadata(binary)
        dictionary = (ROOT / "App/Resources/Cmdy.sdef").read_bytes()
        self.definition = validate_sdef(dictionary)
        for name in ("cmdy.sdef", "ghostty.sdef"):
            (self.tooling / name).write_bytes(dictionary)
        self.frozen = {name: sha(self.tooling / name) for name in ("cmdy.sdef", "ghostty.sdef")}
        self.power = {"signature": {"source": "AC Power", "settings": "synthetic fixed power policy"}}
        self.native = {"ok": True, "lowPowerMode": False, "thermalState": 0, "os": "synthetic OS"}
        self.probe = {"font": {"file": str(self.font)}, "displays": [{"displayID": 1}]}
        self.metadata = {"powerBefore": deepcopy(self.power), "nativeBefore": deepcopy(self.native),
                         "fontSHA256": sha(self.font), "binaries": deepcopy(self.binaries),
                         "sourceBefore": check_source_manifest(self.manifest, self.source)}
        self.args = SimpleNamespace(power_source="AC Power", cmdy_source_root=self.source)
        self.options = BenchOptions(Path(self.binaries["cmdy"]["path"]), Path(self.binaries["ghostty"]["path"]))

    def close(self):
        self.temporary.cleanup()


class PasteFinishAuditTests(unittest.TestCase):
    def fixture(self):
        value = AuditFixture(); self.addCleanup(value.close); return value

    def invoke_main_call(self, fixture, name):
        # Compile only main's actual call expression, not a copied invocation.
        # This catches a missing argument at either the pilot or final call site
        # while all native/session/permission setup remains unexecuted.
        tree = ast.parse(inspect.getsource(paste_bench.main))
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == "finish_audit"]
        self.assertEqual(len(calls), 2)
        by_target = {node.args[0].id: node for node in calls}
        self.assertEqual(set(by_target), {"checkpoint", "metadata"})
        call = compile(ast.Expression(body=by_target[name]), "actual-paste-main-audit-call", "eval")
        values = {"checkpoint": fixture.metadata, "metadata": fixture.metadata, "args": fixture.args,
                  "options": fixture.options, "helper": None, "probe": fixture.probe,
                  "frozen": fixture.frozen, "output": fixture.output}

        def window(_helper, command, *_args):
            return fixture.native if command == "conditions" else fixture.probe

        with ExitStack() as stack:
            stack.enter_context(patch.object(paste_bench, "HERE", fixture.tooling))
            stack.enter_context(patch.object(paste_bench, "power_snapshot", return_value=fixture.power))
            stack.enter_context(patch.object(paste_bench, "window_command", side_effect=window))
            stack.enter_context(patch.object(paste_bench, "installed_definition", return_value=(fixture.tooling / "cmdy.sdef", fixture.definition)))
            check = stack.enter_context(patch.object(paste_bench, "check_source_manifest", wraps=check_source_manifest))
            subprocess = stack.enter_context(patch.object(paste_bench.subprocess, "run"))
            session = stack.enter_context(patch.object(paste_bench, "TerminalSession"))
            eval(call, {"finish_audit": paste_bench.finish_audit}, values)
            check.assert_called_once_with(fixture.output / "app-source-manifest.json", fixture.source)
            subprocess.assert_not_called(); session.assert_not_called()

    def test_pilot_checkpoint_call_uses_explicit_output(self):
        fixture = self.fixture()
        self.invoke_main_call(fixture, "checkpoint")
        self.assertEqual(fixture.metadata["sourceAfter"], fixture.metadata["sourceBefore"])
        self.assertIn("finishedUTC", fixture.metadata)

    def test_final_audit_call_uses_explicit_output(self):
        fixture = self.fixture()
        self.invoke_main_call(fixture, "metadata")
        self.assertEqual(fixture.metadata["sourceAfter"], fixture.metadata["sourceBefore"])
        self.assertIn("finishedUTC", fixture.metadata)

    def test_all_existing_drift_guards_remain_active(self):
        for kind in ("power", "native", "font", "source", "binary", "dictionary", "tooling"):
            with self.subTest(kind=kind):
                fixture = self.fixture()
                if kind == "power": fixture.power["signature"]["source"] = "Battery Power"
                elif kind == "native": fixture.native["thermalState"] = 1
                elif kind == "font": fixture.font.write_text("changed font\n")
                elif kind == "source": fixture.source_file.write_text("changed source\n")
                elif kind == "binary": Path(fixture.binaries["cmdy"]["path"]).write_text("changed binary\n")
                elif kind == "dictionary": fixture.definition = dict(fixture.definition, sha256="f" * 64)
                else:
                    (fixture.tooling / "extra-owned-input").write_text("changed owned input\n")
                    fixture.frozen["extra-owned-input"] = "0" * 64
                expected_error = {"power": "power source", "native": "nominal native thermal",
                                  "font": "font/display changed", "source": "app build input drift",
                                  "binary": "binary/plist changed", "dictionary": "dictionary changed",
                                  "tooling": "frozen tooling changed"}[kind]
                with self.assertRaisesRegex((ValueError, RuntimeError), expected_error):
                    self.invoke_main_call(fixture, "metadata")
                self.assertNotIn("finishedUTC", fixture.metadata)


if __name__ == "__main__":
    unittest.main()
