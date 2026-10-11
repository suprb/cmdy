"""Synthetic supported-public-CLI contracts; no process or native APIs."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scroll_public_config import SCOPE, discrete_multiplier, selected_values, validate_public_policy
from scroll_parity_evidence import load_scroll_evidence
from test_scroll_complete_evidence import build_records, digest, write

BINARY = "/synthetic/Ghostty.app/Contents/MacOS/ghostty"
CONFIG = "/synthetic/owned/ghostty.config"
SHA = "e" * 64


def fixture(profile="matched"):
    config = "font-family = Menlo\nfont-size = 14\n"
    if profile == "matched":
        config += "mouse-scroll-multiplier = discrete:1\n"
    record = {"schemaVersion": 2, "scope": SCOPE,
        "binarySHA256Before": SHA, "binarySHA256After": SHA,
        "configSHA256Before": hashlib.sha256(config.encode()).hexdigest(),
        "configSHA256After": hashlib.sha256(config.encode()).hexdigest(),
        "defaultQuery": {"arguments": [BINARY, "+show-config", "--default"],
            "returncode": 0, "stderr": "",
            "selectedValues": {"mouse-scroll-multiplier": ["precision:1,discrete:3"]}},
        "configurationValidation": {"arguments": [BINARY, "+validate-config", f"--config-file={CONFIG}"],
            "returncode": 0, "stdout": "", "stderr": ""},
        "policy": {"installedDefaultDiscreteMultiplier": 3,
            "validatedDiscreteMultiplier": 1 if profile == "matched" else 3,
            "policyOrigin": "validated-explicit-override" if profile == "matched" else "installed-default"}}
    return record, config


def validate(record, config, profile="matched"):
    return validate_public_policy(record, BINARY, SHA, CONFIG, config, profile)


class PublicConfigurationTests(unittest.TestCase):
    def test_supported_matched_and_default_origins_remain_distinct(self):
        for profile in ("matched", "cmdy-defaults"):
            record, config = fixture(profile)
            self.assertEqual(validate(record, config, profile), record["policy"])

    def test_default_command_cannot_load_user_config_or_use_gui_flags(self):
        for args in ([BINARY, "+show-config"], [BINARY, "+show-config", "--changes-only"],
                     [BINARY, "+show-config", "--config-default-files=false", f"--config-file={CONFIG}"]):
            record, config = fixture(); record["defaultQuery"]["arguments"] = args
            with self.assertRaises(ValueError): validate(record, config)

    def test_validation_is_required_for_the_exact_owned_path(self):
        for args in ([BINARY, "+validate-config"], [BINARY, "+validate-config", "--config-file=/another/config"],
                     [BINARY, "+show-config", f"--config-file={CONFIG}"]):
            record, config = fixture(); record["configurationValidation"]["arguments"] = args
            with self.assertRaises(ValueError): validate(record, config)

    def test_failed_query_or_any_validation_diagnostic_rejects(self):
        for section, key, value in (("defaultQuery", "returncode", 1), ("defaultQuery", "returncode", False),
            ("defaultQuery", "stderr", "error"), ("configurationValidation", "returncode", 1),
            ("configurationValidation", "stdout", "unknown option"), ("configurationValidation", "stderr", "error")):
            record, config = fixture(); record[section][key] = value
            with self.assertRaises(ValueError): validate(record, config)

    def test_schema_identity_and_byte_drift_reject(self):
        for key, value in (("schemaVersion", 1), ("schemaVersion", True), ("scope", "effective GUI config"),
            ("binarySHA256Before", "f" * 64), ("binarySHA256After", "f" * 64),
            ("configSHA256Before", "f" * 64), ("configSHA256After", "f" * 64)):
            record, config = fixture(); record[key] = value
            with self.assertRaises(ValueError): validate(record, config)

    def test_missing_or_ambiguous_default_and_bad_multiplier_reject(self):
        for values in (None, [], ["discrete:1", "discrete:3"], ["discrete:nan"], ["discrete:inf"],
                       ["discrete:0"], ["discrete:10001"], ["discrete:3,precision:1,precision:2"],
                       ["discrete:3,unknown:2"], [True]):
            with self.assertRaises(ValueError): discrete_multiplier(values)
        self.assertEqual(discrete_multiplier(["3"]), 3)
        self.assertEqual(discrete_multiplier(["precision:1,discrete:3"]), 3)
        record, config = fixture(); record["defaultQuery"]["selectedValues"] = {}
        with self.assertRaises(ValueError): validate(record, config)

    def test_policy_cannot_be_relabelled_or_contradict_default(self):
        for key, value in (("policyOrigin", "installed-default"), ("installedDefaultDiscreteMultiplier", 1),
                           ("validatedDiscreteMultiplier", 3), ("validatedDiscreteMultiplier", True)):
            record, config = fixture(); record["policy"][key] = value
            with self.assertRaises(ValueError): validate(record, config)
        record, config = fixture("cmdy-defaults")
        with self.assertRaises(ValueError): validate(record, config, "matched")
        record, config = fixture()
        with self.assertRaises(ValueError): validate(record, config, "cmdy-defaults")

    def test_nested_configuration_is_not_an_exact_input_proof(self):
        for line in ("config-file = /another/config\n", "config-default-files = false\n"):
            record, config = fixture(); config += line
            record["configSHA256Before"] = record["configSHA256After"] = hashlib.sha256(config.encode()).hexdigest()
            with self.assertRaises(ValueError): validate(record, config)

    def test_selected_output_retains_only_allowlisted_config_values(self):
        self.assertEqual(selected_values("# mouse-scroll-multiplier = 8\nmouse-scroll-multiplier = precision:1,discrete:3\nworking-directory = /unrelated\nfont-size = 13\n"),
            {"mouse-scroll-multiplier": ["precision:1,discrete:3"], "font-size": ["13"]})

    def test_resealed_raw_pair_cannot_omit_or_weaken_validation(self):
        with tempfile.TemporaryDirectory(prefix="scroll-public-synthetic-") as name:
            root = Path(name); metadata = build_records(root)
            self.assertEqual(load_scroll_evidence(root)["case"], "scroll")
            folder = root / "runs/00-ghostty"
            original = json.loads((folder / "public-config-query.json").read_text())
            original_run = json.loads((folder / "run.json").read_text())
            for mutation in ("legacy", "default-command", "missing-validation", "wrong-file", "failed", "policy"):
                query = deepcopy(original)
                if mutation == "legacy": query["schemaVersion"] = 1
                elif mutation == "default-command": query["defaultQuery"]["arguments"].pop()
                elif mutation == "missing-validation": del query["configurationValidation"]
                elif mutation == "wrong-file": query["configurationValidation"]["arguments"][-1] = "--config-file=/another"
                elif mutation == "failed": query["configurationValidation"]["returncode"] = 1
                else: query["policy"]["validatedDiscreteMultiplier"] = 3
                write(folder / "public-config-query.json", query)
                raw = deepcopy(original_run); raw["publicConfigQuerySHA256"] = digest(folder / "public-config-query.json")
                write(folder / "run.json", raw)
                changed = deepcopy(metadata)
                next(item for item in changed["runs"] if item["path"] == "runs/00-ghostty")["runSHA256"] = digest(folder / "run.json")
                write(root / "manifest.json", changed)
                with self.assertRaises((ValueError, KeyError)):
                    load_scroll_evidence(root)


if __name__ == "__main__":
    unittest.main()
