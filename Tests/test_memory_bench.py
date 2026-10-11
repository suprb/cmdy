#!/usr/bin/env python3
"""Lightweight harness checks: no GUI, native helper invocation, or compilation."""
import copy
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("memory_bench", HERE / "memory_bench.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
import memory_parity_evidence as evidence
from competitive_bench import terminal_config


class MemoryHarnessTests(unittest.TestCase):
    def condition(self):
        return {"power": {"signature": {"source": "Battery Power", "settings": "isolated-test"},
                          **{key: {"returncode": 0} for key in ("battery", "settings", "thermal")}},
                "native": {"lowPowerMode": True, "thermalState": 0,
                           "physicalMemoryBytes": 64 * 2**30, "processorCount": 10, "os": "test macOS"}}

    def test_payloads_exact_rows_and_alternate_tail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "payloads"
            manifest = bench.payloads.create_payloads(root, "0123456789abcdef")
            self.assertEqual([case["expectedRows"] for case in manifest["cases"]], [1000, 5000, 35])
            for case in manifest["cases"]:
                rows = bench.normalized_rows((root / case["expected"]).read_bytes())
                self.assertEqual(len(rows), case["expectedRows"])
                self.assertTrue(all(len(row) == 76 for row in rows))
                self.assertEqual(len(set(rows)), len(rows))
                self.assertIn("ROW_000000|", rows[0])
            alternate = (root / "alternate-continuous.bin").read_bytes()
            self.assertTrue(alternate.startswith(b"\x1b[?1049h" + b"A" * 3_000_000 + b"\x1b[2J\x1b[H"))
            self.assertTrue(alternate.endswith((root / "alternate-expected.bin").read_bytes()))

    def test_payloads_reject_existing_output_without_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "sentinel").write_bytes(b"preserve")
            with self.assertRaises(FileExistsError):
                bench.payloads.create_payloads(path)
            self.assertEqual(list(path.iterdir()), [path / "sentinel"])
            self.assertEqual((path / "sentinel").read_bytes(), b"preserve")

    def test_markers_and_counts_are_bounded(self):
        for count, marker in ((0, "a" * 16), (5001, "a" * 16), (35, "not-a-marker")):
            with self.assertRaises(ValueError):
                bench.payloads.numbered_rows(count, marker)

    def test_case_and_terminal_orders_counterbalance(self):
        cases = [{"name": name} for name in "abc"]
        orders = [tuple(case["name"] for case in bench.case_order(cases, block)) for block in range(6)]
        self.assertEqual(len(set(orders)), 6)
        for position in range(3):
            self.assertEqual(sorted(order[position] for order in orders), list("aabbcc"))
        self.assertEqual([bench.block_order(block)[0] for block in range(6)],
                         ["cmdy", "ghostty", "cmdy", "ghostty", "cmdy", "ghostty"])

    def test_non_nominal_and_incomplete_conditions_rejected(self):
        for path, value in (("thermalState", 1), ("lowPowerMode", 1)):
            record = self.condition()
            record["native"][path] = value
            with self.assertRaises(RuntimeError):
                bench.condition_signature(record)
        record = self.condition()
        record["power"]["signature"]["source"] = None
        with self.assertRaises(RuntimeError):
            bench.condition_signature(record)

    def test_cross_run_power_and_lowpower_changes_rejected(self):
        reference = bench.condition_signature(self.condition())
        bench.require_conditions(self.condition(), reference)
        for field, value in (("lowPowerMode", False), ("physicalMemoryBytes", 1)):
            record = self.condition()
            record["native"][field] = value
            with self.assertRaises(RuntimeError):
                bench.require_conditions(record, reference)
        record = self.condition()
        record["power"]["signature"]["source"] = "AC Power"
        with self.assertRaises(RuntimeError):
            bench.require_conditions(record, reference)

    def test_retention_needs_public_export_and_exact_hash_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected = Path(temporary) / "rows"
            expected.write_bytes(bench.payloads.numbered_rows(35, "0123456789abcdef"))
            digest = bench.expected_history_sha(expected)
            record = {"ok": True, "transport": "public-scrollback-file-paste-path",
                      "expectedRows": 35, "retainedRows": 35, "normalizedSHA256": digest}
            bench.check_history(record, expected, 35)
            for field, value in (("ok", False), ("transport", "legacy-copy"),
                                 ("retainedRows", 34), ("normalizedSHA256", "different")):
                broken = {**record, field: value}
                with self.assertRaises(RuntimeError):
                    bench.check_history(broken, expected, 35)

    def test_identity_and_cross_clock_sample_rejected(self):
        sample = {"ok": True, "pid": 777, "uid": bench.os.getuid(), "processStartTicks": 42,
                  "startedMonotonicNS": 15, "sampleElapsedNS": 1,
                  **{key: 10 for key in bench.MEMORY_FIELDS}}
        with patch.object(bench, "native_json", return_value=sample), \
             patch.object(bench.time, "perf_counter_ns", side_effect=[10, 20]):
            self.assertEqual(bench.memory_sample(Path("helper"), 777, 42)["processStartTicks"], 42)
        for field, value in (("pid", 778), ("processStartTicks", 43), ("startedMonotonicNS", 21)):
            with patch.object(bench, "native_json", return_value={**sample, field: value}), \
                 patch.object(bench.time, "perf_counter_ns", side_effect=[10, 20]):
                with self.assertRaises(RuntimeError):
                    bench.memory_sample(Path("helper"), 777, 42)

    def test_runner_rejects_existing_output_without_even_probing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "sentinel").write_bytes(b"unchanged")
            arguments = ["--output", str(path), "--cmdy-bin", "/bin/sh",
                         "--window-helper", "/bin/sh", "--memory-helper", "/bin/sh",
                         "--history-helper", "/bin/sh", "--ghostty-bin", "/bin/sh"]
            with patch.object(bench.sys, "platform", "darwin"), \
                 patch.object(bench, "window_command") as native:
                with self.assertRaises(FileExistsError):
                    bench.main(arguments)
                native.assert_not_called()
            self.assertEqual(list(path.iterdir()), [path / "sentinel"])

    def test_summary_requires_paired_complete_cases(self):
        records = []
        for terminal in ("cmdy", "ghostty"):
            records.append({"case": "primary-1000", "terminal": terminal, "block": 0,
                "status": "valid", "launchProxyNS": 100,
                "samples": [{"app": {"residentBytes": 10, "physicalFootprintBytes": 8}},
                            {"app": {"residentBytes": 20, "physicalFootprintBytes": 16}},
                            {"app": {"residentBytes": 30, "physicalFootprintBytes": 24}}]})
        summary = bench.summarize(records, 1)
        self.assertEqual(summary["cases"]["primary-1000"]["cmdy"]["residentBytes"]["deltaMedian"], 10)
        for broken in (records[:1], records + [copy.deepcopy(records[0])]):
            with self.assertRaises(ValueError):
                bench.summarize(broken, 1)
        records[0]["status"] = "invalid"
        with self.assertRaises(ValueError):
            bench.summarize(records, 1)

    def test_failed_cleanup_preserves_original_error_and_case_evidence(self):
        class FailedSession:
            def __init__(self, options, helper, terminal, directory, case, payload, marker, python):
                directory.mkdir()
                self.session = self
            def launch(self):
                raise RuntimeError("original owned-launch failure")
            def close(self):
                raise RuntimeError("secondary cleanup failure")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "runs").mkdir()
            manifest = bench.payloads.create_payloads(output / "payloads", "0123456789abcdef")
            args = SimpleNamespace(cmdy_bin=Path("cmdy"), ghostty_bin=Path("ghostty"), timeout=60, profile="matched",
                settle_seconds=5, diagnostic_frame_trace=False, history_helper=Path("history"),
                window_helper=Path("window"))
            with patch.object(bench, "PublicHistorySession", FailedSession), \
                 patch.object(bench, "conditions", return_value=self.condition()):
                with self.assertRaisesRegex(RuntimeError, "original owned-launch failure"):
                    bench.run_case(args, output, manifest["cases"][0], 0, 0, "cmdy",
                                   bench.condition_signature(self.condition()))
            evidence = bench.json.loads(next((output / "runs").glob("*/memory.json")).read_text())
            self.assertEqual(evidence["status"], "invalid")
            self.assertEqual(evidence["error"], "original owned-launch failure")
            self.assertEqual(evidence["cleanupError"], "secondary cleanup failure")


class RawMemoryEvidenceTests(unittest.TestCase):
    pins = {"cmdy": "a" * 64, "ghostty": "b" * 64}

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(bench.json.dumps(value, indent=2) + "\n")

    def conditions(self, started):
        return {"startedMonotonicNS": started, "finishedMonotonicNS": started + 30,
            "power": {"signature": {"source": "AC Power", "settings": "stable-test-settings"},
                      "loadAverage": [1.0, 1.0, 1.0],
                      **{key: {"returncode": 0} for key in ("battery", "settings", "thermal")}},
            "native": {"ok": True, "lowPowerMode": False, "thermalState": 0, "os": "test macOS",
                       "monotonicNS": started + 10, "physicalMemoryBytes": 64 * 2**30, "processorCount": 10}}

    def process(self, pid, parent, start, host_start, rss, footprint):
        return {"ok": True, "pid": pid, "parentPID": parent, "uid": 501,
                "processStartTicks": start, "hostStartedMonotonicNS": host_start,
                "startedMonotonicNS": host_start + 10, "sampleElapsedNS": 2,
                "hostFinishedMonotonicNS": host_start + 50, "timebaseNumer": 1, "timebaseDenom": 1,
                "residentBytes": rss, "physicalFootprintBytes": footprint}

    def fixture(self, root, profile="matched", schema=2, blocks=2, block_start=0):
        payloads = bench.payloads.create_payloads(root / "payloads", "0123456789abcdef")
        order = evidence.expected_order(list(evidence.CASES), blocks, "cmdy", block_start)
        (root / "tooling").mkdir()
        for name in evidence.TOOLING:
            (root / "tooling" / name).write_bytes(("synthetic fixture " + name).encode())
        (root / "helpers").mkdir()
        for name in ("window_helper", "memory_helper", "history_helper"):
            (root / "helpers" / name).write_bytes(("synthetic helper " + name).encode())
        machine = {"font": {"postScriptName": "Menlo-Regular", "family": "Menlo", "sizePoints": 14,
                            "file": "/generated/font"}, "displays": [{"displayID": 1}],
                   "accessibilityTrusted": True, "postEventAuthorized": True}
        manifest = {"schemaVersion": schema, "benchmarkKind": "memory", "status": "complete",
            "finalHashesVerified": True, "diagnostic": False, "metric": bench.METRIC, "profile": profile,
            "arguments": {"profile": profile, "diagnostic_frame_trace": False, "blocks": blocks, "block_start": block_start,
                "settle_seconds": 5, "after_seconds": [0, 1, 5], "display_id": 1, "cases": None, "first": "cmdy"},
            "targetGrid": {"columns": 120, "rows": 36}, "ghosttyScrollbackLimitBytes": 100_000_000,
            "binaries": {name: {"sha256": value, "version": "1.0.7", "build": "1", "infoPlistSHA256": "c" * 64}
                         for name, value in self.pins.items()},
            "toolingSHA256": {path.name: evidence.digest(path) for path in (root / "tooling").iterdir()},
            "helperSHA256": {path.name: evidence.digest(path) for path in (root / "helpers").iterdir()},
            "fontSHA256": "d" * 64, "displayFontPermissions": machine,
            "hardware": {"returncode": 0, "stdout": "known test hardware"},
            "os": {"returncode": 0, "stdout": "known test OS"},
            "clock": {"implementation": "mach_absolute_time()", "monotonic": True, "adjustable": False},
            "initialConditions": self.conditions(10), "payloads": payloads,
            "preregisteredCases": list(evidence.CASES), "plannedRunOrder": order}
        records = []
        for run_index, entry in enumerate(order):
            block, position, name, terminal = (entry[key] for key in ("block", "position", "case", "terminal"))
            run = root / "runs" / f"{block:02d}-{position:02d}-{name}-{terminal}"
            (run / "cmdy-config/extensions").mkdir(parents=True)
            (run / "window-checks").mkdir()
            (run / "app.log").write_bytes(b"")
            app_pid, worker_pid = 1000 + run_index, 2000 + run_index
            app_start, worker_start = 10000 + run_index, 20000 + run_index
            start = (run_index + 1) * 100_000_000_000
            actual_grid = {"columns": 120, "rows": 36, "xpixel": 0, "ypixel": 0}
            state = {"ok": True, "pid": app_pid, "frontmostPID": app_pid, "windows": [{
                "ownerPID": app_pid, "windowID": 3000 + run_index, "displayID": 1, "onScreen": True,
                "bounds": {"x": 120, "y": 120, "width": 1030, "height": 650}}]}
            definition = next(case for case in payloads["cases"] if case["name"] == name)
            payload = payloads["files"][definition["payload"]]
            expected_sha = bench.expected_history_sha(root / "payloads" / definition["expected"])
            config = run / ("cmdy-config/config" if terminal == "cmdy" else "ghostty.config")
            options = bench.BenchOptions(Path("cmdy"), Path("ghostty"), profile=profile)
            config.write_text(terminal_config(terminal, options, (120, 36), Path("/isolated/work"))
                              + ("scrollback-limit = 100000000\n" if terminal == "ghostty" else ""))
            launch = {"appPID": app_pid, "workerPID": worker_pid, "terminal": terminal, "profile": profile,
                "startedMonotonicNS": start + 1000, "processLaunchToFixtureReadyNS": 1000,
                "drainFixtureSource": {"path": "/frozen/terminal_bench_worker.py",
                    "sha256": manifest["toolingSHA256"]["terminal_bench_worker.py"]},
                "fixtureCommand": ["python3", "/frozen/terminal_bench_worker.py"],
                "cwd": "/isolated/work", "configSHA256": evidence.digest(config), "environment": {}}
            raw_flags = [0, bench.termios.ONLCR, 0, 0, 0, 0]
            ready = {"workerPID": worker_pid, "readyMonotonicNS": start + 2000,
                "payloadBytes": payload["bytes"], "payloadSHA256": payload["sha256"], "ttyFlagsRaw": raw_flags}
            record = {**entry, "status": "valid", "profile": profile,
                "identity": {"appPID": app_pid, "workerPID": worker_pid, "workerLaunchIdentity": f"worker-{worker_pid}"},
                "launchProxyNS": 1000, "payloadBytes": payload["bytes"], "payloadSHA256": payload["sha256"],
                "expectedHistorySHA256": expected_sha, "expectedRows": definition["expectedRows"],
                "activeScreen": definition["activeScreen"], "priorBurstBytes": definition["priorBurstBytes"],
                "tty": {"rawFlags": raw_flags, "effectiveOPOST": False, "inactiveONLCRBit": True},
                "window": state, "setupFinishedMonotonicNS": start + 1_000_000,
                "conditions": [self.conditions(start + 10)], "samples": []}
            drain_finished = None
            labels = ["matched-grid-before-settle", "settled-idle-baseline"]
            if schema == 3:
                labels.append("settled-idle-cpu-end")
            pre_output_count = len(labels)
            labels += ["post-output-0s", "post-output-1s", "post-output-5s"]
            for index, label in enumerate(labels):
                if index == 0:
                    guard_start = record["setupFinishedMonotonicNS"] + 100
                elif index < pre_output_count:
                    guard_start = record["samples"][-1]["guardFinishedMonotonicNS"] + 5_000_000_000
                else:
                    guard_start = drain_finished + [0, 1, 5][index - pre_output_count] * 1_000_000_000 + 100
                sample = {"label": label, "requestedOffsetSeconds": None if index < pre_output_count else [0, 1, 5][index - pre_output_count],
                    "guardStartedMonotonicNS": guard_start, "windowBefore": state, "windowAfter": state,
                    "gridBefore": actual_grid, "gridAfter": actual_grid, "conditionsIndex": index + 1,
                    "ownershipChain": [{"pid": worker_pid, "parentPID": app_pid, "startIdentity": f"worker-{worker_pid}"},
                                       {"pid": app_pid, "parentPID": 1, "startIdentity": f"app-{app_pid}"}],
                    "app": self.process(app_pid, 1, app_start, guard_start + 100,
                                        100_000 + position * 100 + index, 80_000 + position * 100 + index),
                    "worker": self.process(worker_pid, app_pid, worker_start, guard_start + 200, 20_000, 10_000)}
                if schema == 3:
                    sample["app"].update(userTimeNS=index * 2000, systemTimeNS=index * 1000, cpuTimeUnit="nanoseconds")
                condition = self.conditions(guard_start + 300)
                record["conditions"].append(condition)
                sample["guardFinishedMonotonicNS"] = condition["finishedMonotonicNS"] + 100
                if index >= pre_output_count:
                    sample["actualOffsetNS"] = sample["app"]["startedMonotonicNS"] - drain_finished
                record["samples"].append(sample)
                self.write(run / "window-checks" / f"{index:04d}.json", {"check": index,
                    "monotonicNS": guard_start + 1, "status": "valid", "requestedActivation": False,
                    "appPID": app_pid, "processReturncode": None, "response": state})
                if index == pre_output_count - 1:
                    footer, reply = bench.expected_reply(36, 120, block)
                    drain_start = sample["guardFinishedMonotonicNS"] + 100
                    drain_finished = drain_start + 1000
                    record["drain"] = {"ok": True, "sequence": block, "footerHex": footer.hex(),
                        "responseHex": reply.hex(), "expectedResponseHex": reply.hex(),
                        "payloadBytes": payload["bytes"], "gridBefore": actual_grid, "gridAfter": actual_grid,
                        "startedMonotonicNS": drain_start, "finishedMonotonicNS": drain_finished,
                        "elapsedNS": 1000, "windowBefore": state, "windowAfter": state}
            audit_start = record["samples"][-1]["guardFinishedMonotonicNS"] + 100
            record["historyVerification"] = {"ok": True, "matchesExpectedRows": True, "clipboardRestored": True,
                "frontmostOwnedAfter": True, "ownedExecutableVerified": True, "ownedPID": app_pid,
                "expectedRows": definition["expectedRows"], "retainedRows": definition["expectedRows"],
                "normalizedSHA256": expected_sha, "expectedNormalizedSHA256": expected_sha,
                "hostStartedMonotonicNS": audit_start, "nativeStartedMonotonicNS": audit_start + 10,
                "nativeFinishedMonotonicNS": audit_start + 20, "hostFinishedMonotonicNS": audit_start + 30}
            self.write(run / "launch.json", launch)
            self.write(run / "ready.json", ready)
            self.write(run / "cleanup.json", {"appPID": app_pid, "fixtureQuit": True, "returncode": -15})
            self.write(run / "memory.json", record)
            records.append(record)
        manifest["finalConditions"] = self.conditions(records[-1]["historyVerification"]["hostFinishedMonotonicNS"] + 100)
        if schema == 3:
            manifest["idleCPUMetric"] = evidence.IDLE_CPU_METRIC
            manifest["arguments"]["idle_cpu_seconds"] = 5
        self.write(root / "manifest.json", manifest)
        self.write(root / "summary.json", {"status": "valid-normalized-history", "diagnostic": False,
            "metric": bench.METRIC, "profile": profile, "blocks": blocks, "blockStart": block_start})
        self.write(root / "records.json", records)
        self.write(root / "conditions-reference.json", {"signature": evidence.condition_signature(manifest["initialConditions"])})
        return manifest, records

    def mutate_record(self, root, records, index=0):
        record = records[index]
        run = root / "runs" / f"{record['block']:02d}-{record['position']:02d}-{record['case']}-{record['terminal']}"
        self.write(run / "memory.json", record)
        self.write(root / "records.json", records)

    def test_valid_adapter_exposes_both_metrics_and_all_idle_baselines(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            result = evidence.load_memory_evidence(root, self.pins)
            self.assertEqual(len(result), 8)
            self.assertEqual({item["memoryMetric"] for item in result}, {"residentBytes", "physicalFootprintBytes"})
            self.assertTrue(all(item["metric"] == "bytes" for item in result))
            idle = next(item for item in result if item["case"] == "memory/idle/rss")
            self.assertEqual([len(values) for pair in idle["blocks"].values() for values in pair.values()], [3, 3, 3, 3])
            self.assertEqual(idle["kind"], "memory")

    def test_cmdy_defaults_is_separate_and_accepts_only_its_isolated_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root, "cmdy-defaults")
            self.assertTrue(all(item["profile"] == "cmdy-defaults" for item in evidence.load_memory_evidence(root, self.pins)))

    def test_schema3_cpu_includes_all_cases_after_settling_and_keeps_memory_separate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root, schema=3)
            result = evidence.load_memory_evidence(root, self.pins)
            self.assertEqual(len(result), 9)
            cpu = next(item for item in result if item["case"] == "idle-cpu")
            self.assertEqual(cpu["kind"], "cpu")
            self.assertEqual(cpu["metric"], "cpuTime")
            self.assertEqual([len(values) for pair in cpu["blocks"].values() for values in pair.values()], [3] * 4)
            self.assertTrue(all(599 < value < 600 for pair in cpu["blocks"].values()
                                for values in pair.values() for value in values))
            self.assertEqual(len([item for item in result if item["kind"] == "memory"]), 8)

    def test_schema3_missing_or_decreasing_cpu_counter_fails_closed(self):
        for change in (None, -1, 0, True):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                _, records = self.fixture(root, schema=3)
                end = records[0]["samples"][2]["app"]
                if change is None:
                    end.pop("userTimeNS")
                else:
                    end["userTimeNS"] = change
                self.mutate_record(root, records)
                with self.assertRaisesRegex(ValueError, "CPU counter"):
                    evidence.load_memory_evidence(root, self.pins)

    def test_cpu_uses_actual_interval_preserves_zero_and_rejects_clock_drift(self):
        before = {"startedMonotonicNS": 1_000_000_000, "userTimeNS": 10, "systemTimeNS": 4, "cpuTimeUnit": "nanoseconds"}
        after = {"startedMonotonicNS": 6_500_000_000, "userTimeNS": 21, "systemTimeNS": 4, "cpuTimeUnit": "nanoseconds"}
        with self.assertRaisesRegex(ValueError, 'converted nanosecond'):
            evidence.idle_cpu_rate({k: v for k, v in before.items() if k != 'cpuTimeUnit'}, after)
        self.assertEqual(evidence.idle_cpu_rate(before, after), 2)
        self.assertEqual(evidence.idle_cpu_rate(before, {**after, "userTimeNS": 10}), 0)
        for ending in (5_999_999_999, 7_000_000_001):
            with self.assertRaisesRegex(ValueError, "interval"):
                evidence.idle_cpu_rate(before, {**after, "startedMonotonicNS": ending})

    def test_incomplete_pairs_wrong_pins_and_legacy_schema_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, records = self.fixture(root)
            with self.assertRaisesRegex(ValueError, "pinned"):
                evidence.load_memory_evidence(root, {**self.pins, "cmdy": "e" * 64})
            self.write(root / "records.json", records[:-1])
            with self.assertRaisesRegex(ValueError, "paired raw"):
                evidence.load_memory_evidence(root, self.pins)
            self.write(root / "records.json", records)
            manifest["schemaVersion"] = 1
            self.write(root / "manifest.json", manifest)
            with self.assertRaisesRegex(ValueError, "legacy pilot"):
                evidence.load_memory_evidence(root, self.pins)

    def test_history_audit_before_samples_and_failed_restore_rejected(self):
        for mutation in ("early", "restore"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                _, records = self.fixture(root)
                if mutation == "early":
                    records[0]["historyVerification"]["hostStartedMonotonicNS"] = 1
                else:
                    records[0]["historyVerification"]["clipboardRestored"] = False
                self.mutate_record(root, records)
                with self.assertRaisesRegex(ValueError, "history|clipboard"):
                    evidence.load_memory_evidence(root, self.pins)

    def test_stale_worker_identity_and_changed_parent_chain_rejected(self):
        for mutation in ("identity", "parent"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                _, records = self.fixture(root)
                if mutation == "identity":
                    records[0]["samples"][-1]["worker"]["processStartTicks"] += 1
                else:
                    records[0]["samples"][-1]["ownershipChain"][0]["parentPID"] += 1
                self.mutate_record(root, records)
                with self.assertRaisesRegex(ValueError, "identity|ancestry"):
                    evidence.load_memory_evidence(root, self.pins)

    def test_power_drift_traces_and_invalid_raw_cases_rejected(self):
        for mutation in ("power", "trace", "invalid"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                manifest, records = self.fixture(root)
                if mutation == "power":
                    records[0]["conditions"][-1]["native"]["lowPowerMode"] = True
                    self.mutate_record(root, records)
                elif mutation == "trace":
                    manifest["diagnostic"] = True
                    self.write(root / "manifest.json", manifest)
                else:
                    records[0]["status"] = "invalid"
                    self.mutate_record(root, records)
                with self.assertRaisesRegex(ValueError, "power|diagnostic|invalid"):
                    evidence.load_memory_evidence(root, self.pins)

    def test_payload_tampering_and_changed_frozen_helper_rejected(self):
        for target in ("payloads/primary-1000.bin", "helpers/memory_helper"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.fixture(root)
                with (root / target).open("ab") as stream:
                    stream.write(b"changed")
                with self.assertRaisesRegex(ValueError, "payload|helper"):
                    evidence.load_memory_evidence(root, self.pins)

    def test_actual_counterbalanced_order_cannot_be_replaced_by_plan_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, records = self.fixture(root)
            # Swapping raw records cannot be repaired by preserving an unchanged planned order.
            records[0], records[1] = records[1], records[0]
            self.write(root / "records.json", records)
            with self.assertRaisesRegex(ValueError, "order"):
                evidence.load_memory_evidence(root, self.pins)


if __name__ == "__main__":
    unittest.main(verbosity=2)
