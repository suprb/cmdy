"""Historical v4 compatibility cannot waive the prospective v5 contract."""
from pathlib import Path
import unittest

import startup_source_compatibility as compatibility


class SourceCompatibilityTests(unittest.TestCase):
    def test_completed_stop_accepts_only_reviewed_source_pairs(self):
        from startup_campaign_contract import source_version_matches
        for name, (frozen, current) in compatibility.COMPLETED_STOP_SOURCES.items():
            data = Path(compatibility.__file__).with_name(name).read_bytes()
            self.assertEqual(compatibility.digest(data), current)
            for inventory in (compatibility.COMPLETED_STOP_INVENTORY, compatibility.V5_INVENTORY):
                with self.subTest(name=name, inventory=inventory):
                    self.assertTrue(source_version_matches(name, frozen, current, inventory))
                    self.assertFalse(compatibility.completed_stop_extension_matches(
                        name, frozen, compatibility.digest(data + b"\n"), inventory, source=data + b"\n"))
                    self.assertFalse(compatibility.completed_stop_extension_matches(
                        name, "0" * 64, current, inventory, source=data))
                    self.assertFalse(compatibility.completed_stop_extension_matches(
                        name, frozen, "0" * 64, inventory, source=data))
                    self.assertFalse(compatibility.completed_stop_extension_matches(
                        name, frozen, current, "unknown", source=data))

    def test_completed_stop_contract_does_not_accept_sampling_or_hook_changes(self):
        name = "startup_campaign_contract.py"
        data = Path(compatibility.__file__).with_name(name).read_bytes()
        original = data.replace(compatibility.COMPLETED_STOP_HOOK, b"", 1)
        frozen = compatibility.digest(original)
        inventory = compatibility.COMPLETED_STOP_INVENTORY
        self.assertTrue(compatibility.completed_stop_extension_matches(
            name, frozen, compatibility.digest(data), inventory, source=data))
        for changed in (data + b"\n", data + compatibility.COMPLETED_STOP_HOOK,
                        data.replace(b"6, 40, 2", b"6, 39, 2"), original):
            self.assertNotEqual(changed, data)
            self.assertFalse(compatibility.completed_stop_extension_matches(
                name, frozen, compatibility.digest(changed), inventory, source=changed))

    def test_completed_stop_cannot_authorize_unrelated_files_or_v4(self):
        name = "startup_fixture.py"
        frozen, current = compatibility.COMPLETED_STOP_SOURCES[name]
        data = Path(compatibility.__file__).with_name(name).read_bytes()
        for other in ("parity-policy.json", "startup_native.swift", "startup_evidence.py"):
            self.assertFalse(compatibility.completed_stop_extension_matches(
                other, frozen, current, compatibility.COMPLETED_STOP_INVENTORY, source=data))
        self.assertFalse(compatibility.completed_stop_extension_matches(
            name, frozen, current, compatibility.INVENTORY, source=data))

    def test_failure_reporting_reconstructs_exact_original_v5_sources(self):
        from startup_campaign_contract import source_version_matches
        for name, frozen in (("startup_native.swift", compatibility.V5_NATIVE),
                             ("startup_campaign_contract.py", compatibility.V5_CONTRACT)):
            data = Path(compatibility.__file__).with_name(name).read_bytes()
            current = compatibility.digest(data)
            with self.subTest(name=name):
                self.assertTrue(compatibility.failure_metadata_extension_matches(
                    name, frozen, current, compatibility.V5_INVENTORY, source=data))
                self.assertTrue(source_version_matches(name, frozen, current, compatibility.V5_INVENTORY))

    def test_failure_reporting_cannot_authorize_measurement_or_protocol_changes(self):
        for name, frozen, addition in (("startup_native.swift", compatibility.V5_NATIVE,
                                      compatibility.NATIVE_FAILURE_REPORTING),
                                     ("startup_campaign_contract.py", compatibility.V5_CONTRACT,
                                      compatibility.CONTRACT_FAILURE_HOOK)):
            data = Path(compatibility.__file__).with_name(name).read_bytes()
            def matches(value, **changes):
                args = dict(name=name, frozen=frozen, current=compatibility.digest(value),
                            inventory=compatibility.V5_INVENTORY, source=value)
                args.update(changes)
                return compatibility.failure_metadata_extension_matches(**args)
            for value in (data + b"\n", data + addition, data.replace(addition, b""),
                          data.replace(b"if occluded {", b"if false {"),
                          data.replace(b"time.monotonic", b"time.time") if name.endswith('.py') else
                          data.replace(b"+ 15", b"+ 30")):
                if value != data:
                    with self.subTest(name=name, mutation=compatibility.digest(value)):
                        self.assertFalse(matches(value))
            for changes in (dict(inventory=compatibility.INVENTORY), dict(inventory="unknown"),
                            dict(frozen="0"*64), dict(current="0"*64),
                            dict(name="startup_fixture.py"), dict(name="parity-policy.json")):
                with self.subTest(name=name, changes=changes): self.assertFalse(matches(data, **changes))
        name = "startup_campaign_contract.py"
        data = Path(compatibility.__file__).with_name(name).read_bytes()
        altered = data.replace(b"6, 40, 2", b"6, 39, 2")
        self.assertNotEqual(altered, data)
        self.assertFalse(compatibility.failure_metadata_extension_matches(name, compatibility.V5_CONTRACT,
            compatibility.digest(altered), compatibility.V5_INVENTORY, source=altered))

    def test_reviewed_additions_reproduce_every_original_byte(self):
        for name, frozen in [("parity_gate.py", compatibility.FROZEN_GATE),
                             ("resize_protocol.py", compatibility.FROZEN_RESIZE_PROTOCOL)]:
            data = Path(compatibility.__file__).with_name(name).read_bytes()
            with self.subTest(name=name):
                self.assertTrue(compatibility.routing_extension_matches(
                    name, frozen, compatibility.digest(data), compatibility.INVENTORY, source=data))

    def test_current_v5_contract_cannot_match_a_v4_reader_extension(self):
        name='startup_campaign_contract.py'
        data=Path(compatibility.__file__).with_name(name).read_bytes()
        self.assertFalse(compatibility.routing_extension_matches(name,compatibility.FROZEN_CONTRACT,
            compatibility.digest(data),compatibility.INVENTORY,source=data))

    def test_other_source_policy_and_current_digest_changes_are_rejected(self):
        name = "parity_gate.py"; data = Path(compatibility.__file__).with_name(name).read_bytes()
        def matches(value, **overrides):
            args = dict(name=name, frozen=compatibility.FROZEN_GATE,
                        current=compatibility.digest(value), inventory=compatibility.INVENTORY, source=value)
            args.update(overrides)
            return compatibility.routing_extension_matches(**args)
        self.assertFalse(matches(data, name="startup_observer.swift"))
        self.assertFalse(matches(data, inventory="unknown"))
        self.assertFalse(matches(data, frozen="0"*64))
        self.assertFalse(matches(data, current="0"*64))
        for changed in (data+b"\n", data.replace(b"1.0", b"1.1"),
                        data+compatibility.GATE_ADDITION, data.replace(compatibility.GATE_ADDITION,b"")):
            self.assertFalse(matches(changed))
        name = "startup_campaign_contract.py"
        data = Path(compatibility.__file__).with_name(name).read_bytes()
        self.assertFalse(matches(data+b"\n", frozen=compatibility.FROZEN_CONTRACT))
        name = "resize_protocol.py"
        data = Path(compatibility.__file__).with_name(name).read_bytes()
        self.assertFalse(matches(data+b"\n", frozen=compatibility.FROZEN_RESIZE_PROTOCOL))


if __name__ == "__main__":
    unittest.main()
