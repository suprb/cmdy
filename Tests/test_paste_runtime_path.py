"""Canonical worker runtime regression. No app, PTY, permission, or native event."""
import hashlib
import json
from pathlib import Path
import shlex
import tempfile
import unittest
from unittest.mock import patch

from competitive_bench import BenchOptions, binary_metadata
from paste_bench import run_owned
from paste_contract import expected_environment, validate_launch


class CommandCaptured(Exception):
    pass


class PasteRuntimePathTests(unittest.TestCase):
    def test_alias_controller_uses_canonical_pinned_worker_runtime(self):
        with tempfile.TemporaryDirectory(prefix="paste-runtime-alias-") as temporary:
            root = Path(temporary)
            canonical = root / "python3.13"; canonical.write_text("synthetic runtime bytes; never executed\n")
            alias = root / "python3"; alias.symlink_to(canonical)
            tooling = root / "tooling"; tooling.mkdir()
            options = BenchOptions(Path("/synthetic/cmdy"), Path("/synthetic/ghostty"), tooling_dir=tooling)
            metadata = {"runtime": {"python": binary_metadata(alias)}, "toolingDirectory": str(tooling),
                        "binaries": {name: {"path": "/synthetic/" + name} for name in ("cmdy", "ghostty")}}
            self.assertNotEqual(str(alias), metadata["runtime"]["python"]["path"])
            self.assertEqual(metadata["runtime"]["python"]["path"], str(canonical.resolve()))
            token = "0123456789abcdef0123456789abcdef"
            for terminal in ("cmdy", "ghostty"):
                with self.subTest(terminal=terminal):
                    directory = root / "pilot" / terminal
                    captured = {}

                    def intercept(*args, **kwargs):
                        captured.update(kwargs)
                        raise CommandCaptured("stop before any native session setup")

                    with patch("paste_bench.sys.executable", str(alias)), \
                         patch("paste_bench.TerminalSession", side_effect=intercept), \
                         patch("paste_bench.subprocess.run") as native, \
                         patch("paste_bench.window_command") as window, \
                         patch("paste_bench.power_snapshot") as power, \
                         self.assertRaises(CommandCaptured):
                        run_owned(options, None, None, terminal, directory, token, metadata)
                    native.assert_not_called(); window.assert_not_called(); power.assert_not_called()
                    command = captured["fixture_command"]
                    self.assertEqual(command[0], metadata["runtime"]["python"]["path"])
                    self.assertEqual(command[1:5], ["-S", str(tooling / "paste_worker.py"), "--output", str(directory / "fixture")])
                    self.assertEqual(command[7:], ["--token", token, "--timeout", "600"])

                    # The command captured from the real generator must pass the
                    # same strict retained launch contract used by the recorder.
                    config = directory / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
                    config.parent.mkdir(parents=True, exist_ok=True); config.write_text("synthetic controlled config\n")
                    shell = directory / "zsh/.zshenv"; shell.parent.mkdir(); shell.write_text("unsetopt RCS\nexec " + shlex.join(command) + "\n")
                    hashes = {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest() for path in (config, shell)}
                    (directory / "config-before-launch.json").write_text(json.dumps(hashes))
                    cwd = Path("/private/tmp/cmdy-drain-alias-test/work"); domain = "com.cmdy.bench." + token
                    launch = {"terminal": terminal, "config": str(config), "readyPath": str(directory / "fixture/ready.json"),
                              "arguments": [metadata["binaries"][terminal]["path"]]
                                  + (["--config-default-files=false", f"--config-file={config}"] if terminal == "ghostty" else []),
                              "defaultsDomain": domain, "cwd": str(cwd), "environment": expected_environment(directory, cwd, domain),
                              "fixtureCommand": command}
                    spec = {"socketPath": command[6], "token": token}
                    self.assertEqual(validate_launch(directory, metadata, launch, spec), domain)
                    alias_launch = dict(launch, fixtureCommand=[str(alias), *command[1:]])
                    with self.assertRaisesRegex(ValueError, "command binding differs"):
                        validate_launch(directory, metadata, alias_launch, spec)


if __name__ == "__main__":
    unittest.main()
